"""
Gate check for Phase-2: falsify/confirm the four hypothesis claims on the FROZEN
Phase-1 data before building anything. No new simulation; uses the committed CSVs.

Outputs a JSON summary and prints a verdict. Everything here is leakage-safe:
contiguous 60/40 time split, standardize on train, semi-sup models see normal
train steps only.
"""
import os, json, numpy as np, pandas as pd
from sklearn.linear_model import LogisticRegression
from sklearn.ensemble import RandomForestClassifier, IsolationForest
from sklearn.decomposition import PCA
from sklearn.preprocessing import StandardScaler
from sklearn.metrics import roc_auc_score, average_precision_score

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
np.random.seed(0)

def load(ch):
    d = os.path.join(ROOT, 'MATLAB', 'VectorDataset_%s_corrected' % ch)
    g = lambda f: pd.read_csv(os.path.join(d, f), header=None).values
    X = g('features_z.csv')
    y = g('labels.csv').ravel().astype(int)
    J = g('J_residual.csv').ravel()
    tau = g('bdd_tau.csv').ravel()
    fp = g('footprint.csv').ravel()
    des = g('design.csv').ravel()
    rdev = g('real_deviation.csv').ravel()
    ev = pd.read_csv(os.path.join(d, 'events.csv'), header=None, keep_default_na=False).values.ravel().astype(str)
    stealthy = (J < tau) & (fp < 0.5)
    return dict(X=X, y=y, J=J, tau=tau, fp=fp, des=des, rdev=rdev, ev=ev, stealthy=stealthy)

def tpr_at_fpr(score_norm, score_atk, fpr=0.01):
    """threshold set on NORMAL scores to give `fpr`; return TPR on attack scores."""
    thr = np.quantile(score_norm, 1 - fpr)
    return float((score_atk > thr).mean()), float(thr)

def evaluate_channel(ch):
    D = load(ch)
    X, y = D['X'], D['y']
    n = len(y); cut = int(0.6 * n)
    tr = np.arange(cut); te = np.arange(cut, n)
    sc = StandardScaler().fit(X[tr])
    Xtr, Xte = sc.transform(X[tr]), sc.transform(X[te])
    ytr, yte = y[tr], y[te]
    st_te = D['stealthy'][te]
    res = {'channel': ch, 'n_test': len(te), 'atk_test': int(yte.sum()),
           'stealthy_atk_test': int((yte & st_te).sum())}

    # ---- Negative control 1: residual BDD (SHOULD fail at ~alpha) ----
    J_te, tau_te = D['J'][te], D['tau'][te]
    atk = yte == 1
    res['BDD_TPR_all_atk'] = float((J_te[atk] >= tau_te[atk]).mean())
    res['BDD_TPR_stealthy_atk'] = float((J_te[atk & st_te] >= tau_te[atk & st_te]).mean())
    res['BDD_FPR'] = float((J_te[~atk] >= tau_te[~atk]).mean())

    # ---- Supervised snapshot classifiers on raw z (user's 2nd neg control) ----
    for name, clf in [('LogReg', LogisticRegression(max_iter=2000, C=1.0)),
                      ('RandomForest', RandomForestClassifier(n_estimators=200, random_state=0, n_jobs=-1))]:
        clf.fit(Xtr, ytr)
        s = clf.predict_proba(Xte)[:, 1]
        res[name] = {
            'auc': float(roc_auc_score(yte, s)),
            'ap': float(average_precision_score(yte, s)),
            'auc_stealthy_only': float(roc_auc_score(yte[~atk | st_te], s[~atk | st_te])
                                       ) if (yte[~atk | st_te].sum() > 0) else None,
        }
        tpr, _ = tpr_at_fpr(s[~atk], s[atk & st_te])
        res[name]['tpr1pct_stealthy'] = tpr

    # ---- Semi-supervised manifold detectors (train on NORMAL train steps only) ----
    norm_tr = Xtr[ytr == 0]
    # PCA subspace reconstruction error (SPE / Q-statistic)
    k = 20
    pca = PCA(n_components=k, random_state=0).fit(norm_tr)
    recon = lambda Z: ((Z - pca.inverse_transform(pca.transform(Z))) ** 2).sum(1)
    spe_norm = recon(Xte[~atk]); spe_atk = recon(Xte[atk & st_te])
    spe_all_atk = recon(Xte[atk])
    tpr_spe, _ = tpr_at_fpr(spe_norm, spe_atk)
    res['PCA_SPE'] = {
        'auc_stealthy': float(roc_auc_score(np.r_[np.zeros(len(spe_norm)), np.ones(len(spe_atk))],
                                            np.r_[spe_norm, spe_atk])),
        'tpr1pct_stealthy': tpr_spe}
    # Isolation Forest
    ifo = IsolationForest(n_estimators=300, random_state=0, n_jobs=-1).fit(norm_tr)
    sif = lambda Z: -ifo.score_samples(Z)
    tpr_if, _ = tpr_at_fpr(sif(Xte[~atk]), sif(Xte[atk & st_te]))
    res['IsolationForest'] = {'tpr1pct_stealthy': tpr_if}

    # ---- Frontier: bin STEALTHY attacks by design magnitude ----
    des_te, fp_te, rdev_te, ev_te = D['des'][te], D['fp'][te], D['rdev'][te], D['ev'][te]
    m = atk & st_te
    dvals = des_te[m]
    edges = np.quantile(dvals, np.linspace(0, 1, 6))
    edges = np.unique(edges)
    shed_key = 'UFLS' if ch == 'PF' else 'UVLS'
    spe_m = recon(Xte)  # scores for all test rows
    thr_spe = np.quantile(spe_norm, 0.99)
    frontier = []
    for i in range(len(edges) - 1):
        lo, hi = edges[i], edges[i + 1]
        sel = m & (des_te >= lo) & (des_te <= hi if i == len(edges) - 2 else des_te < hi)
        if sel.sum() == 0:
            continue
        frontier.append({
            'design_lo': float(lo), 'design_hi': float(hi), 'n': int(sel.sum()),
            'mean_footprint': float(fp_te[sel].mean()),
            'mean_abs_dev': float(np.nanmean(np.abs(rdev_te[sel]))),
            'p_loadshed': float(np.mean(ev_te[sel] == shed_key)),
            'manifold_TPR1pct': float((spe_m[sel] > thr_spe).mean()),
        })
    res['frontier'] = frontier
    return res

def main():
    out = {}
    for ch in ['PF', 'QV']:
        out[ch] = evaluate_channel(ch)
    os.makedirs(os.path.join(ROOT, 'Python', 'Detector', 'results'), exist_ok=True)
    p = os.path.join(ROOT, 'Python', 'Detector', 'results', 'claim_checks.json')
    with open(p, 'w') as f:
        json.dump(out, f, indent=2)

    for ch in ['PF', 'QV']:
        r = out[ch]
        print('\n===== %s  (test n=%d, stealthy attacks=%d) =====' % (ch, r['n_test'], r['stealthy_atk_test']))
        print(' NEG-CTRL residual BDD : TPR(stealthy)=%.3f  FPR=%.3f   <- should be ~0.01' % (
            r['BDD_TPR_stealthy_atk'], r['BDD_FPR']))
        print(' snapshot LogReg       : AUC=%.3f  TPR@1%%FPR(stealthy)=%.3f' % (
            r['LogReg']['auc'], r['LogReg']['tpr1pct_stealthy']))
        print(' snapshot RandForest   : AUC=%.3f  TPR@1%%FPR(stealthy)=%.3f' % (
            r['RandomForest']['auc'], r['RandomForest']['tpr1pct_stealthy']))
        print(' semisup PCA-SPE       : AUC(stealthy)=%.3f  TPR@1%%FPR(stealthy)=%.3f' % (
            r['PCA_SPE']['auc_stealthy'], r['PCA_SPE']['tpr1pct_stealthy']))
        print(' semisup IsolationForest: TPR@1%%FPR(stealthy)=%.3f' % r['IsolationForest']['tpr1pct_stealthy'])
        print(' FRONTIER (stealthy attacks binned by design magnitude):')
        print('   design-range     n   footprint  |dev|   P(shed)  manifoldTPR')
        for b in r['frontier']:
            print('   [%.3f,%.3f] %4d   %.4f   %.4f   %.3f    %.3f' % (
                b['design_lo'], b['design_hi'], b['n'], b['mean_footprint'],
                b['mean_abs_dev'], b['p_loadshed'], b['manifold_TPR1pct']))
    print('\nwrote', p)

if __name__ == '__main__':
    main()
