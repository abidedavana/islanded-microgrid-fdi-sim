#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
contam_trim.py -- contamination mitigation check: PCA-SPE with a one-pass
10% trim (fit, drop the top-scored 10% of training rows, refit). Standard
robust-refit; tests whether the contamination collapse seen in the main study
is repairable without labels. Appends results/contam_trim.json.
"""
import json
import os
import numpy as np

import data as D
from models import PCASPE, threshold_at_fpr, tci, SEED
from sklearn.preprocessing import StandardScaler

RES = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'results')
RATES = [0.005, 0.01, 0.02, 0.05]
TRIM = 0.10


def run(ch):
    train = D.load_run('TRAIN', ch)
    val = D.load_run('VAL', ch)
    tests = [D.load_run(r, ch) for r in D.TEST_RUNS]
    rng = np.random.default_rng(SEED)
    norm_idx = np.where(train['y'] == 0)[0]
    atk_idx = np.where(train['y'] == 1)[0]
    va_norm = val['X'][val['y'] == 0]
    out = []
    for rate in RATES:
        n_add = int(round(rate*len(norm_idx)/(1 - rate)))
        add = rng.choice(atk_idx, size=min(n_add, len(atk_idx)), replace=False)
        sel = np.concatenate([norm_idx, add])
        Xc = train['X'][sel]
        entry = {'rate': rate, 'channel': ch}
        for tag, trim in [('plain', False), ('trim', True)]:
            sc = StandardScaler().fit(Xc)
            m = PCASPE().fit(sc.transform(Xc))
            if trim:
                s = m.score(sc.transform(Xc))
                keep = s < np.quantile(s, 1 - TRIM)
                sc = StandardScaler().fit(Xc[keep])
                m = PCASPE().fit(sc.transform(Xc[keep]))
            thr = threshold_at_fpr(m.score(sc.transform(va_norm)), 0.01)
            tprs, fprs = [], []
            for t in tests:
                s = m.score(sc.transform(t['X']))
                st = (t['y'] == 1) & t['stealthy']
                tprs.append(float((s[st] > thr).mean()))
                fprs.append(float((s[t['y'] == 0] > thr).mean()))
            mt, ht = tci(tprs); mf, hf = tci(fprs)
            entry[tag] = {'tpr': mt, 'tpr_ci': ht, 'fpr': mf, 'fpr_ci': hf}
            print('%s rate=%.1f%% %-5s TPR=%.3f+-%.3f FPR=%.4f' % (
                ch, 100*rate, tag, mt, ht, mf), flush=True)
        out.append(entry)
    return out


if __name__ == '__main__':
    res = []
    for ch in ['PF', 'QV']:
        res += run(ch)
    with open(os.path.join(RES, 'contam_trim.json'), 'w') as f:
        json.dump(res, f, indent=2)
    print('wrote results/contam_trim.json')
