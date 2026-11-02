#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

RESUME=0
case "${1:-}" in
    "") ;;
    --resume) RESUME=1 ;;
    *) fail "Usage: bash run_ns3_precheck.sh [--resume]" ;;
esac

(( $# <= 1 )) || fail "Too many arguments."

[[ -f ns3 && -f cmake-cache/CMakeCache.txt ]] ||
    fail "Run from the configured ns-3 root."

for cmd in \
    awk cmake timeout setsid sha256sum flock realpath \
    find sort xargs cmp tar; do
    command -v "$cmd" >/dev/null ||
        fail "Missing $cmd"
done

ROOT=$PWD

[[ $(tr -d '[:space:]' <VERSION) == "3.46.1" ]] ||
    fail "Requires ns-3.46.1."

OUT="$ROOT/precheck_ns3_3461"
SCRIPT=$(realpath "${BASH_SOURCE[0]}")

SOURCES=(
    scratch/ns3-precheck.cc
    scratch/ns3-precheck-sources/foundation-d1.inc
    scratch/ns3-precheck-sources/foundation-d2.inc
    scratch/ns3-precheck-sources/foundation-d4.inc
)

hash_file() {
    sha256sum "$1" | awk '{print $1}'
}

[[ $(hash_file src/wifi/model/ht/ht-frame-exchange-manager.cc) == 5dd1802ba9bc067a9c373a062b1b1feda0a66352a56bdce34a2c06e50b6869b3 ]] ||
    fail "HT source differs. Run ns3_prepare.sh inspect."

[[ $(hash_file src/wifi/model/qos-txop.cc) == 4c2239d80a8e939e2658ee82a9e3066a8a0abac9e7687ce72df206facf3a0295 ]] ||
    fail "QoS source differs. Run ns3_prepare.sh inspect."

for pair in \
    '1:7976d1e4169b10b142e433639dabe83fe7ca4eded2264a4c41b592e7e92d76fa' \
    '2:dcd6a03011af574d2c32b5df26f217f9a1b85f2f05217e5503d2b76fd462304f' \
    '4:df6fab62056c8804704966522020385992c448505c41bdf863063ba63910430d'; do

    source="scratch/ns3-precheck-sources/foundation-d${pair%%:*}.inc"

    [[ -f "$source" ]] ||
        fail "Missing $source. Run ns3_prepare.sh apply."

    [[ $(hash_file "$source") == "${pair#*:}" ]] ||
        fail "Archived check source differs: $source"
done

FILES=(
    summary.csv
    per_sta.csv
    per_link.csv
    rx_diagnostic.csv
    rx_timeline.csv
    mac_drop_reasons.csv
    rx_state.csv
    phy_audit.csv
    mechanism.csv
    mobility.csv
    checks.csv
)

for f in "${SOURCES[@]}"; do
    [[ -f "$f" ]] || fail "Missing $f"
done

if (( RESUME )); then
    [[ -f "$OUT/configuration.txt" && -f "$OUT/plan.tsv" ]] ||
        fail "No batch to resume."
else
    [[ ! -e "$OUT" ]] ||
        fail "Output exists. Use --resume."
fi

mkdir -p "$OUT"/{cases,logs,invalid}

exec 9>"$OUT/.lock"
flock -n 9 || fail "Another check is running."

TMP=$(mktemp -d)
PID=
READY=0

cleanup() {
    if [[ -n "$PID" ]]; then
        kill -TERM -- "-$PID" 2>/dev/null ||
            kill -TERM "$PID" 2>/dev/null || true
        kill -KILL -- "-$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi

    rm -rf -- "$TMP"
}

interrupted() {
    trap '' INT TERM
    cleanup
    PID=

    if (( READY )); then
        aggregate || true
    fi

    echo "Interrupted. Resume: bash run_ns3_precheck.sh --resume"
    exit 130
}

trap cleanup EXIT
trap interrupted INT TERM

make_plan() {
    printf 'phase\tcase_id\tprogram\tmode\tn_sta\tload\trng_run\tsplit_ratio\twidth\tfading\tspeed\tprofile\n'

    emit() {
        local phase=$1 program=$2 mode=$3 n=$4 rate=$5
        local ratio=$6 width=$7 fading=$8 speed=$9
        local profile=${10} r id

        for r in 1 2 3 4 5; do
            id="F${phase}_D${program}_${mode}_N${n}_R${rate}_S${ratio//./p}_W${width}_F${fading}_V${speed//./p}_run${r}"

            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$phase" "$id" "$program" "$mode" "$n" \
                "$rate" "$r" "$ratio" "$width" \
                "$fading" "$speed" "$profile"
        done
    }

    # Phase 1: low-load checks, 20 cases.
    for n in 1 5; do
        for mode in slo5 mlo; do
            emit 1 1 "$mode" "$n" 1 0.5 20 0 0 LOW
        done
    done

    # Phase 2: band and channel width, 15 cases.
    emit 2 2 slo6 5 20 0.5 20 0 0 LOADED
    emit 2 2 slo5 5 40 0.5 40 0 0 LOADED
    emit 2 2 slo5 5 40 0.5 80 0 0 LOADED

    # Phase 3: assignment and loaded operation, 60 cases.
    emit 3 4 mlo_balanced 10 20 0.5 20 0 0 LOADED
    emit 3 4 mlo_static 10 20 0.1 20 0 0 LOADED
    emit 3 4 mlo_static 10 20 0.9 20 0 0 LOADED

    for n in 10 30 50; do
        for mode in slo5 mlo; do
            emit 3 2 "$mode" "$n" 10 0.5 20 0 0 LOADED
        done
    done

    emit 3 2 mlo 40 10 0.5 20 0 0 LOADED
    emit 3 2 slo5 40 5 0.5 20 0 0 LOADED
    emit 3 1 mlo 5 60 0.5 20 0 0 LOADED

    # Phase 4: mechanism checks, 15 cases.
    # These are the original diagnostics, not the Demo 5 model.
    emit 4 2 mlo 5 1 0.5 20 1 0 MECHANISM
    emit 4 2 mlo 5 1 0.5 20 0 0.1 MECHANISM
    emit 4 2 mlo 5 1 0.5 20 1 0.1 MECHANISM
}

make_plan >"$TMP/plan.tsv"

{
    echo "schema=ns3-precheck-110-archived-v1"
    cat VERSION
    sha256sum "${SOURCES[@]}" "$SCRIPT" "$TMP/plan.tsv"

    find \
        src/wifi/model \
        src/network/utils \
        src/traffic-control/model \
        src/propagation/model \
        src/mobility/model \
        src/internet/model \
        src/core/model \
        -type f -print0 |
        sort -z |
        xargs -0 sha256sum
} >"$TMP/configuration.txt"

normalize_configuration() {
    awk '
        NF==2 && length($1)==64 && $1 ~ /^[0-9a-f]+$/ {
            name=$2

            if(name ~ /\/plan.tsv$/)
                name="plan.tsv"

            if(name ~ /\/run_ns3_precheck.sh$/)
                name="run_ns3_precheck.sh"

            print $1 "  " name
            next
        }

        {print}
    ' "$1"
}

if (( RESUME )); then
    cmp -s "$TMP/plan.tsv" "$OUT/plan.tsv" ||
        fail "Experiment plan changed. Do not mix results."

    normalize_configuration "$TMP/configuration.txt" \
        >"$TMP/current.normalized"

    normalize_configuration "$OUT/configuration.txt" \
        >"$TMP/saved.normalized"

    cmp -s "$TMP/current.normalized" "$TMP/saved.normalized" ||
        fail "C++, Bash or model source changed. Do not mix results."
else
    cp "$TMP/configuration.txt" "$OUT/configuration.txt"
    cp "$TMP/plan.tsv" "$OUT/plan.tsv"
    cp "${SOURCES[@]}" "$SCRIPT" "$OUT/"
fi

TOTAL=$(awk 'END {print NR-1}' "$OUT/plan.tsv")
(( TOTAL == 110 )) || fail "Expected exactly 110 cases."

audit_case() {
    local dir=$1 id=$2 mode=$3 n=$4 width=$5
    local fading=$6 speed=$7 profile=$8 rate=$9 rng=${10}

    awk -F, \
        -v id="$id" \
        -v mode="$mode" \
        -v n="$n" \
        -v width="$width" \
        -v fading="$fading" \
        -v speed="$speed" \
        -v profile="$profile" \
        -v rate="$rate" \
        -v rng="$rng" '
    function v(k) {
        return $(h[k])
    }

    function near(a,b) {
        return (a-b < 0 ? b-a : a-b) <= \
            0.000001*(1+(b<0?-b:b))
    }

    function check(name,ok,detail) {
        print id "," name "," (ok?"PASS":"FAIL") "," detail
    }

    function kpi() {
        tx=v("tx_packets")+0
        rx=v("rx_packets")+0
        bytes=v("rx_bytes")+0

        if(rx>tx || bytes!=rx*1228 ||
           !near(v("throughput_mbps"),bytes*8/9000000))
            numericBad++

        if(tx && !near(v("loss_pct"),100*(tx-rx)/tx))
            numericBad++

        if(!rx &&
           (v("delay_ms")!="NA" || v("jitter_ms")!="NA"))
            numericBad++

        if(rx &&
           (v("delay_ms")=="NA" || v("delay_ms")<0))
            numericBad++
    }

    BEGIN {
        links=(mode=="slo5" || mode=="slo6")?1:2
        print "case_id,check,status,detail"
    }

    FNR==1 {
        delete h
        for(i=1;i<=NF;i++)
            h[$i]=i
        next
    }

    FILENAME ~ /summary.csv$/ {
        summaryRows++
        kpi()
        stx=tx
        srx=rx
        sb=bytes
        jt=v("jain_sta")
        delay=v("delay_ms")
        jitter=v("jitter_ms")

        if(v("case_id")!=id ||
           v("mode")!=mode ||
           v("n_sta")!=n ||
           v("mcs")!=9 ||
           v("coding")!="BCC" ||
           v("nss")!=1 ||
           v("gi_ns")!=3200 ||
           v("payload_bytes")!=1200 ||
           v("seed")!=1 ||
           v("rng_run")!=rng ||
           !near(v("offered_per_sta_mbps"),rate) ||
           !near(v("offered_total_mbps"),n*rate) ||
           v("measure_s")!=9 ||
           v("radius_m")!=5 ||
           v("status")!="PASS")
            configBad++

        expectedW5=mode=="slo6"?0:width
        expectedW6=mode=="slo6" || links==2?width:0

        if(v("width5_mhz")!=expectedW5 ||
           v("width6_mhz")!=expectedW6 ||
           !near(v("tx_power_dbm"),16.0206) ||
           v("rx_noise_figure_db")!=7)
            configBad++

        next
    }

    FILENAME ~ /per_sta.csv$/ {
        stationRows++
        kpi()
        i=v("sta_id")

        if(seenSta[i]++ || i<0 || i>=n ||
           v("case_id")!=id)
            numericBad++

        atx+=tx
        arx+=rx
        ab+=bytes
        sumT+=v("throughput_mbps")
        sumT2+=v("throughput_mbps")^2

        if(rx)
            delaySum+=v("delay_ms")*rx

        jsta[i]=v("jitter_ms")
        staRx[i]=rx

        if(v("setup_links")!=links)
            setupBad++

        next
    }

    FILENAME ~ /per_link.csv$/ {
        linkRows++
        kpi()
        ltx+=tx
        lrx+=rx
        lb+=bytes
        next
    }

    FILENAME ~ /rx_diagnostic.csv$/ {
        diagRows++
        i=v("sta_id")
        l=v("phy_id")
        key=i ":" l

        if(seenDiag[key]++ || v("case_id")!=id)
            counterBad++

        active[key]=v("planned_load_mbps")>0

        if(active[key]) {
            expectedLoad=(mode=="mlo"?rate/links:rate)
            expectedPackets=9*expectedLoad*1000000/9600

            if(!near(v("planned_load_mbps"),expectedLoad) ||
               v("app_send_ok")<expectedPackets-1 ||
               v("app_send_ok")>expectedPackets+1)
                counterBad++
        }

        if(v("app_send_calls")!=v("app_send_ok") ||
           v("app_send_ok")!=v("flow_tx_packets") ||
           v("app_rx_packets")!=v("flow_rx_packets"))
            counterBad++

        if(v("arp_sta_permanent")!=1 ||
           v("arp_ap_permanent")!=1)
            arpBad++

        if(v("setup_links")!=links)
            setupBad++

        dtx+=v("flow_tx_packets")
        drx+=v("flow_rx_packets")

        if(active[key] &&
           (!v("app_send_ok") || !v("mac_ip_submitted")))
            counterBad++

        if(!active[key] &&
           (v("app_send_ok") || v("flow_rx_packets")))
            counterBad++

        if(active[key] && v("flow_rx_packets")==0)
            zeros++

        denom=v("flow_rx_packets")>1?v("flow_rx_packets")-1:0
        jd[i]+=denom
        jden+=denom

        next
    }

    FILENAME ~ /rx_timeline.csv$/ {
        timelineRows++

        if(v("case_id")!=id ||
           v("associated")!=1 ||
           v("setup_links")!=links)
            setupBad++

        if(v("arp_sta_permanent")!=1 ||
           v("arp_ap_permanent")!=1)
            arpBad++

        next
    }

    FILENAME ~ /rx_state.csv$/ {
        stateRows++
        key=v("sta_id") ":" v("planned_phy")

        if(v("planned_phy")==v("observed_phy") &&
           v("elapsed_s")>=6 &&
           active[key] &&
           v("originator_ba_state")=="PENDING" &&
           v("blocked_reasons")~/WAITING_ADDBA_RESP/)
            pending[key]++

        next
    }

    FILENAME ~ /phy_audit.csv$/ {
        phyRows++

        if(v("case_id")!=id || v("valid")!=1)
            phyBad++

        next
    }

    FILENAME ~ /mechanism.csv$/ {
        mechanismRows++
        l=v("phy_id")
        expectedBand=(mode=="slo6" || l==1)?6:5

        if(v("case_id")!=id ||
           v("band_ghz")!=expectedBand ||
           v("width_mhz")!=width ||
           v("fading")!=fading ||
           !near(v("mobility_speed_mps"),speed))
            mechanismBad++

        if(fading &&
           v("loss_chain")!="LogDistance+Nakagami_m1")
            mechanismBad++

        next
    }

    FILENAME ~ /mobility.csv$/ {
        mobilityRows++
        i=v("sta_id")
        t=v("elapsed_s")
        a=2*atan2(0,-1)*i/n

        if(v("case_id")!=id ||
           !near(v("x_m"),5*cos(a)-speed*sin(a)*t) ||
           !near(v("y_m"),5*sin(a)+speed*cos(a)*t) ||
           !near(v("z_m"),1.5))
            mobilityBad++

        next
    }

    END {
        check("CONFIGURATION",
              !configBad && summaryRows==1,
              "fixed_parameters_and_runtime_status")

        check("ASSOCIATION_SETUP",
              !setupBad && timelineRows==n*links*6,
              "all_samples")

        check("ARP_BIDIRECTIONAL",
              !arpBad && diagRows==n*links,
              "permanent_and_correct_MAC_both_directions")

        check("APP_IP_COUNTERS",
              !counterBad && diagRows==n*links &&
              dtx==stx && drx==srx,
              "application_vs_FlowMonitor")

        check("KPI_CONSERVATION",
              !numericBad &&
              stationRows==n &&
              linkRows==links &&
              atx==stx && arx==srx && ab==sb &&
              ltx==stx && lrx==srx && lb==sb,
              "IP_bytes_rates_loss_and_sums")

        expectedJ=sumT2>0?sumT*sumT/(n*sumT2):"NA"

        check("JAIN",
              sumT2>0?near(jt,expectedJ):jt=="NA",
              "all_physical_STAs_including_zeros")

        for(i in jd)
            if(jd[i])
                jitterSum+=jsta[i]*jd[i]

        check("DELAY_JITTER",
              (!srx || near(delay,delaySum/srx)) &&
              (!jden || near(jitter,jitterSum/jden)),
              "weighted_received_packet_statistics")

        check("ACTUAL_PHY",
              !phyBad && phyRows>0,
              "actual_QoS_transmit_MCS_NSS_GI_BCC_width_TID_link")

        check("CHANNEL_MECHANISMS",
              !mechanismBad && mechanismRows==links,
              "band_width_and_loss_chain_each_link")

        check("MOBILITY",
              !mobilityBad && mobilityRows==n*6,
              "position_on_shared_STA_node_all_samples")

        check("STATE_COVERAGE",
              stateRows==n*links*links*6,
              "all_TID_and_link_snapshots")

        stuck=0
        for(key in pending)
            if(pending[key]>=2)
                stuck++

        print id ",ZERO_RX_ACTIVE_FLOW," \
            (zeros?"REVIEW":"PASS") ",count_" (zeros+0)

        print id ",PERSISTENT_BA_PENDING," \
            (stuck?"REVIEW":"PASS") ",count_" stuck

        print id ",LOW_LOAD_LOSS," \
            (profile=="LOW" && stx &&
             100*(stx-srx)/stx>1?"REVIEW":"PASS") \
            ",review_threshold_1pct_only_for_LOW"
    }
    ' \
        "$dir/summary.csv" \
        "$dir/per_sta.csv" \
        "$dir/per_link.csv" \
        "$dir/rx_diagnostic.csv" \
        "$dir/rx_timeline.csv" \
        "$dir/rx_state.csv" \
        "$dir/phy_audit.csv" \
        "$dir/mechanism.csv" \
        "$dir/mobility.csv" \
        >"$dir/checks.csv"
}

valid_case() {
    local dir=$1

    [[ -s "$dir/.done" &&
       $(wc -l <"$dir/.done") -eq ${#FILES[@]} ]] ||
        return 1

    (cd "$dir" && sha256sum --check --status .done)
}

aggregate() {
    local stage phase id program mode n rate run ratio
    local width fading speed profile dir status f

    stage=$(mktemp -d "$OUT/.aggregate.XXXXXX")

    for f in "${FILES[@]}"; do
        : >"$stage/$f"
    done

    echo 'phase,case_id,status' >"$stage/run_manifest.csv"

    while IFS=$'\t' read -r \
        phase id program mode n rate run ratio \
        width fading speed profile; do

        [[ "$phase" == phase ]] && continue

        dir="$OUT/cases/$id"
        status=PENDING

        if valid_case "$dir"; then
            status=PASS

            if awk -F, '
                NR>1 && $3!="PASS" {bad=1}
                END {exit !bad}
            ' "$dir/checks.csv"; then
                status=HOLD
            fi

            for f in "${FILES[@]}"; do
                if [[ ! -s "$stage/$f" ]]; then
                    head -n 1 "$dir/$f" >"$stage/$f"
                fi

                tail -n +2 "$dir/$f" >>"$stage/$f"
            done
        fi

        printf '%s,%s,%s\n' \
            "$phase" "$id" "$status" \
            >>"$stage/run_manifest.csv"

    done <"$OUT/plan.tsv"

    for f in "${FILES[@]}" run_manifest.csv; do
        mv -f "$stage/$f" "$OUT/$f"
    done

    rmdir "$stage"
}

run_logged() {
    local logfile=$1 rc=0
    shift

    setsid "$@" >"$logfile" 2>&1 9>&- &
    PID=$!

    wait "$PID" || rc=$?
    PID=

    return "$rc"
}

{
    cat VERSION
    uname -srmo
    c++ --version | head -n 1
    cmake --version | head -n 1
    python3 --version
} >"$OUT/environment.txt"

tar -czf "$OUT/blockack-source-3461.tar.gz" \
    VERSION \
    src/wifi/model/ht/ht-frame-exchange-manager.cc \
    src/wifi/model/ht/ht-frame-exchange-manager.h \
    src/wifi/model/qos-txop.cc \
    src/wifi/model/qos-txop.h \
    src/wifi/model/block-ack-manager.cc \
    src/wifi/model/block-ack-manager.h

READY=1
aggregate

if [[ -s "$OUT/checks.csv" ]] &&
   awk -F, '
       NR>1 && $3=="FAIL" {bad=1}
       END {exit !bad}
   ' "$OUT/checks.csv"; then
    fail "Retained case has failed checks. Review checks.csv."
fi

echo "NS3_PRECHECK: $TOTAL cases; five RNG runs/configuration."
echo "Output: $OUT"

if ! run_logged "$OUT/logs/configure.log" \
    cmake -S "$ROOT" -B "$ROOT/cmake-cache"; then
    tail -n 30 "$OUT/logs/configure.log"
    fail "Configure failed."
fi

if ! run_logged "$OUT/logs/build.log" \
    cmake --build "$ROOT/cmake-cache" \
    --target scratch_ns3-precheck --parallel 4; then
    tail -n 40 "$OUT/logs/build.log"
    fail "Build failed."
fi

awk '
    /enum WifiMacDropReason/ {on=1}
    on {print}
    on && /};/ {exit}
' src/wifi/model/wifi-mac.h >"$OUT/drop_reason_enum.txt"

awk '
    /enum class WifiQueueBlockedReason/ {on=1}
    on {print}
    on && /};/ {exit}
' src/wifi/model/wifi-mac-queue-scheduler.h \
    >"$OUT/blocked_reason_enum.txt"

COUNT=0

for PHASE in 1 2 3 4; do
    echo "PHASE $PHASE"

    while IFS=$'\t' read -r \
        phase id program mode n rate run ratio \
        width fading speed profile; do

        [[ "$phase" == "$PHASE" ]] || continue

        COUNT=$((COUNT+1))
        dir="$OUT/cases/$id"

        if valid_case "$dir"; then
            echo "[$COUNT/$TOTAL] retained $id"
            continue
        fi

        if [[ -e "$dir" ]]; then
            invalid=$(mktemp -d "$OUT/invalid/${id}.XXXXXX")
            mv "$dir" "$invalid/case"
        fi

        work=$(mktemp -d "$OUT/.work-${id}.XXXXXX")

        args=(
            "--mode=$mode"
            "--nSta=$n"
            "--offeredLoad=$rate"
            "--seed=1"
            "--run=$run"
            "--caseId=$id"
            "--out=$work"
        )

        if [[ "$program" == 2 ]]; then
            args+=(
                "--width=$width"
                "--fading=$fading"
                "--speed=$speed"
            )
        fi

        if [[ "$program" == 4 ]]; then
            args+=("--splitRatio=$ratio")
        fi

        echo "[$COUNT/$TOTAL] $id"

        rc=0

        run_logged "$work/run.log" \
            timeout --signal=TERM --kill-after=10s 1800s \
            ./ns3 run --no-build scratch/ns3-precheck -- \
            "--program=$program" "${args[@]}" || rc=$?

        if (( rc != 0 )); then
            aggregate
            tail -n 40 "$work/run.log"
            fail "$id failed (exit $rc). Evidence: $work"
        fi

        for f in "${FILES[@]}"; do
            [[ "$f" == checks.csv || -s "$work/$f" ]] ||
                fail "Missing $f: $work"
        done

        audit_case \
            "$work" "$id" "$mode" "$n" "$width" \
            "$fading" "$speed" "$profile" "$rate" "$run"

        (
            cd "$work"
            sha256sum "${FILES[@]}" >.done
        )

        mv "$work" "$dir"

        if (( COUNT % 5 == 0 )); then
            aggregate
        fi

        if awk -F, '
            NR>1 && $3=="FAIL" {bad=1}
            END {exit !bad}
        ' "$dir/checks.csv"; then
            aggregate
            cat "$dir/checks.csv"
            fail "Hard check failed: $id"
        fi

    done <"$OUT/plan.tsv"

    aggregate

    if awk -F, -v phase="$PHASE" '
        NR>1 && $1==phase && $3=="HOLD" {bad=1}
        END {exit !bad}
    ' "$OUT/run_manifest.csv"; then
        echo "REVIEW retained in phase $PHASE."
        echo "Continue remaining planned checks; hard FAIL still stops."
    fi

    if [[ "$PHASE" == 1 ]]; then
        read -r _ replayId _ < <(
            awk -F '\t' '
                $1==1 && $4=="mlo" && $5==1 && $7==1 {
                    print $1, $2, $3
                    exit
                }
            ' "$OUT/plan.tsv"
        )

        if ! valid_case "$OUT/replay"; then
            work=$(mktemp -d "$OUT/.replay.XXXXXX")

            echo "REPLAY: same seed/run for $replayId"

            rc=0

            run_logged "$work/run.log" \
                timeout --signal=TERM --kill-after=10s 1800s \
                ./ns3 run --no-build scratch/ns3-precheck -- \
                --program=1 \
                --mode=mlo \
                --nSta=1 \
                --offeredLoad=1 \
                --seed=1 \
                --run=1 \
                --caseId="$replayId" \
                --out="$work" || rc=$?

            (( rc == 0 )) ||
                fail "Replay failed: $work/run.log"

            audit_case \
                "$work" "$replayId" mlo 1 20 \
                0 0 LOW 1 1

            for f in "${FILES[@]}"; do
                cmp -s "$work/$f" "$OUT/cases/$replayId/$f" ||
                    fail "Replay differs: $f; evidence: $work"
            done

            (
                cd "$work"
                sha256sum "${FILES[@]}" >.done
            )

            if [[ -e "$OUT/replay" ]]; then
                invalid=$(mktemp -d "$OUT/invalid/replay.XXXXXX")
                mv "$OUT/replay" "$invalid/case"
            fi

            mv "$work" "$OUT/replay"
        fi

        printf 'case_id,status,detail\n%s,PASS,identical_seed_run_all_11_CSV\n' \
            "$replayId" >"$OUT/reproducibility.csv"
    fi
done

aggregate

if awk -F, '
    NR>1 && $3!="PASS" {bad=1}
    END {exit !bad}
' "$OUT/run_manifest.csv"; then
    echo "NS3_PRECHECK=HOLD: all planned cases processed."
    echo "Review: $OUT/checks.csv"
    exit 2
fi

echo "NS3_PRECHECK=PASS: $TOTAL/$TOTAL cases passed."
echo "Results: $OUT"