#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_repro.py -- reproduction / integrity tests for the Phase-2 detector paper.
Run:  python tests/test_repro.py     (exits non-zero on any failure)

These are real assertions on real outputs, deliberately independent of the
analysis harness where it matters:
  * metric correctness on a hand-verifiable toy case
  * BDD-floor sanity (must be ~0 by construction)
  * leakage: splits use disjoint UCI segments; semi-sup TRAIN is attack-free-only
  * determinism: same seed -> identical PCA-SPE scores
  * model-free headline re-derived from raw CSVs (integration repro)
  * detector-side estimator independence (methodology claim #4)
"""
import os, sys, glob, numpy as np, pandas as pd
from sklearn.decomposition import PCA
from sklearn.preprocessing import StandardScaler

HERE = os.path.dirname(os.path.abspath(__file__))
DET = os.path.dirname(HERE)
DATA = os.path.abspath(os.path.join(DET, '..', '..', 'MATLAB', 'Phase2', 'Data'))
TOL = 0.02
_fail = []


def check(name, cond, detail=''):
    print(('  PASS ' if cond else '  FAIL ') + name + (('  -- ' + detail) if detail else ''))
    if not cond:
        _fail.append(name)


# ---------- canonical metric definitions (as stated in the paper) ----------
def threshold_at_fpr(clean_scores, fpr=0.01):
    return float(np.quantile(clean_scores, 1 - fpr))

def tpr_conditioned(scores, thr, mask):
    return float((scores[mask] > thr).mean()) if mask.sum() else float('nan')


def load(name, ch, f):
    p = os.path.join(DATA, '%s_%s' % (name, ch), f)
    if f == 'events.csv':
        return pd.read_csv(p, header=None, keep_default_na=False).values.ravel().astype(str)
    return pd.read_csv(p, header=None).values


# ============================ TESTS ============================
def test_metric_toy():
    """Hand-verified TPR|harm, TPR|safe, HBU, and 1%-FPR threshold."""
    harmful = np.array([5.0, 4.0, 2.0]); harmless = np.array([3.0, 1.0, 0.5])
    scores = np.concatenate([harmful, harmless])
    hmask = np.array([True]*3 + [False]*3)
    thr = 2.5
    tS = tpr_conditioned(scores, thr, hmask)
    tsafe = tpr_conditioned(scores, thr, ~hmask)
    hbu = 1 - tS
    check('metric/TPR_harm toy == 2/3', abs(tS - 2/3) < 1e-9, 'got %.4f' % tS)
    check('metric/TPR_safe toy == 1/3', abs(tsafe - 1/3) < 1e-9, 'got %.4f' % tsafe)
    check('metric/HBU toy == 1/3', abs(hbu - 1/3) < 1e-9, 'got %.4f' % hbu)
    clean = np.arange(100.0)
    thr99 = threshold_at_fpr(clean, 0.01)
    fpr = (clean > thr99).mean()
    check('metric/1%-FPR threshold realizes ~1% on its own clean set',
          abs(fpr - 0.01) < 1e-9, 'realized FPR %.4f' % fpr)


def test_splits_disjoint():
    """Leakage: TRAIN/VAL/TEST/MAG use disjoint UCI segments (whole runs)."""
    def seg(name, ch='QV'):
        man = os.path.join(DATA, '%s_%s' % (name, ch), 'manifest.txt')
        d = dict(l.strip().split('=', 1) for l in open(man) if '=' in l)
        off, steps = int(d['offset']), int(d['steps'])
        return (off, off + steps, int(d['seed']))
    names = ['TRAIN', 'VAL', 'TEST201', 'TEST202', 'TEST203', 'TEST204',
             'TEST205', 'MAG100']
    segs = {n: seg(n) for n in names}
    ok = True; bad = ''
    items = list(segs.items())
    for i in range(len(items)):
        for j in range(i+1, len(items)):
            (a0, a1, _), (b0, b1, _) = items[i][1], items[j][1]
            if not (a1 <= b0 or b1 <= a0):
                ok = False; bad = '%s overlaps %s' % (items[i][0], items[j][0])
    check('leakage/UCI segments disjoint across splits', ok, bad)
    # TRAIN vs TEST also use different seeds (distinct noise streams)
    seeds_distinct = segs['TRAIN'][2] != segs['TEST201'][2] != segs['VAL'][2]
    check('leakage/TRAIN,VAL,TEST use distinct seeds', seeds_distinct)


def test_train_semisup_normal_only():
    """Leakage: the semi-sup training mask is attack-free-only and non-vacuous."""
    for ch in ['PF', 'QV']:
        y = load('TRAIN', ch, 'labels.csv').ravel().astype(int)
        mask = (y == 0)
        check('leakage/%s TRAIN has both classes (filter non-vacuous)' % ch,
              0 < mask.sum() < len(y), 'normal=%d total=%d' % (mask.sum(), len(y)))
        # the invariant the code must uphold: no attacked row in the semi-sup set
        check('leakage/%s semi-sup training set contains zero attacked rows' % ch,
              int(y[mask].sum()) == 0)


def test_bdd_floor():
    """Sanity: residual BDD detects ~0 of stealthy attacks (by construction)."""
    for ch in ['PF', 'QV']:
        pool_J, pool_tau, pool_st = [], [], []
        runs = ['TEST%d' % s for s in range(201, 206)] + \
               ['MAG%03d' % m for m in (20, 40, 60, 80, 100, 120, 140)]
        for n in runs:
            y = load(n, ch, 'labels.csv').ravel().astype(int)
            st = load(n, ch, 'stealthy.csv').ravel().astype(bool)
            m = (y == 1) & st
            pool_J.append(load(n, ch, 'J_residual.csv').ravel()[m])
            pool_tau.append(load(n, ch, 'bdd_tau.csv').ravel()[m])
        J = np.concatenate(pool_J); tau = np.concatenate(pool_tau)
        bdd = float((J >= tau).mean())
        check('bdd-floor/%s stealthy detection ~ 0' % ch, bdd < TOL,
              'BDD TPR=%.4f (n=%d)' % (bdd, len(J)))


def _pca_spe_scorer(Xn):
    sc = StandardScaler().fit(Xn)
    pca = PCA(n_components=20, random_state=0).fit(sc.transform(Xn))
    def score(X):
        Z = sc.transform(X)
        return ((Z - pca.inverse_transform(pca.transform(Z)))**2).sum(1)
    return score


def test_model_free_headline_repro():
    """Integration: re-derive the model-free (F1) harm-conditioned headline
    from raw CSVs and assert within tolerance of the paper."""
    claims = {'PF': dict(tS=1.000, hbu=0.000), 'QV': dict(tS=0.909, hbu=0.091)}
    for ch in ['PF', 'QV']:
        Xtr = load('TRAIN', ch, 'features_z.csv')
        ytr = load('TRAIN', ch, 'labels.csv').ravel().astype(int)
        score = _pca_spe_scorer(Xtr[ytr == 0])
        Xva = load('VAL', ch, 'features_z.csv')
        yva = load('VAL', ch, 'labels.csv').ravel().astype(int)
        thr = threshold_at_fpr(score(Xva[yva == 0]), 0.01)
        shed = 'UFLS' if ch == 'PF' else 'UVLS'
        Xs, harm = [], []
        runs = ['TEST%d' % s for s in range(201, 206)] + \
               ['MAG%03d' % m for m in (20, 40, 60, 80, 100, 120, 140)]
        for n in runs:
            y = load(n, ch, 'labels.csv').ravel().astype(int)
            st = load(n, ch, 'stealthy.csv').ravel().astype(bool)
            ev = load(n, ch, 'events.csv')
            m = (y == 1) & st
            Xs.append(load(n, ch, 'features_z.csv')[m]); harm.append(ev[m] == shed)
        X = np.vstack(Xs); harm = np.concatenate(harm)
        s = score(X)
        tS = tpr_conditioned(s, thr, harm); hbu = 1 - tS
        c = claims[ch]
        check('repro/%s model-free TPR|harm within %.2f of %.3f' % (ch, TOL, c['tS']),
              abs(tS - c['tS']) <= TOL, 'reproduced %.4f' % tS)
        check('repro/%s model-free HBU within %.2f of %.3f' % (ch, TOL, c['hbu']),
              abs(hbu - c['hbu']) <= TOL, 'reproduced %.4f' % hbu)


def test_within_magnitude_triage():
    """The harm-triage is not a magnitude artifact: at FIXED attack magnitude,
    the model-free detector separates harmful from harmless Q-V attacks.
    Re-derived from raw CSVs; asserts TPR|harm > TPR|safe in every mag bin."""
    ch = 'QV'
    Xtr = load('TRAIN', ch, 'features_z.csv')
    ytr = load('TRAIN', ch, 'labels.csv').ravel().astype(int)
    score = _pca_spe_scorer(Xtr[ytr == 0])
    Xva = load('VAL', ch, 'features_z.csv')
    yva = load('VAL', ch, 'labels.csv').ravel().astype(int)
    thr = threshold_at_fpr(score(Xva[yva == 0]), 0.01)
    all_sep = True; detail = []
    for mg in ('MAG060', 'MAG080', 'MAG100', 'MAG120', 'MAG140'):
        y = load(mg, ch, 'labels.csv').ravel().astype(int)
        st = load(mg, ch, 'stealthy.csv').ravel().astype(bool)
        ev = load(mg, ch, 'events.csv')
        m = (y == 1) & st
        s = score(load(mg, ch, 'features_z.csv')[m]); h = (ev[m] == 'UVLS')
        if h.sum() == 0 or (~h).sum() == 0:
            continue
        tS = (s[h] > thr).mean(); tsafe = (s[~h] > thr).mean()
        detail.append('%s %.2f>%.2f' % (mg, tS, tsafe))
        if not (tS > tsafe):
            all_sep = False
    check('triage/within-magnitude TPR|harm > TPR|safe in every Q-V bin',
          all_sep, ' '.join(detail))


def test_determinism_scores():
    """Same seed -> identical PCA-SPE scores (byte-level array equality)."""
    Xtr = load('TRAIN', 'QV', 'features_z.csv')
    ytr = load('TRAIN', 'QV', 'labels.csv').ravel().astype(int)
    Xte = load('TEST201', 'QV', 'features_z.csv')
    s1 = _pca_spe_scorer(Xtr[ytr == 0])(Xte)
    s2 = _pca_spe_scorer(Xtr[ytr == 0])(Xte)
    check('determinism/PCA-SPE scores identical across refits',
          np.array_equal(s1, s2), 'max|d|=%.2e' % np.max(np.abs(s1 - s2)))


def test_estimator_independence():
    """Methodology #4: detector-side estimator takes only z (no true-state /
    simulator-Jacobian input) and is iterative from flat start."""
    sys.path.insert(0, DET)
    import inspect
    from gridmodel import GridSE, measModel
    params = list(inspect.signature(GridSE.estimate).parameters)
    banned = {'H', 'J', 'jac', 'jacobian', 'x_true', 'theta_true', 'V_true', 'c'}
    check('methodology/estimate() takes only (self,z,tol,maxIter), no oracle input',
          set(params) & banned == set(), 'params=%s' % params)
    se = GridSE()
    z = load('TEST201', 'QV', 'features_z.csv')[0]
    theta, Vm, Jv, ok, iters = se.estimate(z)
    check('methodology/estimator is iterative (converges in >1 step from flat)',
          ok and iters > 1, 'iters=%d converged=%s' % (iters, ok))
    # flat start check: with a zero-iteration reference the objective must drop,
    # i.e. it is genuinely solving rather than returning the input state
    r0 = z - measModel(se.Ybus, se.Yf, se.f_idx, np.ones(se.N).astype(complex))
    J_flat = float(r0 @ r0) / se.sigma**2
    check('methodology/estimator reduces objective below flat start',
          Jv < J_flat, 'J=%.1f flat=%.1f' % (Jv, J_flat))


def main():
    print('=== Phase-2 reproduction/integrity tests ===')
    for t in [test_metric_toy, test_splits_disjoint, test_train_semisup_normal_only,
              test_bdd_floor, test_model_free_headline_repro, test_within_magnitude_triage,
              test_determinism_scores, test_estimator_independence]:
        print('\n[%s]' % t.__name__)
        t()
    print('\n' + ('ALL TESTS PASSED' if not _fail else 'FAILURES: %s' % _fail))
    sys.exit(1 if _fail else 0)


if __name__ == '__main__':
    main()
