#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_figures.py  -- IEEE-style figures for the corrected microgrid FDI datasets.

Reads the CSVs produced by SimulateMicrogridFDI.m (or microgrid_fdi_sim.py) and
produces four publication figures per channel.

    python make_figures.py                       # both channels, look next to this file
    python make_figures.py pf                     # P-f only
    python make_figures.py --base "..\..\MATLAB"  # plot the MATLAB-generated datasets
    python make_figures.py pf qv --base "C:\path\to\folder_with_VectorDataset_*"

--base is the folder that CONTAINS the VectorDataset_PF_corrected / _QV_corrected
directories (e.g. the MATLAB folder, if you generated the data with MATLAB).
Defaults to the folder containing this script.
"""
import os
import sys
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

matplotlib.rcParams.update({
    'font.family': 'serif', 'font.serif': ['Times New Roman', 'DejaVu Serif'],
    'font.size': 10, 'axes.titlesize': 10, 'axes.labelsize': 10,
    'figure.dpi': 150, 'savefig.dpi': 300,
})
PAGE_W = 7.16
C_ATT, C_NOM, C_TAU, C_LIM = '#C0392B', '#27AE60', '#2980B9', '#E67E22'
HERE = os.path.dirname(os.path.abspath(__file__))


def despine(ax):
    ax.spines['top'].set_visible(False)
    ax.spines['right'].set_visible(False)


def figs_for(channel, base=HERE):
    ddir = os.path.join(base, f'VectorDataset_{channel.upper()}_corrected')
    if not os.path.isdir(ddir):
        print(f"[skip] {ddir} not found -- run the simulation first.")
        return
    load = lambda f: np.loadtxt(os.path.join(ddir, f), delimiter=',')
    labels = load('labels.csv').astype(int)
    J = load('J_residual.csv')
    Jn = load('J_naive.csv')
    Jl = load('J_limited.csv')
    tau = load('bdd_tau.csv')
    design = load('design.csv')
    real = load('real_deviation.csv')
    with open(os.path.join(ddir, 'events.csv')) as fh:
        events = np.array([ln.strip() for ln in fh if ln.strip()])

    atk = labels == 1
    nom = labels == 0
    idx = np.arange(len(labels))
    is_pf = (channel == 'pf')
    unit = 'Hz' if is_pf else 'pu'
    sym = r'\Delta f' if is_pf else r'\Delta V'
    trip = 0.20 if is_pf else 0.10
    k_under = 'UFLS' if is_pf else 'UVLS'

    Jn_over_tau = J / tau

    # --- Fig 1: BDD stealthiness ---
    fig, ax = plt.subplots(1, 2, figsize=(PAGE_W, 2.8)); fig.subplots_adjust(wspace=0.34)
    ax[0].plot(idx[nom], (J/tau)[nom], color=C_NOM, lw=0.5, alpha=0.7, label=r'Normal $J/\tau$')
    ax[0].scatter(idx[atk], (J/tau)[atk], c=C_ATT, s=5, alpha=0.7, label=r'FDI $J_{att}/\tau$')
    ax[0].axhline(1.0, color=C_TAU, ls='--', lw=1.0, label=r'Detection limit')
    ax[0].set_ylim(0, max(1.6, np.nanmax(J/tau)*1.1)); ax[0].set_xlim(0, len(labels))
    ax[0].set_xlabel('Simulation Step'); ax[0].set_ylabel(r'Normalised residual $J/\tau$')
    ax[0].set_title('(a) WLS residual: attack evades BDD'); ax[0].legend(fontsize=7); despine(ax[0])
    ax[1].boxplot([(J/tau)[nom], (J/tau)[atk]], patch_artist=True,
                  medianprops=dict(color='k'))
    ax[1].set_xticklabels(['Normal', 'FDI']); ax[1].axhline(1.0, color=C_TAU, ls='--', lw=1.0)
    ax[1].set_ylabel(r'$J/\tau$'); ax[1].set_title('(b) Residual distribution'); despine(ax[1])
    _save(fig, ddir, f'Fig1_BDD_stealth_{channel}')

    # --- Fig 2: injection vs real impact ---
    m = atk & ~np.isnan(real)
    x = design[m]; y = np.abs(real[m])
    fig, ax = plt.subplots(figsize=(PAGE_W/2, 2.8))
    ax.scatter(x, y, c=C_ATT, s=10, alpha=0.5)
    ax.axhline(trip, color=C_LIM, ls='--', lw=1.0, label=f'{k_under} limit ({trip} {unit})')
    ax.set_xlabel(rf'Designed perceived ${sym}_{{inj}}$ ({unit})')
    ax.set_ylabel(rf'Real $|{sym}_{{real}}|$ ({unit})')
    ax.set_title('Injection vs. real physical impact'); ax.legend(fontsize=8); despine(ax)
    _save(fig, ddir, f'Fig2_impact_{channel}')

    # --- Fig 3: deviation distribution + timeline ---
    fig, ax = plt.subplots(1, 2, figsize=(PAGE_W, 2.8)); fig.subplots_adjust(wspace=0.34)
    dv_a = real[atk & ~np.isnan(real)]; dv_n = real[nom & ~np.isnan(real)]
    bins = np.linspace(min(dv_a.min(), dv_n.min())-0.01, max(dv_a.max(), dv_n.max())+0.01, 40)
    ax[0].hist(dv_n, bins=bins, color=C_NOM, alpha=0.6, density=True, label='Normal')
    ax[0].hist(dv_a, bins=bins, color=C_ATT, alpha=0.6, density=True, label='Attack')
    ax[0].axvline(-trip, color=C_LIM, ls='--', lw=1.0, label=f'{k_under} ({-trip} {unit})')
    ax[0].set_xlabel(rf'${sym}_{{real}}$ ({unit})'); ax[0].set_ylabel('Density')
    ax[0].set_title('(a) Deviation distribution'); ax[0].legend(fontsize=7); despine(ax[0])
    ax[1].plot(idx[nom], real[nom], color=C_NOM, lw=0.5, alpha=0.8, label='Normal')
    ax[1].scatter(idx[atk], real[atk], c=C_ATT, s=5, alpha=0.7, label='Attack')
    ax[1].axhline(-trip, color=C_LIM, ls='--', lw=1.0)
    ax[1].set_xlim(0, len(labels)); ax[1].set_xlabel('Simulation Step')
    ax[1].set_ylabel(rf'${sym}_{{real}}$ ({unit})'); ax[1].set_title('(b) Timeline')
    ax[1].legend(fontsize=7); despine(ax[1])
    _save(fig, ddir, f'Fig3_deviation_{channel}')

    # --- Fig 4: detector comparison (FDI vs naive vs limited access) ---
    tau_a = tau[atk]
    fdi_evade = 100 * (J[atk] < tau_a).mean()
    naive_caught = 100 * (Jn[atk] >= tau_a).mean()
    lim_caught = 100 * (Jl[atk] >= tau_a).mean()
    fig, ax = plt.subplots(figsize=(PAGE_W/2, 2.9))
    cats = ['Stealthy FDI\n(full access)', 'Naive\n(same norm)', 'Limited\naccess (70%)']
    caught = [100 - fdi_evade, naive_caught, lim_caught]
    evade = [fdi_evade, 100 - naive_caught, 100 - lim_caught]
    xpos = np.arange(3)
    ax.bar(xpos, evade, 0.6, color=C_ATT, alpha=0.75, label='Evades BDD')
    ax.bar(xpos, caught, 0.6, bottom=evade, color=C_NOM, alpha=0.75, label='Detected')
    for i, e in enumerate(evade):
        ax.text(i, e/2, f'{e:.0f}%', ha='center', va='center', color='white', fontweight='bold', fontsize=8)
    ax.set_xticks(xpos); ax.set_xticklabels(cats, fontsize=8); ax.set_ylim(0, 110)
    ax.set_ylabel('% of attack steps'); ax.set_title('Detectability by attacker capability')
    ax.legend(fontsize=8, loc='center right'); despine(ax)
    _save(fig, ddir, f'Fig4_detectability_{channel}')

    print(f"[{channel}] figures written to {ddir}/")


def _save(fig, ddir, name):
    for ext in ('png', 'pdf'):
        fig.savefig(os.path.join(ddir, f'{name}.{ext}'), bbox_inches='tight')
    plt.close(fig)


if __name__ == '__main__':
    args = sys.argv[1:]
    base = HERE
    if '--base' in args:
        i = args.index('--base')
        base = os.path.abspath(args[i + 1])
        del args[i:i + 2]
    chans = args if args else ['pf', 'qv']
    for ch in chans:
        figs_for(ch, base)
