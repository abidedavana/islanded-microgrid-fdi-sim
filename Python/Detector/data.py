#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
data.py -- loaders for the Phase-2 detector datasets (MATLAB/Phase2/Data/<NAME>_<CH>/)
with on-disk caching of the F2 physics features (they cost ~6 ms/snapshot).

Run naming (see MATLAB/Phase2/generate_all.m):
  TRAIN, VAL, TEST201..TEST205, MAG020..MAG140, CAD025..CAD100, CADI100
"""
import os
import numpy as np
import pandas as pd

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DATA_DIR = os.path.join(ROOT, 'MATLAB', 'Phase2', 'Data')
CACHE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'results', 'cache')

TEST_RUNS = ['TEST%d' % s for s in range(201, 206)]
MAG_SCALES = [0.2, 0.4, 0.6, 0.8, 1.0, 1.2, 1.4]
MAG_RUNS = ['MAG%03d' % round(100*m) for m in MAG_SCALES]
CAD_PROBS = [0.25, 0.50, 0.75, 1.00]
CAD_RUNS = ['CAD%03d' % round(100*p) for p in CAD_PROBS] + ['CADI100']


def run_dir(name, ch):
    return os.path.join(DATA_DIR, '%s_%s' % (name, ch.upper()))


def load_run(name, ch, variants=False):
    """Load one generated run for one channel into a dict of aligned arrays."""
    d = run_dir(name, ch)
    g = lambda f: pd.read_csv(os.path.join(d, f), header=None).values
    out = dict(
        name=name, ch=ch,
        X=g('features_z.csv'),
        y=g('labels.csv').ravel().astype(int),
        J=g('J_residual.csv').ravel(),
        tau=g('bdd_tau.csv').ravel(),
        fp=g('footprint.csv').ravel(),
        des=g('design.csv').ravel(),
        rdev=g('real_deviation.csv').ravel(),
        stealthy=g('stealthy.csv').ravel().astype(bool),
        Jn=g('J_naive.csv').ravel(),
        Jlim=g('J_limited.csv').ravel(),
        ev=pd.read_csv(os.path.join(d, 'events.csv'), header=None,
                       keep_default_na=False).values.ravel().astype(str),
    )
    if variants:
        out['Zn'] = g('z_naive.csv')
        out['Zlim'] = g('z_limited.csv')
    return out


def physics_features(name, ch, Z=None, tag=''):
    """F2 features for a run (or an arbitrary matrix, cached under name+tag)."""
    from gridmodel import physics_features_batch, GridSE
    os.makedirs(CACHE_DIR, exist_ok=True)
    cache = os.path.join(CACHE_DIR, 'phys_%s_%s%s.npz' % (name, ch.upper(), tag))
    if os.path.exists(cache):
        return np.load(cache)['F']
    if Z is None:
        Z = load_run(name, ch)['X']
    print('  computing F2 physics features: %s_%s%s (%d rows)'
          % (name, ch.upper(), tag, Z.shape[0]), flush=True)
    F = physics_features_batch(Z, se=GridSE())
    np.savez_compressed(cache, F=F)
    return F


def delta_features(X):
    """Temporal deltas z_t - z_{t-1} within a run; first row backfilled with 0."""
    D = np.diff(X, axis=0)
    return np.vstack([np.zeros((1, X.shape[1])), D])
