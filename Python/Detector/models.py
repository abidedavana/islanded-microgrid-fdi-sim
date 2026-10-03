#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
models.py -- detector zoo (DETECTOR_DESIGN.md par.2) behind one interface:
  semi-supervised: fit(X_normal);        score(X) -> higher = more anomalous
  supervised:      fit(X, y);            score(X) -> P(attack)
Deterministic: every stochastic model takes random_state=SEED.
"""
import numpy as np
from sklearn.decomposition import PCA
from sklearn.linear_model import LogisticRegression
from sklearn.ensemble import RandomForestClassifier, IsolationForest, \
    HistGradientBoostingClassifier
from sklearn.neural_network import MLPRegressor, MLPClassifier
from sklearn.svm import OneClassSVM

SEED = 0
PCA_K = 20          # claim-check precedent; sensitivity to k reported separately
OCSVM_CAP = 8000    # subsample cap (O(n^2) kernel)


# ---------------- semi-supervised ----------------
class PCASPE:
    """PCA subspace reconstruction error (SPE / Q-statistic)."""
    def __init__(self, k=PCA_K):
        self.k = k
    def fit(self, X):
        self.pca = PCA(n_components=self.k, random_state=SEED).fit(X)
        return self
    def score(self, X):
        R = X - self.pca.inverse_transform(self.pca.transform(X))
        return (R**2).sum(axis=1)


class PCAT2:
    """Hotelling T^2 in the retained PCA subspace."""
    def __init__(self, k=PCA_K):
        self.k = k
    def fit(self, X):
        self.pca = PCA(n_components=self.k, random_state=SEED).fit(X)
        T = self.pca.transform(X)
        self.var = T.var(axis=0) + 1e-12
        return self
    def score(self, X):
        T = self.pca.transform(X)
        return ((T**2)/self.var).sum(axis=1)


class AEMLP:
    """Autoencoder via MLPRegressor 64-16-64 (design par.6); score = recon MSE."""
    def fit(self, X):
        self.net = MLPRegressor(hidden_layer_sizes=(64, 16, 64), activation='relu',
                                solver='adam', early_stopping=True, max_iter=400,
                                random_state=SEED)
        self.net.fit(X, X)
        return self
    def score(self, X):
        R = X - self.net.predict(X)
        return (R**2).sum(axis=1)


class OCSVM:
    def fit(self, X):
        if X.shape[0] > OCSVM_CAP:
            rng = np.random.default_rng(SEED)
            X = X[rng.choice(X.shape[0], OCSVM_CAP, replace=False)]
        self.m = OneClassSVM(kernel='rbf', nu=0.05, gamma='scale').fit(X)
        return self
    def score(self, X):
        return -self.m.decision_function(X)


class IFOREST:
    def fit(self, X):
        self.m = IsolationForest(n_estimators=300, random_state=SEED,
                                 n_jobs=-1).fit(X)
        return self
    def score(self, X):
        return -self.m.score_samples(X)


# ---------------- supervised ----------------
class SupWrap:
    def __init__(self, clf):
        self.clf = clf
    def fit(self, X, y):
        self.clf.fit(X, y)
        return self
    def score(self, X):
        return self.clf.predict_proba(X)[:, 1]


def semisup_zoo():
    return {
        'PCA-SPE': PCASPE(),
        'PCA-T2': PCAT2(),
        'AE-MLP': AEMLP(),
        'OC-SVM': OCSVM(),
        'IForest': IFOREST(),
    }


def supervised_zoo():
    return {
        'LogReg': SupWrap(LogisticRegression(max_iter=2000, C=1.0)),
        'RF': SupWrap(RandomForestClassifier(n_estimators=300, random_state=SEED,
                                             n_jobs=-1)),
        'HistGB': SupWrap(HistGradientBoostingClassifier(random_state=SEED)),
        'MLP': SupWrap(MLPClassifier(hidden_layer_sizes=(64, 32), max_iter=400,
                                     early_stopping=True, random_state=SEED)),
    }


# ---------------- metrics ----------------
def threshold_at_fpr(clean_scores, fpr=0.01):
    return float(np.quantile(clean_scores, 1 - fpr))


def tci(x):
    """mean +/- 95% t-CI half-width (the Phase-1 audit M-1 lesson: t, not z)."""
    from scipy.stats import t as tdist
    x = np.asarray(x, float)
    n = len(x)
    if n < 2:
        return float(x.mean()), float('nan')
    hw = tdist.ppf(0.975, n-1)*x.std(ddof=1)/np.sqrt(n)
    return float(x.mean()), float(hw)
