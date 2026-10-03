#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
loadx_eval.py -- E9 heterogeneous-load robustness (user-approved).

Two questions on the LOADX cells (per-bus multiplicative load jitter):
  SHIFT:   detectors trained on the RANK-1 TRAIN/VAL (main campaign), evaluated
           on jittered LXT5 -- does distribution shift blow up the FPR / drop TPR?
  RETRAIN: detectors trained on jittered LXTRAIN, thresholds on jittered LXVAL,
           evaluated on jittered LXT5 -- does the detector still work when the
           manifold is legitimately thicker?
Also reports the 2% jitter cells (LXT2) under RETRAIN as a milder-heterogeneity
point. Headline detector = PCA-SPE F1 (pre-registered); AE-MLP F1 alongside.

Writes results/loadx_eval.json and prints a summary.
"""
import json
import os
import numpy as np

import data as D
from models import PCASPE, AEMLP, threshold_at_fpr, tci
from sklearn.preprocessing import StandardScaler

RES = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'results')
LXT5 = ['LXT5%d' % s for s in range(511, 516)]
LXT2 = ['LXT2%d' % s for s in (521, 522)]


def fit_detectors(Xtr_norm):
    sc = StandardScaler().fit(Xtr_norm)
    dets = {'PCA-SPE': PCASPE().fit(sc.transform(Xtr_norm)),
            'AE-MLP': AEMLP().fit(sc.transform(Xtr_norm))}
    return sc, dets


def eval_on(sc, dets, thr, runs, ch):
    res = {}
    for name, m in dets.items():
        tprs, fprs = [], []
        for r in runs:
            d = D.load_run(r, ch)
            s = m.score(sc.transform(d['X']))
            st = (d['y'] == 1) & d['stealthy']
            tprs.append(float((s[st] > thr[name]).mean()))
            fprs.append(float((s[d['y'] == 0] > thr[name]).mean()))
        mt, ht = tci(tprs); mf, hf = tci(fprs)
        res[name] = {'tpr': mt, 'tpr_ci': ht, 'fpr': mf, 'fpr_ci': hf}
    return res


def run(ch):
    out = {'channel': ch}

    # --- SHIFT: rank-1-trained detectors, deployed threshold from clean VAL ---
    train = D.load_run('TRAIN', ch); val = D.load_run('VAL', ch)
    sc, dets = fit_detectors(train['X'][train['y'] == 0])
    thr = {n: threshold_at_fpr(m.score(sc.transform(val['X'][val['y'] == 0])), 0.01)
           for n, m in dets.items()}
    out['shift_on_5pct'] = eval_on(sc, dets, thr, LXT5, ch)

    # --- RETRAIN: jitter-trained detectors, threshold from jittered LXVAL ---
    lxtr = D.load_run('LXTRAIN', ch); lxval = D.load_run('LXVAL', ch)
    scr, detsr = fit_detectors(lxtr['X'][lxtr['y'] == 0])
    thrr = {n: threshold_at_fpr(m.score(scr.transform(lxval['X'][lxval['y'] == 0])), 0.01)
            for n, m in detsr.items()}
    out['retrain_on_5pct'] = eval_on(scr, detsr, thrr, LXT5, ch)
    out['retrain_on_2pct'] = eval_on(scr, detsr, thrr, LXT2, ch)

    # --- reference: rank-1 detector on rank-1 TEST (from the main eval) ---
    tst = [D.load_run(r, ch) for r in D.TEST_RUNS]
    ref = {}
    for name, m in dets.items():
        tprs, fprs = [], []
        for d in tst:
            s = m.score(sc.transform(d['X']))
            st = (d['y'] == 1) & d['stealthy']
            tprs.append(float((s[st] > thr[name]).mean()))
            fprs.append(float((s[d['y'] == 0] > thr[name]).mean()))
        mt, ht = tci(tprs); mf, hf = tci(fprs)
        ref[name] = {'tpr': mt, 'tpr_ci': ht, 'fpr': mf, 'fpr_ci': hf}
    out['reference_rank1'] = ref
    return out


def main():
    res = {}
    for ch in ['PF', 'QV']:
        res[ch] = run(ch)
        r = res[ch]
        print('\n===== %s =====' % ch)
        for blk in ['reference_rank1', 'shift_on_5pct', 'retrain_on_5pct', 'retrain_on_2pct']:
            for name in ['PCA-SPE', 'AE-MLP']:
                e = r[blk][name]
                print('  %-16s %-8s TPR=%.3f+-%.3f  FPR=%.4f+-%.4f' % (
                    blk, name, e['tpr'], e['tpr_ci'], e['fpr'], e['fpr_ci']))
    with open(os.path.join(RES, 'loadx_eval.json'), 'w') as f:
        json.dump(res, f, indent=2)
    print('\nwrote results/loadx_eval.json')


if __name__ == '__main__':
    main()
