"""
FULLY INDEPENDENT re-derivation of every Phase-2 result table.
Does NOT import run_eval.py / models.py / data.py. Reimplements the minimal
pipeline from raw CSVs and compares to the reported JSONs. Any |delta|>0.02 on a
rate is flagged. Purpose: catch pipeline artifacts / bugs in the reported numbers.
"""
import os, json, numpy as np, pandas as pd
from sklearn.decomposition import PCA
from sklearn.preprocessing import StandardScaler
from sklearn.linear_model import LogisticRegression
from sklearn.ensemble import RandomForestClassifier, IsolationForest
from sklearn.svm import OneClassSVM
from sklearn.neural_network import MLPRegressor
from sklearn.metrics import roc_auc_score

BASE = r"C:\Users\abide\Downloads\FDI_Microgrid_Project (3)\FDI_Microgrid_Project (2)\FDI_Microgrid_Project\FDI_Microgrid_Project"
DATA = os.path.join(BASE, "MATLAB", "Phase2", "Data")
RES = os.path.join(BASE, "Python", "Detector", "results")
SEED = 0
flags = []

def load(name, ch):
    d = os.path.join(DATA, f"{name}_{ch}")
    g = lambda f: pd.read_csv(os.path.join(d, f), header=None).values
    return dict(
        X=g("features_z.csv"), y=g("labels.csv").ravel().astype(int),
        J=g("J_residual.csv").ravel(), tau=g("bdd_tau.csv").ravel(),
        Jn=g("J_naive.csv").ravel(), Jl=g("J_limited.csv").ravel(),
        st=pd.read_csv(os.path.join(d,"stealthy.csv"),header=None).values.ravel().astype(bool),
        ev=pd.read_csv(os.path.join(d,"events.csv"),header=None,keep_default_na=False).values.ravel().astype(str),
        des=g("design.csv").ravel(), rdev=g("real_deviation.csv").ravel(),
        fp=g("footprint.csv").ravel())

def zvariant(name, ch, which):
    return pd.read_csv(os.path.join(DATA,f"{name}_{ch}",f"z_{which}.csv"),header=None).values

def spe_model(Xn):
    sc = StandardScaler().fit(Xn)
    pca = PCA(n_components=20, random_state=SEED).fit(sc.transform(Xn))
    def score(X):
        Z = sc.transform(X); R = Z - pca.inverse_transform(pca.transform(Z))
        return (R**2).sum(1)
    return score

def ae_model(Xn):
    sc = StandardScaler().fit(Xn)
    net = MLPRegressor(hidden_layer_sizes=(64,16,64), activation='relu', solver='adam',
                       early_stopping=True, max_iter=400, random_state=SEED).fit(sc.transform(Xn), sc.transform(Xn))
    def score(X):
        Z = sc.transform(X); R = Z - net.predict(Z); return (R**2).sum(1)
    return score

def thr_at(scores, fpr=0.01):
    return np.quantile(scores, 1-fpr)

def chk(label, got, rep, tol=0.02):
    ok = abs(got-rep) <= tol
    if not ok: flags.append((label, got, rep))
    print(f"  {'OK ' if ok else '!! '}{label:42s} indep={got:.3f}  reported={rep:.3f}")

TESTS = [f"TEST{s}" for s in range(201,206)]
evJ = {ch: json.load(open(os.path.join(RES,f"eval_{ch}.json"))) for ch in ["PF","QV"]}

for ch in ["PF","QV"]:
    print(f"\n===================== {ch} =====================")
    tr = load("TRAIN",ch); va = load("VAL",ch)
    Xn = tr["X"][tr["y"]==0]; vaN = va["X"][va["y"]==0]
    spe = spe_model(Xn); ae = ae_model(Xn)
    thr_spe = thr_at(spe(vaN)); thr_ae = thr_at(ae(vaN))
    # supervised
    scS = StandardScaler().fit(tr["X"])
    lr = LogisticRegression(max_iter=2000).fit(scS.transform(tr["X"]), tr["y"])
    rf = RandomForestClassifier(n_estimators=300,random_state=SEED,n_jobs=-1).fit(scS.transform(tr["X"]), tr["y"])
    thr_lr = thr_at(lr.predict_proba(scS.transform(vaN))[:,1])
    thr_rf = thr_at(rf.predict_proba(scS.transform(vaN))[:,1])
    # iforest (expected failure)
    scI = StandardScaler().fit(Xn)
    ifo = IsolationForest(n_estimators=300,random_state=SEED,n_jobs=-1).fit(scI.transform(Xn))
    thr_if = thr_at(-ifo.score_samples(scI.transform(vaN)))

    spe_tpr, ae_tpr, bdd_tpr, lr_tpr, rf_tpr, if_tpr, spe_fpr = ([] for _ in range(7))
    for t in [load(n,ch) for n in TESTS]:
        m = (t["y"]==1)&t["st"]; norm = t["y"]==0
        spe_tpr.append((spe(t["X"])[m]>thr_spe).mean()); spe_fpr.append((spe(t["X"])[norm]>thr_spe).mean())
        ae_tpr.append((ae(t["X"])[m]>thr_ae).mean())
        bdd_tpr.append((t["J"][m]>=t["tau"][m]).mean())
        lr_tpr.append((lr.predict_proba(scS.transform(t["X"]))[m,1]>thr_lr).mean())
        rf_tpr.append((rf.predict_proba(scS.transform(t["X"]))[m,1]>thr_rf).mean())
        if_tpr.append((-ifo.score_samples(scI.transform(t["X"]))[m]>thr_if).mean())
    T = evJ[ch]["test"]
    chk("BDD TPR", np.mean(bdd_tpr), T["bdd|BDD|-"]["tpr_stealthy"])
    chk("PCA-SPE F1 TPR", np.mean(spe_tpr), T["semi|PCA-SPE|F1"]["tpr_stealthy"])
    chk("PCA-SPE F1 FPR", np.mean(spe_fpr), T["semi|PCA-SPE|F1"]["fpr"])
    chk("AE-MLP F1 TPR", np.mean(ae_tpr), T["semi|AE-MLP|F1"]["tpr_stealthy"])
    chk("LogReg F1 TPR", np.mean(lr_tpr), T["sup|LogReg|F1"]["tpr_stealthy"])
    chk("RF F1 TPR", np.mean(rf_tpr), T["sup|RF|F1"]["tpr_stealthy"])
    chk("IForest F1 TPR", np.mean(if_tpr), T["semi|IForest|F1"]["tpr_stealthy"])

    # ---- magnitude sweep (SPE F1 + BDD) ----
    print("  -- magnitude sweep --")
    for row in evJ[ch]["magnitude_sweep"]:
        mg = row["magScale"]; nm = f"MAG{round(100*mg):03d}"
        r = load(nm,ch); m = (r["y"]==1)&r["st"]
        got_spe = (spe(r["X"])[m]>thr_spe).mean()
        got_shed = (r["ev"][m]==("UFLS" if ch=="PF" else "UVLS")).mean()
        chk(f"mag{mg} SPE-F1 TPR", got_spe, row["tpr_PCA-SPE_F1"])
        chk(f"mag{mg} P(shed)", got_shed, row["p_shed"])

    # ---- variants: naive + limited (SPE + BDD-union) ----
    print("  -- variants --")
    for which, jkey in [("naive","Jn"),("limited","Jl")]:
        got_bdd, got_spe, got_union = [], [], []
        for n in TESTS:
            t = load(n,ch); atk = t["y"]==1
            Zv = zvariant(n,ch,which)[atk]; ok = ~np.isnan(Zv).any(1); Zv=Zv[ok]
            bdd = t[jkey][atk][ok] >= t["tau"][atk][ok]
            ml = spe(Zv) > thr_spe
            got_bdd.append(bdd.mean()); got_spe.append(ml.mean()); got_union.append((ml|bdd).mean())
        vrep = evJ[ch]["variants"][which]
        chk(f"{which} BDD TPR", np.mean(got_bdd), np.mean([x["bdd_tpr"] for x in vrep]))
        chk(f"{which} SPE TPR", np.mean(got_spe), np.mean([x["ml_tpr_PCA-SPE_F1"] for x in vrep]))
        chk(f"{which} union TPR", np.mean(got_union), np.mean([x["union_tpr_PCA-SPE_F1"] for x in vrep]))

print("\n=================== SUMMARY ===================")
if flags:
    print(f"{len(flags)} MISMATCH(es) > 0.02:")
    for lab,g,r in flags: print(f"  {lab}: indep={g:.3f} reported={r:.3f}")
else:
    print("ALL CHECKS PASS (every independently re-derived rate within 0.02 of reported).")
