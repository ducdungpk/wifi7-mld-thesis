from pathlib import Path
import argparse
import hashlib
import itertools
import json
import sys

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

COUNTS = {1: 290, 2: 460, 3: 25, 4: 125, 5: 535}
METRICS = ['throughput_mbps', 'throughput_5g_mbps',
           'throughput_6g_mbps', 'delay_ms', 'jitter_ms',
           'loss_pct', 'jain_sta']
PANELS = [('throughput_mbps', 'Throughput IP (Mbps)'),
          ('loss_pct', 'Mất gói (%)'),
          ('delay_ms', 'Độ trễ (ms)'),
          ('jain_sta', 'Jain fairness')]
KEYS = ['demo', 'scenario', 'mode', 'n_sta',
        'offered_per_sta_mbps', 'width5_mhz', 'width6_mhz',
        'split_ratio', 'speed_mps', 'nakagami_m']
LABELS = {'slo5': 'SLO 5 GHz', 'slo6': 'SLO 6 GHz', 'mlo': 'MLD',
          'mlo_balanced': 'MLD: STA xen kẽ',
          'mlo_static': 'MLD: STA theo nhóm'}
plt.rcParams.update({'font.family': 'DejaVu Sans', 'font.size': 10,
                     'axes.spines.top': False,
                     'axes.spines.right': False,
                     'savefig.dpi': 300, 'pdf.fonttype': 42})


def require(condition, message):
    if not bool(condition):
        raise ValueError(message)


def expected_ids(demo):
    ids = set()
    for run in range(1, 6):
        if demo == 1:
            rates = {1: [1, 5, 10, 20, 40, 60, 80, 100, 120,
                         160, 200, 300, 400, 500],
                     5: [1, 3, 5, 7, 9, 11, 13, 15, 17,
                         20, 25, 30, 40, 60, 100]}
            for n, rr in rates.items():
                for r, m in itertools.product(rr, ['slo5', 'mlo']):
                    ids.add(f'D1_N{n}_R{r}_{m}_run{run}')
        elif demo == 2:
            nn = list(range(1, 18)) + [20, 25, 30, 35, 40, 50]
            for n, r, m in itertools.product(nn, [5, 10], ['slo5', 'mlo']):
                ids.add(f'D2_N{n}_R{r}_{m}_run{run}')
        elif demo == 3:
            for m, r, w in [('slo5', 20, 20), ('slo6', 20, 20),
                            ('slo5', 40, 20), ('slo5', 40, 40),
                            ('slo5', 40, 80)]:
                ids.add(f'D3_N5_R{r}_{m}_W{w}_run{run}')
        elif demo == 4:
            cc = [('mode', m, 10, 20, 0.5)
                  for m in ['slo5', 'mlo_balanced', 'mlo_static']]
            cc += [('ratio', 'mlo_static', 10, 20, i / 10)
                   for i in range(1, 10)]
            cc += [('load', 'mlo_static', 10, r, 0.5)
                   for r in range(10, 41, 5)]
            cc += [('sta', 'mlo_static', n, 20, 0.5)
                   for n in [5, 10, 15, 20, 25, 30]]
            for g, m, n, r, q in cc:
                token = str(q).replace('.', 'p')
                ids.add(f'D4_{g}_N{n}_R{r}_{m}_S{token}_run{run}')
        else:
            cc = [('baseline', '1.5', '2', 10)]
            cc += [('mobility', v, '2', 10)
                   for v in ['0', '0.5', '1', '2', '3', '5', '7', '10', '15', '20']]
            cc += [('fading', '1.5', m, 10)
                   for m in ['0.5', '1', '1.5', '2', '2.5', '3', '4']]
            cc += [('load', '1.5', '2', r)
                   for r in [10, 20, 30, 40, 50, 60, 70, 80, 90,
                             100, 110, 120, 150, 180, 200, 250, 300]]
            cc += [('stress', str(v), str(m), r)
                   for v, m, r in itertools.product(
                       [0, 1, 2, 3], [1, 2, 3], [30, 40, 50, 60, 70, 80])]
            for g, v, m, r in cc:
                vt, mt = v.replace('.', 'p'), m.replace('.', 'p')
                ids.add(f'D5_{g}_N10_R{r}_mlo_V{vt}_M{mt}_run{run}')
    return ids


def close(a, b, message):
    require(np.allclose(np.asarray(a, dtype=float),
                        np.asarray(b, dtype=float),
                        rtol=1e-8, atol=1e-7, equal_nan=True), message)


def load_demo(root, demo):
    folder = root / f'results_demo_{demo}_rng5'
    frames, hashes = {}, {}
    for name in ['summary', 'per_sta', 'per_link', 'run_manifest']:
        p = folder / f'{name}.csv'
        require(p.is_file(), f'Thieu file: {p}')
        frames[name] = pd.read_csv(p, encoding='utf-8-sig')
        hashes[str(p.resolve())] = hashlib.sha256(p.read_bytes()).hexdigest()
    s, a, b, manifest = (frames[k] for k in
                         ['summary', 'per_sta', 'per_link', 'run_manifest'])
    expected = expected_ids(demo)
    for name, frame in frames.items():
        require(set(frame.case_id) == expected,
                f'Demo {demo}: case_id thieu/thua trong {name}')
    require(len(s) == len(manifest) == COUNTS[demo], 'Sai so case')
    require(not s.case_id.duplicated().any(), 'Trung summary')
    require(not manifest.case_id.duplicated().any(), 'Trung manifest')
    require(s.status.eq('PASS').all(), f'Demo {demo}: co case khong PASS')
    require(manifest.status.eq('DONE').all(), 'Manifest chua DONE')
    require(s.demo.eq(demo).all(), 'Sai demo')
    for frame in [a, b]:
        require(frame.demo.eq(demo).all(), 'Sai demo chi tiet')
    for frame, key in [(a, 'sta_id'), (b, 'phy_id')]:
        require(not frame.duplicated(['case_id', key]).any(), 'Trung dong chi tiet')
    si = s.set_index('case_id')
    for frame, key in [(a, 'sta_id'), (b, 'phy_id')]:
        for cid, group in frame.groupby('case_id'):
            n = int(si.loc[cid, 'n_sta']) if key == 'sta_id' else (
                2 if str(si.loc[cid, 'mode']).startswith('mlo') else 1)
            require(set(group[key]) == set(range(n)), f'{cid}: sai chi so {key}')
    for frame in [s, a, b]:
        require((frame.rx_packets <= frame.tx_packets).all(), 'rx > tx')
        require((frame[['tx_packets', 'rx_packets', 'rx_bytes']] >= 0).all().all(),
                'Bo dem am')
        close(frame.rx_bytes, frame.rx_packets * 1228, 'Sai byte IP')
        close(frame.throughput_mbps, frame.rx_bytes * 8 / 9e6, 'Sai throughput')
        loss = 100 * (frame.tx_packets - frame.rx_packets) / frame.tx_packets.replace(0, np.nan)
        close(frame.loss_pct, loss, 'Sai loss')
        require(frame.loc[frame.rx_packets.eq(0), ['delay_ms', 'jitter_ms']]
                .isna().all().all(), 'Zero RX phai co delay/jitter NA')
    for frame in [a, b]:
        totals = frame.groupby('case_id')[['tx_packets', 'rx_packets', 'rx_bytes']].sum()
        close(si.loc[totals.index, totals.columns], totals, 'Tong chi tiet khong khop')
        delay_sum = (frame.delay_ms.fillna(0) * frame.rx_packets).groupby(frame.case_id).sum()
        delay = delay_sum / si.rx_packets.replace(0, np.nan)
        close(si.loc[delay.index, 'delay_ms'], delay, 'Sai delay co trong so')
    throughput = a.groupby('case_id').throughput_mbps
    jain = throughput.sum().pow(2) / (si.n_sta * throughput.apply(lambda x: (x*x).sum()))
    close(si.loc[jain.index, 'jain_sta'], jain, 'Sai Jain')
    for band in [5, 6]:
        col = f'throughput_{band}g_mbps'
        sta_total = a.groupby('case_id')[col].sum()
        link_total = b[b.band_ghz.eq(band)].groupby('case_id').throughput_mbps.sum()
        close(si.loc[sta_total.index, col], sta_total, 'Sai tong band STA')
        close(si[col], link_total.reindex(si.index, fill_value=0), 'Sai tong band link')
    close(s.sim_stop_s - s.app_start_s, 9, 'Sai thoi gian do')
    for col, value in {'mcs': 9, 'nss': 1, 'gi_ns': 3200,
                       'payload_bytes': 1200, 'seed': 1, 'radius_m': 5}.items():
        require(s[col].eq(value).all(), f'Sai cau hinh {col}')
    require(s.coding.eq('BCC').all(), 'Sai coding')
    for col in ['demo', 'mode', 'n_sta', 'offered_per_sta_mbps', 'rng_run']:
        require(manifest.set_index('case_id')[col].reindex(si.index).eq(si[col]).all(),
                f'Manifest khong khop {col}')
    s['scenario'] = s.case_id.str.extract(r'^D[45]_([^_]+)_', expand=False).fillna('main')
    if demo == 4:
        s['split_ratio'] = s.case_id.map(manifest.set_index('case_id').split_ratio)
    else:
        s['split_ratio'] = 0.0
    if demo != 5:
        s['speed_mps'] = 0.0
        s['nakagami_m'] = 0.0
    groups = s.groupby(KEYS, dropna=False)
    for _, group in groups:
        require(len(group) == 5 and set(group.rng_run) == set(range(1, 6)),
                'Nhom khong du 5 RNG; khong tu loai run')
    for frame in [a, b]:
        meta = s[['case_id', 'rng_run'] + KEYS]
        extra = [col for col in meta.columns if col == 'case_id' or col not in frame.columns]
        frame_meta = frame.merge(meta[extra], on='case_id', validate='many_to_one')
        if frame is a:
            a = frame_meta
        else:
            b = frame_meta
    audit = {'demo': demo, 'cases': len(s), 'configurations': len(groups),
             'sta_rows': len(a), 'link_rows': len(b),
             'zero_rx_sta': int(((a.tx_packets > 0) & a.rx_packets.eq(0)).sum()),
             'zero_rx_link': int(((b.tx_packets > 0) & b.rx_packets.eq(0)).sum())}
    return s, a, b, audit, hashes


def statistics_table(frame, keys, metrics):
    result = frame.groupby(keys, dropna=False)[metrics].agg(['mean', 'std', 'count'])
    result.columns = [f'{metric}_{stat}' for metric, stat in result.columns]
    return result.reset_index()


def save_csv(frame, path):
    frame.to_csv(path, index=False, encoding='utf-8-sig', na_rep='NA')


def save_figure(fig, folder, name):
    fig.savefig(folder / f'{name}.png', dpi=300, bbox_inches='tight')
    fig.savefig(folder / f'{name}.pdf', bbox_inches='tight')
    plt.close(fig)


def four_panels(data, x, xlabel, title, folder, name, bars=False, series='mode'):
    require(not data.empty, f'Khong co du lieu cho hinh {name}')
    fig, axes = plt.subplots(2, 2, figsize=(10.5, 7), constrained_layout=True)
    for ax, (metric, ylabel) in zip(axes.flat, PANELS):
        if bars:
            z = data.sort_values(x)
            labels = [LABELS.get(str(v), str(v)) for v in z[x]]
            ax.bar(np.arange(len(z)), z[f'{metric}_mean'],
                   yerr=z[f'{metric}_std'], capsize=4,
                   color=['#497da6', '#bc8049', '#679574', '#9c79a8'][:len(z)])
            ax.set_xticks(np.arange(len(z)), labels)
            ax.tick_params(axis='x', labelsize=9)
        else:
            for label, z in data.groupby(series, sort=True):
                z = z.sort_values(x)
                require(not z[x].duplicated().any(), f'Trung diem x: {name}, {label}')
                ax.errorbar(z[x], z[f'{metric}_mean'],
                            yerr=z[f'{metric}_std'], marker='o',
                            markersize=4, capsize=3, linewidth=1.4,
                            label=LABELS.get(str(label), str(label)))
            ax.legend(fontsize=9)
        ax.set_xlabel(xlabel)
        ax.set_ylabel(ylabel)
        ax.grid(axis='y', alpha=0.25)
        ax.set_axisbelow(True)
        if metric in ['loss_pct', 'jain_sta']:
            ax.set_ylim(0, 100 if metric == 'loss_pct' else 1.05)
    fig.suptitle(title + '\nTrung bình ± SD; 5 RNG', fontsize=12)
    save_figure(fig, folder, name)


def plot_demo(g, demo, folder):
    if demo == 1:
        for n in [1, 5]:
            four_panels(g[g.n_sta.eq(n)], 'offered_per_sta_mbps',
                        'Tải payload mỗi STA (Mbps)', f'Demo 1 - {n} STA',
                        folder, f'd1_load_N{n}')
    elif demo == 2:
        for rate in [5, 10]:
            four_panels(g[g.offered_per_sta_mbps.eq(rate)], 'n_sta',
                        'Số STA', f'Demo 2 - {rate} Mbps/STA',
                        folder, f'd2_sta_R{rate}')
    elif demo == 3:
        four_panels(g[g.offered_per_sta_mbps.eq(20)], 'mode', 'Băng tần',
                    'Demo 3 - 20 MHz; 20 Mbps/STA', folder, 'd3_band', bars=True)
        four_panels(g[g.offered_per_sta_mbps.eq(40)], 'width5_mhz',
                    'Độ rộng kênh (MHz)', 'Demo 3 - 5 GHz; 40 Mbps/STA',
                    folder, 'd3_width', bars=True)
    elif demo == 4:
        for scenario, x, xlabel in [('mode', 'mode', 'Cách gán STA'),
                                    ('ratio', 'split_ratio', 'Tỷ lệ STA vào 5 GHz'),
                                    ('load', 'offered_per_sta_mbps', 'Tải payload mỗi STA (Mbps)'),
                                    ('sta', 'n_sta', 'Số STA')]:
            four_panels(g[g.scenario.eq(scenario)], x, xlabel,
                        f'Demo 4 - {scenario}', folder, f'd4_{scenario}',
                        bars=scenario == 'mode')
    else:
        for scenario, x, xlabel in [('mobility', 'speed_mps', 'Tốc độ (m/s)'),
                                    ('fading', 'nakagami_m', 'Hệ số Nakagami m'),
                                    ('load', 'offered_per_sta_mbps', 'Tải payload mỗi STA (Mbps)')]:
            four_panels(g[g.scenario.eq(scenario)], x, xlabel,
                        f'Demo 5 - {scenario}', folder, f'd5_{scenario}')
        stress = g[g.scenario.eq('stress')]
        for metric, ylabel in [PANELS[0], PANELS[3]]:
            fig, axes = plt.subplots(2, 2, figsize=(10.5, 7), constrained_layout=True)
            for ax, speed in zip(axes.flat, [0, 1, 2, 3]):
                for m, z in stress[stress.speed_mps.eq(speed)].groupby('nakagami_m'):
                    z = z.sort_values('offered_per_sta_mbps')
                    ax.errorbar(z.offered_per_sta_mbps, z[f'{metric}_mean'],
                                yerr=z[f'{metric}_std'], marker='o', capsize=3,
                                markersize=4, label=f'm={m:g}')
                ax.set_title(f'v={speed} m/s')
                ax.set_xlabel('Tải payload mỗi STA (Mbps)')
                ax.set_ylabel(ylabel)
                ax.grid(alpha=0.25)
                ax.legend()
                if metric == 'jain_sta':
                    ax.set_ylim(0, 1.05)
            fig.suptitle('Demo 5 - Điều kiện kết hợp; trung bình ± SD; 5 RNG')
            save_figure(fig, folder, f'd5_stress_{metric}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent,
                        help='Thu muc chua 5 folder results_demo_N_rng5')
    args = parser.parse_args()
    root = args.root.resolve()
    # Validate every demo before producing any statistical output.
    loaded = {d: load_demo(root, d) for d in range(1, 6)}
    out = root / 'analysis_results'
    out.mkdir(exist_ok=True)
    all_hashes, audits = {}, []
    for demo, (s, a, b, audit, hashes) in loaded.items():
        folder = out / f'demo_{demo}'
        folder.mkdir(exist_ok=True)
        g = statistics_table(s, KEYS, METRICS)
        save_csv(g, folder / 'summary_mean_sd.csv')
        save_csv(statistics_table(a, KEYS + ['sta_id'],
                                 [m for m in METRICS if m != 'jain_sta']),
                 folder / 'per_sta_mean_sd.csv')
        save_csv(statistics_table(b, KEYS + ['phy_id', 'band_ghz', 'width_mhz'],
                                 ['throughput_mbps', 'delay_ms', 'jitter_ms', 'loss_pct']),
                 folder / 'per_link_mean_sd.csv')
        save_csv(s, folder / 'runs_with_metadata.csv')
        plot_demo(g, demo, folder)
        audits.append(audit)
        all_hashes.update(hashes)
        print(f'Demo {demo}: {len(s)} case; {len(g)} nhom; OK')
    save_csv(pd.DataFrame(audits), out / 'data_check.csv')
    (out / 'input_sha256.json').write_text(
        json.dumps(all_hashes, indent=2, ensure_ascii=False), encoding='utf-8')
    method = ('Mean = arithmetic mean across the five RNG runs.\n'
              'SD = sample standard deviation, ddof=1. Error bars are SD, not CI.\n'
              'Zero values are retained. NA is never replaced with zero.\n'
              'Each metric_count records the number of defined run values.\n'
              'Scenario groups remain separate; repeated baseline configurations\n'
              'across groups are not pooled as additional independent RNG runs.\n'
              'Offered load = UDP payload Mbps per STA; throughput = IP Mbps.\n'
              'Delay/jitter describe received packets only.\n'
              'Jain is computed per run across STAs, then averaged across runs.\n'
              'Demo 5 radius_m = initial radius; STA coordinates = final positions.\n'
              'Raw CSV files are read only. PNG/PDF figures use unsmoothed data.\n'
              'Python: ' + sys.version + '\nPandas: ' + pd.__version__ +
              '\nNumPy: ' + np.__version__ + '\nMatplotlib: ' + matplotlib.__version__)
    (out / 'analysis_method.txt').write_text(method, encoding='utf-8')
    print(f'HOAN THANH: {out}')
    print('15 hinh PNG + 15 hinh PDF; CSV mean/std/count cho tung demo.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError) as exc:
        raise SystemExit(f'ERROR: {exc}') from exc
