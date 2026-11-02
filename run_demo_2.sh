#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
fail() { echo "ERROR: $*" >&2; exit 1; }
RESUME=0
case "${1:-}" in "") ;; --resume) RESUME=1 ;; *) fail "Usage: bash run_demo_2.sh [--resume]" ;; esac
(( $# <= 1 )) || fail "Too many arguments."
[[ -f ns3 && -f VERSION ]] || fail "Run from ns-3 root."
[[ $(tr -d '[:space:]' <VERSION) == 3.46.1 ]] || fail "Requires ns-3.46.1."
for c in cmake awk sha256sum flock timeout setsid find sort xargs; do
    command -v "$c" >/dev/null || fail "Missing $c"
done
ROOT=$PWD
SRC=scratch/demo-2-sta-scaling.cc
SCRIPT=$(realpath "${BASH_SOURCE[0]}")
OUT="$ROOT/results_demo_2_rng5"
FILES=(summary.csv per_sta.csv per_link.csv)
[[ -f "$SRC" ]] || fail "Missing $SRC"
hash_file() { sha256sum "$1" | awk '{print $1}'; }
[[ $(hash_file src/wifi/model/ht/ht-frame-exchange-manager.cc) == 5dd1802ba9bc067a9c373a062b1b1feda0a66352a56bdce34a2c06e50b6869b3 ]] || fail "HT source differs from the checked version."
[[ $(hash_file src/wifi/model/qos-txop.cc) == 4c2239d80a8e939e2658ee82a9e3066a8a0abac9e7687ce72df206facf3a0295 ]] || fail "ADDBA expiry fix missing or source changed."
if (( RESUME )); then
    [[ -f "$OUT/configuration.txt" ]] || fail "No batch to resume."
else
    [[ ! -e "$OUT" ]] || fail "Output exists. Resume this batch, or archive the old output."
fi
mkdir -p "$OUT"/{cases,logs,invalid}
exec 9>"$OUT/.lock"
flock -n 9 || fail "Another Demo 2 runner is active."
TMP=$(mktemp -d)
PID=
READY=0
cleanup() {
    if [[ -n "$PID" ]]; then
        kill -TERM -- "-$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    rm -rf -- "$TMP"
}
interrupted() {
    trap '' INT TERM
    cleanup
    PID=
    if (( READY )); then aggregate || true; fi
    echo "Interrupted. Continue: bash run_demo_2.sh --resume"
    exit 130
}
trap cleanup EXIT
trap interrupted INT TERM
{
    printf 'case_id\tn_sta\tload\tmode\trng_run\n'
    for r in 1 2 3 4 5; do
        for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 20 25 30 35 40 50; do
            rates=(5 10)
            for rate in "${rates[@]}"; do
                for mode in slo5 mlo; do
                    printf 'D2_N%s_R%s_%s_run%s\t%s\t%s\t%s\t%s\n' \
                        "$n" "$rate" "$mode" "$r" "$n" "$rate" "$mode" "$r"
                done
            done
        done
    done
} >"$TMP/plan.tsv"
{
    echo 'demo2-schema2-gi3200-staticarp-expiryfix-v1'
    printf 'cpp=%s\nbash=%s\nplan=%s\n' \
        "$(hash_file "$SRC")" "$(hash_file "$SCRIPT")" "$(hash_file "$TMP/plan.tsv")"
    cat VERSION
    find src/wifi/model src/internet/model src/flow-monitor/model \
        src/mobility/model src/propagation/model src/network/utils src/core/model \
        -type f -print0 | sort -z | xargs -0 sha256sum
} >"$TMP/configuration.txt"
if (( RESUME )); then
    cmp -s "$TMP/configuration.txt" "$OUT/configuration.txt" || fail "Source/script/model changed. Do not mix results."
    cmp -s "$TMP/plan.tsv" "$OUT/plan.tsv" || fail "Plan changed."
else
    cp "$TMP/configuration.txt" "$OUT/configuration.txt"
    cp "$TMP/plan.tsv" "$OUT/plan.tsv"
    cp "$SRC" "$SCRIPT" "$OUT/"
fi
validate() {
    local dir=$1 id=$2 n=$3 rate=$4 mode=$5 run=$6
    awk -F, -v id="$id" -v n="$n" -v rate="$rate" -v mode="$mode" -v run="$run" '
      function v(k) {return $(h[k])}
      function near(a,b) {return (a>b?a-b:b-a)<0.000001*(1+(b<0?-b:b))}
      FNR==1 {delete h; for(i=1;i<=NF;i++) h[$i]=i; next}
      {
        if(v("case_id")!=id || v("mode")!=mode) bad=1
        tx=v("tx_packets")+0; rx=v("rx_packets")+0; bytes=v("rx_bytes")+0
        if(rx>tx || bytes!=rx*1228 || !near(v("throughput_mbps"),8*bytes/9000000)) bad=1
        if(tx && !near(v("loss_pct"),100*(tx-rx)/tx)) bad=1
        if(!rx && (v("delay_ms")!="NA" || v("jitter_ms")!="NA")) bad=1
      }
      FILENAME==ARGV[1] {
        summaries++; stx=tx; srx=rx; sb=bytes; j=v("jain_sta")
        if(v("status")!="PASS" || v("schema")!=2 || v("demo")!=2 || v("n_sta")!=n ||
           v("mcs")!=9 || v("coding")!="BCC" || v("nss")!=1 || v("gi_ns")!=3200 ||
           v("width5_mhz")!=20 || v("width6_mhz")!=(mode=="mlo"?20:0) ||
           v("payload_bytes")!=1200 || v("seed")!=1 || v("rng_run")!=run ||
           v("radius_m")!=5 || v("app_start_s")<1 || v("app_start_s")>10.1 ||
           !near(v("sim_stop_s")-v("app_start_s"),9) ||
           v("measure_s")!=9 || !near(v("offered_per_sta_mbps"),rate)) bad=1
        next
      }
      FILENAME==ARGV[2] {
        stations++; i=v("sta_id"); if(seenSta[i]++ || i<0 || i>=n) bad=1
        if(v("setup_links")!=(mode=="mlo"?2:1)) bad=1
        atx+=tx; arx+=rx; ab+=bytes; t=v("throughput_mbps"); sum+=t; sq+=t*t
        next
      }
      FILENAME==ARGV[3] {links++; ltx+=tx; lrx+=rx; lb+=bytes}
      END {
        if(summaries!=1 || stations!=n || links!=(mode=="mlo"?2:1) ||
           atx!=stx || arx!=srx || ab!=sb || ltx!=stx || lrx!=srx || lb!=sb) bad=1
        if(sq && !near(j,sum*sum/(n*sq))) bad=1
        if(bad) exit 1
      }
    ' "$dir/summary.csv" "$dir/per_sta.csv" "$dir/per_link.csv"
}
valid_case() {
    local dir=$1
    [[ -s "$dir/.done" && $(wc -l <"$dir/.done") -eq 3 ]] || return 1
    (cd "$dir" && sha256sum --check --status .done)
}
aggregate() {
    local stage id n rate mode run dir f status
    stage=$(mktemp -d "$OUT/.aggregate.XXXXXX")
    for f in "${FILES[@]}"; do : >"$stage/$f"; done
    echo 'case_id,demo,mode,n_sta,offered_per_sta_mbps,rng_run,status' >"$stage/run_manifest.csv"
    while IFS=$'\t' read -r id n rate mode run; do
        [[ "$id" == case_id ]] && continue
        dir="$OUT/cases/$id"; status=PENDING
        if valid_case "$dir"; then
            status=DONE
            for f in "${FILES[@]}"; do
                if [[ ! -s "$stage/$f" ]]; then head -n 1 "$dir/$f" >"$stage/$f"; fi
                tail -n +2 "$dir/$f" >>"$stage/$f"
            done
        fi
        printf '%s,2,%s,%s,%s,%s,%s\n' "$id" "$mode" "$n" "$rate" "$run" "$status" >>"$stage/run_manifest.csv"
    done <"$OUT/plan.tsv"
    for f in "${FILES[@]}" run_manifest.csv; do mv -f "$stage/$f" "$OUT/$f"; done
    rmdir "$stage"
}
run_logged() {
    local log=$1 rc=0; shift
    setsid "$@" >"$log" 2>&1 9>&- & PID=$!
    wait "$PID" || rc=$?
    PID=
    return "$rc"
}
READY=1
TOTAL=$(awk 'END {print NR-1}' "$OUT/plan.tsv")
[[ "$TOTAL" == 460 ]] || fail "Invalid plan count."
aggregate
DONE=$(awk -F, '$NF=="DONE" {n++} END {print n+0}' "$OUT/run_manifest.csv")
echo "DEMO 2: $TOTAL cases; completed $DONE; RNG 1 2 3 4 5"
echo "MCS9 BCC 20/20MHz NSS1 GI3200ns radius5m; output: $OUT"
if (( DONE == TOTAL )); then echo "Already complete."; exit 0; fi
if ! run_logged "$OUT/logs/configure.log" cmake -S "$ROOT" -B "$ROOT/cmake-cache"; then
    tail -n 30 "$OUT/logs/configure.log"; fail "Configure failed."
fi
if ! run_logged "$OUT/logs/build.log" cmake --build "$ROOT/cmake-cache" --target scratch_demo-2-sta-scaling --parallel 4; then
    tail -n 40 "$OUT/logs/build.log"; fail "Build failed."
fi
while IFS=$'\t' read -r id n rate mode run; do
    [[ "$id" == case_id ]] && continue
    dir="$OUT/cases/$id"
    if valid_case "$dir"; then continue; fi
    if [[ -e "$dir" ]]; then
        archived=$(mktemp -d "$OUT/invalid/${id}.XXXXXX")
        mv "$dir" "$archived/case"
    fi
    work=$(mktemp -d "$OUT/.work-${id}.XXXXXX")
    echo "[$((DONE+1))/$TOTAL] $id"
    rc=0
    run_logged "$work/run.log" timeout --signal=TERM --kill-after=10s 1800s \
        ./ns3 run --no-build scratch/demo-2-sta-scaling -- \
        "--mode=$mode" "--nSta=$n" "--offeredLoad=$rate" --seed=1 \
        "--run=$run" "--caseId=$id" "--out=$work" || rc=$?
    if (( rc != 0 )); then
        aggregate; tail -n 40 "$work/run.log"
        fail "$id failed (exit $rc). Log: $work/run.log"
    fi
    validate "$work" "$id" "$n" "$rate" "$mode" "$run" || fail "CSV check failed: $work"
    (cd "$work" && sha256sum "${FILES[@]}" >.done)
    mv "$work" "$dir"
    DONE=$((DONE+1))
    if (( DONE % 5 == 0 )); then aggregate; fi
done <"$OUT/plan.tsv"
aggregate
echo "DONE: $DONE/$TOTAL. Results: $OUT"
