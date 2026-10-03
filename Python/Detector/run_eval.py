#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
run_eval.py -- Phase-2 detector evaluation driver (DETECTOR_DESIGN.md par.4-5).

One deterministic pass per channel:
  1. train semi-supervised zoo on TRAIN normal steps, supervised zoo on all TRAIN
  2. calibrate every alarm threshold on clean VAL steps at 1% FPR (same alpha as BDD)
  3. evaluate: in-distribution TEST x5 (t-CIs), magnitude sweep + impact overlay,
     naive same-norm sanity, limited-access BDD-union coverage, cross-channel
     supervised stress, contamination study, F1/F2/F3 feature ablation,
     cadence sweep for the temporal (delta-z) component (PHASE2_NOTES E1 guard)
  4. write results/eval_<CH>.json + flat CSV tables under results/tables/

Pre-registered headline: semi-supervised PCA-SPE on F1 (raw z). Everything else
is reported alongside, including where models fail (e.g. IForest on QV).

Usage: python run_eval.py [--channels PF QV] [--skip-contam] [--skip-cadence]
"""
import argparse
import json
import os
import numpy as np

import data as D
from models import semisup_zoo, supervised_zoo, threshold_at_fpr, tci, SEED
from sklearn.preprocessing import StandardScaler
from sklearn.metrics import roc_auc_score, average_precision_score
from gridmodel import PHYS_IDX

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(HERE, 'results')
FPR_TARGET = 0.01
CONTAM_RATES = [0.005, 0.01, 0.02, 0.05]
ORACLE_COLS = [PHYS_IDX['df_spread']] + list(range(39, 43))  # df_spread + 4 qv_res


# ---------------------------------------------------------------- features
def build_features(run, fs, phys=None):
    """Assemble a feature matrix for one run. fs in {F1,F2,F3,F1d}."""
    if fs == 'F1':
        return run['X']
    if fs == 'F1d':
        return np.hstack([run['X'], D.delta_features(run['X'])])
    if phys is None:
        phys = D.physics_features(run['name'], run['ch'])
    if fs == 'F2':
        return phys
    if fs == 'F3':
        return np.hstack([run['X'], phys])
    raise ValueError(fs)


def metrics_block(scores, y, stealthy, thr):
    """Standard metric set on one evaluated run at a deployed threshold."""
    y = y.astype(bool)
    st = y & stealthy
    normal = ~y
    out = {
        'tpr_stealthy': float((scores[st] > thr).mean()) if st.sum() else float('nan'),
        'tpr_all': float((scores[y] > thr).mean()) if y.sum() else float('nan'),
        'fpr': float((scores[normal] > thr).mean()),
        'n_stealthy': int(st.sum()), 'n_attack': int(y.sum()),
        'n_normal': int(normal.sum()),
    }
    keep = normal | st          # headline population: normals + stealthy attacks
    if st.sum():
        out['auc_stealthy'] = float(roc_auc_score(y[keep], scores[keep]))
        out['ap_stealthy'] = float(average_precision_score(y[keep], scores[keep]))
    return out


class OracleDetector:
    """Physics-oracle: max |z-scored droop-consistency residual| (model-based
    information bound; requires exact droop parameters)."""
    def fit(self, phys_normal):
        B = phys_normal[:, ORACLE_COLS]
        self.mu = B.mean(axis=0)
        self.sd = B.std(axis=0) + 1e-12
        return self
    def score(self, phys):
        return np.max(np.abs((phys[:, ORACLE_COLS] - self.mu)/self.sd), axis=1)


# ---------------------------------------------------------------- channel run
def eval_channel(ch, skip_contam=False, skip_cadence=False):
    print('\n================ CHANNEL %s ================' % ch, flush=True)
    train = D.load_run('TRAIN', ch)
    val = D.load_run('VAL', ch)
    tests = [D.load_run(r, ch, variants=True) for r in D.TEST_RUNS]

    phys_train = D.physics_features('TRAIN', ch)
    phys_val = D.physics_features('VAL', ch)
    phys_tests = {t['name']: D.physics_features(t['name'], ch) for t in tests}

    norm_tr = train['y'] == 0
    res = {'channel': ch, 'fpr_target': FPR_TARGET, 'headline': 'PCA-SPE/F1',
           'n_train': int(len(train['y'])), 'n_train_normal': int(norm_tr.sum())}

    # ---------------- train + calibrate all (model, feature-set) pairs ------
    featsets = ['F1', 'F2', 'F3']
    fitted = {}     # (kind, mname, fs) -> dict(scaler, model, thr)
    for fs in featsets:
        Ftr = build_features(train, fs, phys_train)
        Fva = build_features(val, fs, phys_val)
        va_norm = Fva[val['y'] == 0]

        sc_semi = StandardScaler().fit(Ftr[norm_tr])
        for name, m in semisup_zoo().items():
            m.fit(sc_semi.transform(Ftr[norm_tr]))
            thr = threshold_at_fpr(m.score(sc_semi.transform(va_norm)), FPR_TARGET)
            fitted[('semi', name, fs)] = dict(scaler=sc_semi, model=m, thr=thr)
            print('  trained semi %-8s %s' % (name, fs), flush=True)

        sc_sup = StandardScaler().fit(Ftr)
        for name, m in supervised_zoo().items():
            m.fit(sc_sup.transform(Ftr), train['y'])
            thr = threshold_at_fpr(m.score(sc_sup.transform(va_norm)), FPR_TARGET)
            fitted[('sup', name, fs)] = dict(scaler=sc_sup, model=m, thr=thr)
            print('  trained sup  %-8s %s' % (name, fs), flush=True)

    # physics oracle (threshold from clean VAL like everyone else)
    oracle = OracleDetector().fit(phys_train[norm_tr])
    thr_oracle = threshold_at_fpr(oracle.score(phys_val[val['y'] == 0]), FPR_TARGET)

    # ---------------- in-distribution TEST (5 runs, t-CIs) ------------------
    print('  evaluating TEST x%d ...' % len(tests), flush=True)
    per_run = {k: [] for k in list(fitted) + [('bdd', 'BDD', '-'),
                                              ('oracle', 'Oracle', 'F2')]}
    for t in tests:
        pt = phys_tests[t['name']]
        for (kind, name, fs), f in fitted.items():
            F = build_features(t, fs, pt)
            s = f['model'].score(f['scaler'].transform(F))
            per_run[(kind, name, fs)].append(
                metrics_block(s, t['y'], t['stealthy'], f['thr']))
        # BDD from the frozen sim's own logs
        bdd_scores = t['J'] - t['tau']
        per_run[('bdd', 'BDD', '-')].append(
            metrics_block(bdd_scores, t['y'], t['stealthy'], 0.0))
        per_run[('oracle', 'Oracle', 'F2')].append(
            metrics_block(oracle.score(pt), t['y'], t['stealthy'], thr_oracle))

    def aggregate(blocks):
        agg = {}
        for key in ['tpr_stealthy', 'tpr_all', 'fpr', 'auc_stealthy', 'ap_stealthy']:
            vals = [b[key] for b in blocks if key in b and not np.isnan(b[key])]
            if vals:
                m, hw = tci(vals)
                agg[key] = m
                agg[key + '_ci'] = hw
        agg['n_stealthy_total'] = int(sum(b['n_stealthy'] for b in blocks))
        return agg

    res['test'] = {'%s|%s|%s' % k: aggregate(v) for k, v in per_run.items()}

    # dump concatenated TEST scores for the paper's distribution figures
    dump = {'y': [], 'stealthy': [], 'des': [], 'rdev': [], 'bdd_margin': [],
            'spe_f1': [], 'ae_f1': [], 'oracle': [], 'run': []}
    for t in tests:
        pt = phys_tests[t['name']]
        fS = fitted[('semi', 'PCA-SPE', 'F1')]
        fA = fitted[('semi', 'AE-MLP', 'F1')]
        dump['spe_f1'].append(fS['model'].score(fS['scaler'].transform(t['X'])))
        dump['ae_f1'].append(fA['model'].score(fA['scaler'].transform(t['X'])))
        dump['oracle'].append(oracle.score(pt))
        dump['bdd_margin'].append(t['J'] - t['tau'])
        dump['y'].append(t['y']); dump['stealthy'].append(t['stealthy'])
        dump['des'].append(t['des']); dump['rdev'].append(t['rdev'])
        dump['run'].append(np.full(len(t['y']), int(t['name'][-3:])))
    np.savez_compressed(
        os.path.join(RES, 'scores_%s.npz' % ch),
        thr_spe=fitted[('semi', 'PCA-SPE', 'F1')]['thr'],
        thr_ae=fitted[('semi', 'AE-MLP', 'F1')]['thr'],
        thr_oracle=thr_oracle,
        **{k: np.concatenate(v) for k, v in dump.items()})

    # ---------------- magnitude sweep + impact overlay ----------------------
    print('  magnitude sweep ...', flush=True)
    shed = 'UFLS' if ch == 'PF' else 'UVLS'
    mag_rows = []
    for mname, mscale in zip(D.MAG_RUNS, D.MAG_SCALES):
        r = D.load_run(mname, ch)
        pm = D.physics_features(mname, ch)
        st = (r['y'] == 1) & r['stealthy']
        row = {'magScale': mscale, 'n_stealthy': int(st.sum()),
               'mean_abs_dev': float(np.nanmean(np.abs(r['rdev'][st]))) if st.sum() else float('nan'),
               'p_shed': float((r['ev'][st] == shed).mean()) if st.sum() else float('nan'),
               'mean_footprint': float(r['fp'][st].mean()) if st.sum() else float('nan')}
        for key in [('semi', 'PCA-SPE', 'F1'), ('semi', 'AE-MLP', 'F1'),
                    ('semi', 'PCA-SPE', 'F3'), ('sup', 'RF', 'F1'),
                    ('sup', 'LogReg', 'F1')]:
            f = fitted[key]
            F = build_features(r, key[2], pm)
            s = f['model'].score(f['scaler'].transform(F))
            row['tpr_%s_%s' % (key[1], key[2])] = float((s[st] > f['thr']).mean()) if st.sum() else float('nan')
        row['tpr_BDD'] = float((r['J'][st] >= r['tau'][st]).mean()) if st.sum() else float('nan')
        so = oracle.score(pm)
        row['tpr_Oracle'] = float((so[st] > thr_oracle).mean()) if st.sum() else float('nan')
        mag_rows.append(row)
    res['magnitude_sweep'] = mag_rows

    # ---------------- naive + limited-access variants -----------------------
    print('  attack variants (naive / limited access) ...', flush=True)
    var_keys = [('semi', 'PCA-SPE', 'F1'), ('semi', 'AE-MLP', 'F1'),
                ('sup', 'RF', 'F1'), ('sup', 'LogReg', 'F1')]
    variants = {}
    for vtag, zkey, jkey in [('naive', 'Zn', 'Jn'), ('limited', 'Zlim', 'Jlim')]:
        rows = []
        for t in tests:
            atk = t['y'] == 1
            Zv = t[zkey][atk]
            ok = ~np.isnan(Zv).any(axis=1)
            Zv = Zv[ok]
            bdd_caught = (t[jkey][atk][ok] >= t['tau'][atk][ok])
            entry = {'run': t['name'], 'n': int(Zv.shape[0]),
                     'bdd_tpr': float(bdd_caught.mean())}
            pv = D.physics_features(t['name'], ch, Z=Zv, tag='_' + vtag) \
                if any(k[2] != 'F1' for k in var_keys) else None
            for kind, name, fs in var_keys:
                f = fitted[(kind, name, fs)]
                rr = dict(t); rr['X'] = Zv
                F = build_features(rr, fs, pv)
                s = f['model'].score(f['scaler'].transform(F))
                ml_caught = s > f['thr']
                entry['ml_tpr_%s_%s' % (name, fs)] = float(ml_caught.mean())
                entry['union_tpr_%s_%s' % (name, fs)] = float((ml_caught | bdd_caught).mean())
            rows.append(entry)
        variants[vtag] = rows
    res['variants'] = variants

    # ---------------- contamination study (semi-sup, F1) --------------------
    if not skip_contam:
        print('  contamination study ...', flush=True)
        rng = np.random.default_rng(SEED)
        atk_idx = np.where(train['y'] == 1)[0]
        contam = []
        Ftr = build_features(train, 'F1', phys_train)
        Fva_norm = build_features(val, 'F1', phys_val)[val['y'] == 0]
        for rate in CONTAM_RATES:
            n_norm = int(norm_tr.sum())
            n_add = int(round(rate*n_norm/(1 - rate)))
            add = rng.choice(atk_idx, size=min(n_add, len(atk_idx)), replace=False)
            sel = np.concatenate([np.where(norm_tr)[0], add])
            sc = StandardScaler().fit(Ftr[sel])
            entry = {'rate': rate, 'n_added_attacks': int(len(add))}
            for name, m in semisup_zoo().items():
                m.fit(sc.transform(Ftr[sel]))
                thr = threshold_at_fpr(m.score(sc.transform(Fva_norm)), FPR_TARGET)
                tprs, fprs = [], []
                for t in tests:
                    s = m.score(sc.transform(t['X']))
                    st = (t['y'] == 1) & t['stealthy']
                    tprs.append(float((s[st] > thr).mean()))
                    fprs.append(float((s[t['y'] == 0] > thr).mean()))
                mtpr, htpr = tci(tprs); mfpr, hfpr = tci(fprs)
                entry[name] = {'tpr_stealthy': mtpr, 'tpr_ci': htpr,
                               'fpr': mfpr, 'fpr_ci': hfpr}
            contam.append(entry)
        res['contamination'] = contam

    # ---------------- cadence sweep (temporal-feature honesty guard) --------
    if not skip_cadence:
        print('  cadence sweep (F1 vs F1+delta) ...', flush=True)
        cad_keys = [('semi', 'PCA-SPE'), ('sup', 'RF')]
        # train the F1d variants (same protocol as the main pairs)
        f1d = {}
        Ftr = build_features(train, 'F1d')
        Fva = build_features(val, 'F1d')
        va_norm = Fva[val['y'] == 0]
        sc_semi = StandardScaler().fit(Ftr[norm_tr])
        m = semisup_zoo()['PCA-SPE'].fit(sc_semi.transform(Ftr[norm_tr]))
        f1d[('semi', 'PCA-SPE')] = dict(
            scaler=sc_semi, model=m,
            thr=threshold_at_fpr(m.score(sc_semi.transform(va_norm)), FPR_TARGET))
        sc_sup = StandardScaler().fit(Ftr)
        m = supervised_zoo()['RF'].fit(sc_sup.transform(Ftr), train['y'])
        f1d[('sup', 'RF')] = dict(
            scaler=sc_sup, model=m,
            thr=threshold_at_fpr(m.score(sc_sup.transform(va_norm)), FPR_TARGET))

        cadence = []
        for cname in D.CAD_RUNS:
            r = D.load_run(cname, ch)
            st = (r['y'] == 1) & r['stealthy']
            entry = {'run': cname, 'n_stealthy': int(st.sum()),
                     'attack_frac': float((r['y'] == 1).mean())}
            for kind, name in cad_keys:
                fA = fitted[(kind, name, 'F1')]
                sA = fA['model'].score(fA['scaler'].transform(build_features(r, 'F1')))
                fB = f1d[(kind, name)]
                sB = fB['model'].score(fB['scaler'].transform(build_features(r, 'F1d')))
                entry['tpr_%s_F1' % name] = float((sA[st] > fA['thr']).mean()) if st.sum() else float('nan')
                entry['tpr_%s_F1d' % name] = float((sB[st] > fB['thr']).mean()) if st.sum() else float('nan')
                if (r['y'] == 0).sum():
                    entry['fpr_%s_F1' % name] = float((sA[r['y'] == 0] > fA['thr']).mean())
                    entry['fpr_%s_F1d' % name] = float((sB[r['y'] == 0] > fB['thr']).mean())
            cadence.append(entry)
        res['cadence'] = cadence

    # keep fitted supervised F1/F3 models for the cross-channel test
    keep = {k: v for k, v in fitted.items() if k[0] == 'sup' and k[2] in ('F1', 'F3')}
    return res, keep


def cross_channel(fitted_by_ch):
    """Supervised detectors trained on channel A, deployed (A's threshold) on B."""
    out = []
    for src, dst in [('PF', 'QV'), ('QV', 'PF')]:
        tests = [D.load_run(r, dst, variants=False) for r in D.TEST_RUNS]
        phys = {t['name']: D.physics_features(t['name'], dst) for t in tests}
        for (kind, name, fs), f in fitted_by_ch[src].items():
            tprs, fprs = [], []
            for t in tests:
                F = build_features(t, fs, phys[t['name']])
                s = f['model'].score(f['scaler'].transform(F))
                st = (t['y'] == 1) & t['stealthy']
                tprs.append(float((s[st] > f['thr']).mean()))
                fprs.append(float((s[t['y'] == 0] > f['thr']).mean()))
            mtpr, htpr = tci(tprs); mfpr, hfpr = tci(fprs)
            out.append({'train_ch': src, 'test_ch': dst, 'model': name, 'fs': fs,
                        'tpr_stealthy': mtpr, 'tpr_ci': htpr,
                        'fpr': mfpr, 'fpr_ci': hfpr})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--channels', nargs='+', default=['PF', 'QV'])
    ap.add_argument('--skip-contam', action='store_true')
    ap.add_argument('--skip-cadence', action='store_true')
    args = ap.parse_args()

    os.makedirs(RES, exist_ok=True)
    fitted_by_ch = {}
    for ch in args.channels:
        res, keep = eval_channel(ch, args.skip_contam, args.skip_cadence)
        fitted_by_ch[ch] = keep
        with open(os.path.join(RES, 'eval_%s.json' % ch), 'w') as f:
            json.dump(res, f, indent=2)
        print('wrote results/eval_%s.json' % ch, flush=True)

    if len(fitted_by_ch) == 2:
        xc = cross_channel(fitted_by_ch)
        with open(os.path.join(RES, 'eval_crosschannel.json'), 'w') as f:
            json.dump(xc, f, indent=2)
        print('wrote results/eval_crosschannel.json', flush=True)


if __name__ == '__main__':
    main()
