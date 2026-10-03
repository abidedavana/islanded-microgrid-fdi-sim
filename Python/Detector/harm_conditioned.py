#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
harm_conditioned.py -- the paper's central analysis (Phase-2 reframed).

Operational premise: not all stealthy attacks matter equally. Only those that
cause a physical consequence (load shedding, ev in {UFLS,UVLS}) are dangerous.
We therefore report detection CONDITIONED ON HARM:
    TPR_harm  = P(alarm | stealthy attack AND sheds load)
    TPR_safe  = P(alarm | stealthy attack AND does NOT shed load)
and the safety-critical gap  HBU = 1 - TPR_harm  (harmful-but-undetected rate).

Findings this quantifies:
  (1) manifold detection self-triages by harm (TPR_harm >> TPR_safe);
  (2) the model-free detector (F1) leaves a residual harmful gap on QV;
  (3) physics-informed features (F3, operator's own droop model) close it to
      the physics-oracle floor.

All detectors: thresholds set once on clean VAL at 1% FPR (same alpha as BDD),
semi-supervised models trained on TRAIN normal steps only. Pools stealthy
attacks over TEST(x5)+MAG(x7) for statistical power across the magnitude range.
Writes results/harm_conditioned.json and results/tables/T5_harm.csv.
Independently re-derivable: uses only raw CSVs + cached F2 features.
"""
import os, json, numpy as np
import data as D
from models import PCASPE, AEMLP, threshold_at_fpr, SEED
from sklearn.preprocessing import StandardScaler
from gridmodel import PHYS_IDX

RES = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'results')
ORACLE_COLS = [PHYS_IDX['df_spread']] + list(range(39, 43))  # df_spread + 4 qv_res
POOL = D.TEST_RUNS + D.MAG_RUNS


def oracle_scaler(phys_norm):
    B = phys_norm[:, ORACLE_COLS]
    mu, sd = B.mean(0), B.std(0) + 1e-12
    return lambda P: np.max(np.abs((P[:, ORACLE_COLS] - mu) / sd), axis=1)


def channel(ch):
    tr, va = D.load_run('TRAIN', ch), D.load_run('VAL', ch)
    ptr, pva = D.physics_features('TRAIN', ch), D.physics_features('VAL', ch)
    ntr = tr['y'] == 0
    Xn, vaN = tr['X'][ntr], va['X'][va['y'] == 0]
    pn, pvaN = ptr[ntr], pva[va['y'] == 0]
    shed = 'UFLS' if ch == 'PF' else 'UVLS'

    # detectors + deployed thresholds (all calibrated on clean VAL @1% FPR)
    def fit_semi(model, Xtr, Xval):
        sc = StandardScaler().fit(Xtr)
        m = model.fit(sc.transform(Xtr))
        thr = threshold_at_fpr(m.score(sc.transform(Xval)), 0.01)
        return lambda X: m.score(sc.transform(X)), thr

    det = {}
    det['PCA-SPE (F1, model-free)'] = fit_semi(PCASPE(), Xn, vaN)
    det['AE-MLP (F1, model-free)'] = fit_semi(AEMLP(), Xn, vaN)
    det['PCA-SPE (F3, +droop model)'] = fit_semi(PCASPE(), np.hstack([Xn, pn]), np.hstack([vaN, pvaN]))
    det['AE-MLP (F3, +droop model)'] = fit_semi(AEMLP(), np.hstack([Xn, pn]), np.hstack([vaN, pvaN]))
    orc = oracle_scaler(pn)
    t_or = threshold_at_fpr(orc(pvaN), 0.01)

    # pooled stealthy attacks
    Xs, Ps, EV = [], [], []
    for n in POOL:
        r, p = D.load_run(n, ch), D.physics_features(n, ch)
        m = (r['y'] == 1) & r['stealthy']
        Xs.append(r['X'][m]); Ps.append(p[m]); EV.append(r['ev'][m])
    X, P, EV = np.vstack(Xs), np.vstack(Ps), np.concatenate(EV)
    X3 = np.hstack([X, P])
    harm = EV == shed

    def rate(sc, thr, mask):
        return float((sc[mask] > thr).mean()) if mask.sum() else float('nan')

    rows = {}
    for name, (scf, thr) in det.items():
        Xin = X3 if '(F3' in name else X
        s = scf(Xin)
        rows[name] = {'tpr_harm': rate(s, thr, harm), 'tpr_safe': rate(s, thr, ~harm),
                      'hbu': 1 - rate(s, thr, harm)}
    s = orc(P)
    rows['Physics oracle'] = {'tpr_harm': rate(s, t_or, harm), 'tpr_safe': rate(s, t_or, ~harm),
                              'hbu': 1 - rate(s, t_or, harm)}
    # BDD floor
    Js, taus = [], []
    for n in POOL:
        r = D.load_run(n, ch); m = (r['y'] == 1) & r['stealthy']
        Js.append(r['J'][m]); taus.append(r['tau'][m])
    J, tau = np.concatenate(Js), np.concatenate(taus)
    rows['Residual BDD'] = {'tpr_harm': rate(J, 0, harm) if False else float(((J >= tau) & harm).sum() / harm.sum()),
                            'tpr_safe': float(((J >= tau) & ~harm).sum() / (~harm).sum()),
                            'hbu': 1 - float(((J >= tau) & harm).sum() / harm.sum())}

    # per-magnitude harm-conditioned frontier (F1 model-free vs F3 vs oracle)
    frontier = []
    for mname, mscale in zip(D.MAG_RUNS, D.MAG_SCALES):
        r, p = D.load_run(mname, ch), D.physics_features(mname, ch)
        m = (r['y'] == 1) & r['stealthy']
        hh = (r['ev'][m] == shed)
        if hh.sum() == 0:
            frontier.append({'magScale': mscale, 'n_harmful': 0}); continue
        Xm, Pm = r['X'][m], p[m]
        f1 = det['PCA-SPE (F1, model-free)']
        f3 = det['PCA-SPE (F3, +droop model)']
        frontier.append({
            'magScale': mscale, 'n_harmful': int(hh.sum()),
            'tpr_harm_F1': rate(f1[0](Xm), f1[1], hh),
            'tpr_harm_F3': rate(f3[0](np.hstack([Xm, Pm])), f3[1], hh),
            'tpr_harm_oracle': rate(orc(Pm), t_or, hh)})

    # WITHIN-magnitude harm split: at a FIXED attack size, does the model-free
    # detector still separate harmful from harmless attacks? If yes, the triage
    # is not a magnitude artifact (attacks of equal design magnitude shed load or
    # not depending on the operating point at that step).
    within = []
    f1 = det['PCA-SPE (F1, model-free)']
    for mname, mscale in zip(D.MAG_RUNS, D.MAG_SCALES):
        r = D.load_run(mname, ch)
        m = (r['y'] == 1) & r['stealthy']
        s = f1[0](r['X'][m]); hh = (r['ev'][m] == shed)
        if hh.sum() == 0 or (~hh).sum() == 0:
            continue
        within.append({'magScale': mscale, 'n_harm': int(hh.sum()),
                       'n_safe': int((~hh).sum()),
                       'tpr_harm': rate(s, f1[1], hh),
                       'tpr_safe': rate(s, f1[1], ~hh)})
    return {'channel': ch, 'n_harmful': int(harm.sum()), 'n_safe': int((~harm).sum()),
            'detectors': rows, 'frontier': frontier, 'within_magnitude': within}


def main():
    out = {}
    for ch in ['PF', 'QV']:
        out[ch] = channel(ch)
        r = out[ch]
        print('\n===== %s  (harmful=%d, harmless=%d) =====' % (ch, r['n_harmful'], r['n_safe']))
        print('  %-30s %9s %9s %8s' % ('detector', 'TPR|harm', 'TPR|safe', 'HBU'))
        for name, e in r['detectors'].items():
            print('  %-30s %9.3f %9.3f %8.3f' % (name, e['tpr_harm'], e['tpr_safe'], e['hbu']))
    os.makedirs(os.path.join(RES, 'tables'), exist_ok=True)
    with open(os.path.join(RES, 'harm_conditioned.json'), 'w') as f:
        json.dump(out, f, indent=2)
    # flat table
    lines = ['channel,detector,tpr_harm,tpr_safe,hbu']
    for ch in ['PF', 'QV']:
        for name, e in out[ch]['detectors'].items():
            lines.append('%s,%s,%.4f,%.4f,%.4f' % (ch, name, e['tpr_harm'], e['tpr_safe'], e['hbu']))
    with open(os.path.join(RES, 'tables', 'T5_harm.csv'), 'w') as f:
        f.write('\n'.join(lines))
    print('\nwrote results/harm_conditioned.json and tables/T5_harm.csv')


if __name__ == '__main__':
    main()
