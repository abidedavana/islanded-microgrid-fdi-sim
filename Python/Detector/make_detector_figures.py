#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_detector_figures.py -- IEEE figures + tables from run_eval.py outputs.
Style matches Python/Simulation/make_figures.py (Phase-1 figures).

    python make_detector_figures.py
"""
import json
import os
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
C_ML = '#8E44AD'

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(HERE, 'results')
FIG = os.path.join(RES, 'figures')
TAB = os.path.join(RES, 'tables')


def despine(ax):
    ax.spines['top'].set_visible(False)
    ax.spines['right'].set_visible(False)


def load_eval(ch):
    with open(os.path.join(RES, 'eval_%s.json' % ch)) as f:
        return json.load(f)


def savefig(fig, name):
    for ext in ('png', 'pdf'):
        fig.savefig(os.path.join(FIG, '%s.%s' % (name, ext)), bbox_inches='tight')
    plt.close(fig)
    print('  fig:', name)


# ---------------------------------------------------------------- figures
def fig_frontier():
    """Detection-vs-impact frontier: TPR and P(load shed) vs attack magnitude."""
    fig, axes = plt.subplots(1, 2, figsize=(PAGE_W, 2.7))
    for ax, ch, unit in zip(axes, ['PF', 'QV'], ['Hz', 'pu']):
        rows = load_eval(ch)['magnitude_sweep']
        m = [r['magScale'] for r in rows]
        ax.plot(m, [r['tpr_PCA-SPE_F1'] for r in rows], 'o-', color=C_ML,
                label='PCA-SPE (semi-sup)')
        ax.plot(m, [r['tpr_Oracle'] for r in rows], 's--', color=C_TAU,
                label='Physics oracle')
        ax.plot(m, [r['tpr_BDD'] for r in rows], 'x-', color='0.45',
                label='Residual BDD')
        ax.plot(m, [r['p_shed'] for r in rows], 'd:', color=C_ATT,
                label='P(load shed)')
        ax.axvspan(min(m), 0.99, color='0.92', zorder=0)
        ax.text(0.02, 0.98, 'below training\nmagnitudes', transform=ax.transAxes,
                fontsize=8, va='top', color='0.4')
        ax.set_xlabel('attack magnitude scale')
        ax.set_ylabel('rate')
        ax.set_ylim(-0.03, 1.05)
        ax.set_title('%s channel' % ch)
        despine(ax)
    axes[0].legend(fontsize=8, loc='center right', frameon=False)
    fig.tight_layout()
    savefig(fig, 'FigD1_frontier')


def fig_scores():
    """Headline score distributions on TEST: normals vs stealthy attacks."""
    fig, axes = plt.subplots(1, 2, figsize=(PAGE_W, 2.6))
    for ax, ch in zip(axes, ['PF', 'QV']):
        z = np.load(os.path.join(RES, 'scores_%s.npz' % ch))
        s = np.log10(z['spe_f1'] + 1e-12)
        nrm = z['y'] == 0
        st = (z['y'] == 1) & z['stealthy']
        bins = np.linspace(min(s.min(), np.log10(z['thr_spe'])) - 0.2,
                           s.max() + 0.2, 60)
        ax.hist(s[nrm], bins=bins, density=True, alpha=0.65, color=C_NOM,
                label='normal (n=%d)' % nrm.sum())
        ax.hist(s[st], bins=bins, density=True, alpha=0.65, color=C_ATT,
                label='stealthy FDI (n=%d)' % st.sum())
        ax.axvline(np.log10(z['thr_spe']), color='k', lw=1, ls='--',
                   label='threshold (1% FPR)')
        ax.set_xlabel(r'log$_{10}$ PCA-SPE score')
        ax.set_ylabel('density')
        ax.set_title('%s channel' % ch)
        ax.legend(fontsize=8, frameon=False)
        despine(ax)
    fig.tight_layout()
    savefig(fig, 'FigD2_scores')


def fig_cadence():
    """Temporal-feature honesty guard: F1 vs F1+delta TPR across attack cadence."""
    fig, axes = plt.subplots(1, 2, figsize=(PAGE_W, 2.7))
    for ax, ch in zip(axes, ['PF', 'QV']):
        rows = load_eval(ch).get('cadence', [])
        if not rows:
            continue
        pers = [r for r in rows if r['run'].startswith('CAD0') or r['run'] == 'CAD100']
        x = [r['attack_frac'] for r in pers]
        for key, colr, mk, lb in [
                ('tpr_PCA-SPE_F1', C_ML, 'o', 'PCA-SPE (z only)'),
                ('tpr_PCA-SPE_F1d', C_ML, 'o', 'PCA-SPE (z, $\\Delta$z)'),
                ('tpr_RF_F1', C_LIM, 's', 'RF (z only)'),
                ('tpr_RF_F1d', C_LIM, 's', 'RF (z, $\\Delta$z)')]:
            ls = ':' if key.endswith('F1d') else '-'
            ax.plot(x, [r[key] for r in pers], marker=mk, ls=ls, color=colr,
                    label=lb, ms=4)
        ctrl = [r for r in rows if r['run'] == 'CADI100']
        if ctrl:
            ax.plot([ctrl[0]['attack_frac']], [ctrl[0]['tpr_PCA-SPE_F1d']],
                    marker='*', ms=10, color='k', ls='none',
                    label='$\\Delta$z, i.i.d. redraw')
        ax.set_xlabel('attacked fraction of steps (persistent attacker)')
        ax.set_ylabel('TPR on stealthy FDI')
        ax.set_ylim(-0.03, 1.05)
        ax.set_title('%s channel' % ch)
        despine(ax)
    axes[0].legend(fontsize=7.5, frameon=False, loc='lower left')
    fig.tight_layout()
    savefig(fig, 'FigD3_cadence')


def fig_coverage():
    """BDD vs ML vs union coverage across attack variants."""
    fig, axes = plt.subplots(1, 2, figsize=(PAGE_W, 2.6))
    for ax, ch in zip(axes, ['PF', 'QV']):
        ev = load_eval(ch)
        test = ev['test']
        v = ev['variants']
        bdd = [test['bdd|BDD|-']['tpr_stealthy'],
               float(np.mean([r['bdd_tpr'] for r in v['naive']])),
               float(np.mean([r['bdd_tpr'] for r in v['limited']]))]
        ml = [test['semi|PCA-SPE|F1']['tpr_stealthy'],
              float(np.mean([r['ml_tpr_PCA-SPE_F1'] for r in v['naive']])),
              float(np.mean([r['ml_tpr_PCA-SPE_F1'] for r in v['limited']]))]
        un = [max(bdd[0], ml[0]),
              float(np.mean([r['union_tpr_PCA-SPE_F1'] for r in v['naive']])),
              float(np.mean([r['union_tpr_PCA-SPE_F1'] for r in v['limited']]))]
        xx = np.arange(3); w = 0.26
        ax.bar(xx - w, bdd, w, color='0.55', label='Residual BDD')
        ax.bar(xx, ml, w, color=C_ML, label='PCA-SPE')
        ax.bar(xx + w, un, w, color=C_NOM, label='BDD $\\cup$ ML')
        ax.set_xticks(xx)
        ax.set_xticklabels(['stealthy\n(full access)', 'naive\nsame-norm',
                            'limited\naccess (70%)'], fontsize=8)
        ax.set_ylabel('detection rate')
        ax.set_ylim(0, 1.09)
        ax.set_title('%s channel' % ch)
        despine(ax)
    axes[1].legend(fontsize=8, frameon=False, loc='lower right')
    fig.tight_layout()
    savefig(fig, 'FigD4_coverage')


# ---------------------------------------------------------------- tables
def fmt(m, ci=None):
    if m is None or (isinstance(m, float) and np.isnan(m)):
        return '--'
    if ci is None or (isinstance(ci, float) and np.isnan(ci)):
        return '%.3f' % m
    return '%.3f$\\pm$%.3f' % (m, ci)


def table_main():
    """Main results: per channel, model x (TPR stealthy, FPR, AUC)."""
    lines_csv = ['channel,family,model,features,tpr_stealthy,tpr_ci,fpr,fpr_ci,auc']
    order = [('bdd', 'BDD', '-'), ('oracle', 'Oracle', 'F2')] + \
        [('semi', m, fs) for m in ['PCA-SPE', 'PCA-T2', 'AE-MLP', 'OC-SVM', 'IForest']
         for fs in ['F1', 'F2', 'F3']] + \
        [('sup', m, fs) for m in ['LogReg', 'RF', 'HistGB', 'MLP']
         for fs in ['F1', 'F2', 'F3']]
    for ch in ['PF', 'QV']:
        t = load_eval(ch)['test']
        for kind, name, fs in order:
            k = '%s|%s|%s' % (kind, name, fs)
            if k not in t:
                continue
            e = t[k]
            lines_csv.append('%s,%s,%s,%s,%.4f,%.4f,%.4f,%.4f,%.4f' % (
                ch, kind, name, fs,
                e.get('tpr_stealthy', float('nan')), e.get('tpr_stealthy_ci', float('nan')),
                e.get('fpr', float('nan')), e.get('fpr_ci', float('nan')),
                e.get('auc_stealthy', float('nan'))))
    with open(os.path.join(TAB, 'T1_main.csv'), 'w') as f:
        f.write('\n'.join(lines_csv))
    print('  table: T1_main.csv')


def table_crosschannel():
    p = os.path.join(RES, 'eval_crosschannel.json')
    if not os.path.exists(p):
        return
    with open(p) as f:
        xc = json.load(f)
    lines = ['train_ch,test_ch,model,fs,tpr_stealthy,tpr_ci,fpr,fpr_ci']
    for r in xc:
        lines.append('%s,%s,%s,%s,%.4f,%.4f,%.4f,%.4f' % (
            r['train_ch'], r['test_ch'], r['model'], r['fs'],
            r['tpr_stealthy'], r['tpr_ci'], r['fpr'], r['fpr_ci']))
    with open(os.path.join(TAB, 'T2_crosschannel.csv'), 'w') as f:
        f.write('\n'.join(lines))
    print('  table: T2_crosschannel.csv')


def table_contamination():
    lines = ['channel,rate,model,tpr_stealthy,tpr_ci,fpr,fpr_ci']
    for ch in ['PF', 'QV']:
        ev = load_eval(ch)
        for e in ev.get('contamination', []):
            for m in ['PCA-SPE', 'PCA-T2', 'AE-MLP', 'OC-SVM', 'IForest']:
                if m in e:
                    lines.append('%s,%.3f,%s,%.4f,%.4f,%.4f,%.4f' % (
                        ch, e['rate'], m, e[m]['tpr_stealthy'], e[m]['tpr_ci'],
                        e[m]['fpr'], e[m]['fpr_ci']))
    with open(os.path.join(TAB, 'T3_contamination.csv'), 'w') as f:
        f.write('\n'.join(lines))
    print('  table: T3_contamination.csv')


def table_magnitude():
    lines = None
    rows_all = []
    for ch in ['PF', 'QV']:
        for r in load_eval(ch)['magnitude_sweep']:
            r2 = {'channel': ch}
            r2.update(r)
            rows_all.append(r2)
            if lines is None:
                lines = [','.join(r2.keys())]
            lines.append(','.join(str(v) for v in r2.values()))
    with open(os.path.join(TAB, 'T4_magnitude.csv'), 'w') as f:
        f.write('\n'.join(lines))
    print('  table: T4_magnitude.csv')


def main():
    os.makedirs(FIG, exist_ok=True)
    os.makedirs(TAB, exist_ok=True)
    fig_frontier()
    fig_scores()
    fig_cadence()
    fig_coverage()
    table_main()
    table_crosschannel()
    table_contamination()
    table_magnitude()
    print('done.')


if __name__ == '__main__':
    main()
