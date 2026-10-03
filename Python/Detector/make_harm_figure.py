#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""FigD5: the harm-conditioned story. Left: TPR|harm vs TPR|safe per detector
(QV), showing self-triage and the gap closing F1->F3->oracle. Right: per-
magnitude harm-conditioned TPR (QV), the model-free gap and its closure."""
import json, os
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

matplotlib.rcParams.update({'font.family': 'serif',
    'font.serif': ['Times New Roman', 'DejaVu Serif'], 'font.size': 10,
    'axes.titlesize': 10, 'axes.labelsize': 10, 'figure.dpi': 150, 'savefig.dpi': 300})
PAGE_W = 7.16
C_F1, C_F3, C_OR, C_BDD = '#8E44AD', '#2980B9', '#27AE60', '#7F8C8D'
HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(HERE, 'results'); FIG = os.path.join(RES, 'figures')


def despine(ax):
    ax.spines['top'].set_visible(False); ax.spines['right'].set_visible(False)


def main():
    H = json.load(open(os.path.join(RES, 'harm_conditioned.json')))
    qv = H['QV']
    fig, (axL, axR) = plt.subplots(1, 2, figsize=(PAGE_W, 2.8))

    # --- left: grouped bars TPR|harm vs TPR|safe ---
    order = [('Residual BDD', C_BDD), ('PCA-SPE (F1, model-free)', C_F1),
             ('PCA-SPE (F3, +droop model)', C_F3), ('Physics oracle', C_OR)]
    labels = ['BDD', 'SPE\n(F1)', 'SPE\n(F3)', 'Oracle']
    harm = [qv['detectors'][k]['tpr_harm'] for k, _ in order]
    safe = [qv['detectors'][k]['tpr_safe'] for k, _ in order]
    x = np.arange(len(order)); w = 0.38
    axL.bar(x - w/2, harm, w, color='#C0392B', label='harmful (sheds load)')
    axL.bar(x + w/2, safe, w, color='#95A5A6', label='harmless')
    axL.set_xticks(x); axL.set_xticklabels(labels, fontsize=8.5)
    axL.set_ylabel('detection rate'); axL.set_ylim(0, 1.09)
    axL.set_title('QV: detection conditioned on harm')
    axL.legend(fontsize=8, frameon=False, loc='upper left')
    despine(axL)

    # --- right: per-magnitude harm-conditioned TPR ---
    fr = [r for r in qv['frontier'] if r.get('n_harmful', 0) > 0]
    m = [r['magScale'] for r in fr]
    axR.plot(m, [r['tpr_harm_F1'] for r in fr], 'o-', color=C_F1, label='F1 (model-free)')
    axR.plot(m, [r['tpr_harm_F3'] for r in fr], 's-', color=C_F3, label='F3 (+droop model)')
    axR.plot(m, [r['tpr_harm_oracle'] for r in fr], '^--', color=C_OR, label='oracle')
    axR.fill_between(m, [r['tpr_harm_F1'] for r in fr], [r['tpr_harm_F3'] for r in fr],
                     color=C_F3, alpha=0.12)
    axR.set_xlabel('attack magnitude scale'); axR.set_ylabel('TPR on harmful attacks')
    axR.set_ylim(0, 1.05); axR.set_title('QV: closing the harmful gap')
    axR.legend(fontsize=8, frameon=False, loc='lower right')
    despine(axR)

    fig.tight_layout()
    for ext in ('png', 'pdf'):
        fig.savefig(os.path.join(FIG, 'FigD5_harm.%s' % ext), bbox_inches='tight')
    plt.close(fig)
    print('wrote FigD5_harm')


if __name__ == '__main__':
    main()
