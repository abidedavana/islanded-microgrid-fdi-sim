#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Figures for the statistical-rigor + sensitivity study (reads the Study_*.csv
files produced by SimulateMicrogridFDI('study'))."""
import os
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
SDIR = os.path.abspath(os.path.join(HERE, "..", "..", "MATLAB"))   # study CSVs live here
matplotlib.rcParams.update({"font.family": "serif", "font.size": 10,
                            "figure.dpi": 150, "savefig.dpi": 300})
C_PF, C_QV = "#C0392B", "#2980B9"

def save(fig, name):
    for ext in ("png", "pdf"):
        fig.savefig(os.path.join(SDIR, f"{name}.{ext}"), bbox_inches="tight")
    plt.close(fig)
    print("  wrote", name)

# ---- (A) multi-seed CIs (bar chart with 95% CI error bars) ----
import csv
rows = {}
with open(os.path.join(SDIR, "Study_CIs.csv")) as f:
    for r in csv.DictReader(f):
        rows[r["channel"]] = {k: float(v) if k != "channel" else v for k, v in r.items()}
metrics = [("stealthy_pct", "stealthy_ci", "Stealthy\n(evades BDD)"),
           ("limited_caught_pct", "limited_ci", "Caught at\n70% access"),
           ("event_pct", "event_ci", "Load-shedding\nevents")]
x = np.arange(len(metrics)); w = 0.36
fig, ax = plt.subplots(figsize=(5.2, 3.0))
for off, ch, c in [(-w/2, "PF", C_PF), (w/2, "QV", C_QV)]:
    vals = [rows[ch][m] for m, _, _ in metrics]
    cis = [rows[ch][ci] for _, ci, _ in metrics]
    ax.bar(x + off, vals, w, yerr=cis, capsize=4, color=c, alpha=0.8,
           label=("P-f (frequency)" if ch == "PF" else "Q-V (voltage)"))
ax.set_xticks(x); ax.set_xticklabels([m[2] for m in metrics])
ax.set_ylabel("% of attack steps"); ax.set_ylim(0, 110)
ax.set_title("Statistical rigor: mean ± 95% CI over 8 seeds")
ax.legend(fontsize=8); ax.spines[["top", "right"]].set_visible(False)
save(fig, "Fig_study_CIs")

# ---- (B) magnitude sweep ----
M = np.loadtxt(os.path.join(SDIR, "Study_mag_sweep.csv"), delimiter=",")  # chan,mag,stealth,dev,event
fig, ax = plt.subplots(1, 2, figsize=(7.0, 3.0)); fig.subplots_adjust(wspace=0.34)
for ci, c, lab, unit, ev in [(1, C_PF, "P-f", "Hz", "UFLS"), (2, C_QV, "Q-V", "pu", "UVLS")]:
    s = M[M[:, 0] == ci]
    ax[0].plot(s[:, 1], s[:, 3], "o-", color=c, label=f"{lab} mean|dev| ({unit})")
    ax[1].plot(s[:, 1], s[:, 4], "s-", color=c, label=f"{lab} {ev} events")
ax[0].set_xlabel("Attack-magnitude scale"); ax[0].set_ylabel("Mean |real deviation|")
ax[0].set_title("(a) Physical impact vs. attack size"); ax[0].legend(fontsize=7.5)
ax[1].set_xlabel("Attack-magnitude scale"); ax[1].set_ylabel("Protection events (%)")
ax[1].set_title("(b) Load-shedding vs. attack size"); ax[1].legend(fontsize=7.5)
for a in ax: a.grid(alpha=0.25); a.spines[["top", "right"]].set_visible(False)
save(fig, "Fig_study_magnitude_sweep")

# ---- (C) meter-access sweep ----
A = np.loadtxt(os.path.join(SDIR, "Study_access_sweep.csv"), delimiter=",")  # chan,access,detected
fig, ax = plt.subplots(figsize=(5.0, 3.0))
for ci, c, lab in [(1, C_PF, "P-f (frequency)"), (2, C_QV, "Q-V (voltage)")]:
    s = A[A[:, 0] == ci]
    ax.plot(100 * s[:, 1], s[:, 2], "o-", color=c, label=lab)
ax.set_xlabel("Attacker meter access (%)"); ax.set_ylabel("Attack detected by BDD (%)")
ax.set_title("Detection vs. attacker reach"); ax.set_ylim(-5, 105)
ax.legend(fontsize=8); ax.grid(alpha=0.25); ax.spines[["top", "right"]].set_visible(False)
save(fig, "Fig_study_access_sweep")

print("Study figures saved to", SDIR)
