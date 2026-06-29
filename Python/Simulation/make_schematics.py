#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate the two schematic figures the paper needs:
   Fig_topology.png        - modified IEEE 33-bus islanded feeder one-line with DERs
   Fig_attack_pipeline.png - cyber-physical FDI attack-injection architecture
Saved into ../../MATLAB so they sit with the other figures."""
import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.abspath(os.path.join(HERE, "..", "..", "MATLAB"))
matplotlib.rcParams.update({"font.family": "serif", "font.size": 9,
                            "figure.dpi": 150, "savefig.dpi": 300})
C_DER, C_BUS, C_LINE, C_ATT = "#C0392B", "#34495E", "#7F8C8D", "#C0392B"

def save(fig, name):
    for ext in ("png", "pdf"):
        fig.savefig(os.path.join(OUT, f"{name}.{ext}"), bbox_inches="tight")
    plt.close(fig)
    print("  wrote", name)

# ============================================================ 1) ONE-LINE
pos = {}
for i in range(1, 19):           # main feeder 1..18
    pos[i] = (i - 1, 0)
for k, b in enumerate([19, 20, 21, 22]):  pos[b] = (1 + k, -1.1)   # lateral @2
for k, b in enumerate([23, 24, 25]):      pos[b] = (2 + k, -2.2)   # lateral @3
for k, b in enumerate([26,27,28,29,30,31,32,33]): pos[b] = (5 + k, 1.1)  # lateral @6
branches = [(1,2),(2,3),(3,4),(4,5),(5,6),(6,7),(7,8),(8,9),(9,10),(10,11),
            (11,12),(12,13),(13,14),(14,15),(15,16),(16,17),(17,18),
            (2,19),(19,20),(20,21),(21,22),(3,23),(23,24),(24,25),
            (6,26),(26,27),(27,28),(28,29),(29,30),(30,31),(31,32),(32,33)]
der = {1, 6, 18, 25}

fig, ax = plt.subplots(figsize=(7.0, 3.2))
for a, b in branches:
    (x1, y1), (x2, y2) = pos[a], pos[b]
    ax.plot([x1, x2], [y1, y2], "-", color=C_LINE, lw=1.0, zorder=1)
for b, (x, y) in pos.items():
    if b in der:
        ax.scatter(x, y, s=120, marker="s", color=C_DER, zorder=3,
                   edgecolors="k", linewidths=0.5)
        ax.annotate(f"{b}", (x, y), color="white", ha="center", va="center",
                    fontsize=6.5, zorder=4, fontweight="bold")
    else:
        ax.scatter(x, y, s=42, marker="o", color=C_BUS, zorder=2)
        ax.annotate(f"{b}", (x, y + 0.16), color=C_BUS, ha="center", fontsize=5.5, zorder=4)
ax.annotate("Bus 1\n(grid-forming, angle ref.)", pos[1], xytext=(-0.3, 0.7),
            fontsize=6.5, color=C_DER,
            arrowprops=dict(arrowstyle="->", color=C_DER, lw=0.7))
ax.scatter([], [], s=80, marker="s", color=C_DER, edgecolors="k",
           label="Grid-forming DER (buses 1, 6, 18, 25)")
ax.scatter([], [], s=42, marker="o", color=C_BUS, label="Load bus")
ax.legend(loc="lower right", fontsize=7, frameon=False)
ax.set_title("Modified IEEE 33-bus islanded microgrid (no slack; PCC bus 34 removed)")
ax.axis("off"); ax.set_xlim(-1, 17.5); ax.set_ylim(-3.0, 2.2)
save(fig, "Fig_topology")

# ============================================================ 2) ATTACK PIPELINE
fig, ax = plt.subplots(figsize=(7.0, 3.6))
ax.set_xlim(0, 10); ax.set_ylim(0, 10); ax.axis("off")

def box(x, y, w, h, text, fc, tc="white", fs=8.5):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.08",
                 linewidth=1.0, edgecolor="k", facecolor=fc, zorder=2))
    ax.text(x + w/2, y + h/2, text, ha="center", va="center", color=tc,
            fontsize=fs, zorder=3, wrap=True)

def arrow(x1, y1, x2, y2, color="#2C3E50", style="-|>", lw=1.4, ls="-"):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle=style,
                 mutation_scale=12, color=color, lw=lw, linestyle=ls, zorder=4))

# layers
box(0.4, 0.6, 9.2, 1.7, "Physical microgrid  —  33-bus islanded feeder, 4 grid-forming DERs (droop)",
    "#27AE60")
box(0.4, 4.2, 9.2, 1.3, "Communication network  (DNP3 / Modbus / IEC 61850)", "#95A5A6", tc="black")
box(0.4, 7.6, 9.2, 1.7,
    "Control centre  —  WLS state estimation  +  chi-squared BDD  →  secondary control",
    "#2980B9")

# measurement path up, setpoints path down
arrow(2.2, 2.3, 2.2, 4.2, color="#2C3E50")
ax.text(1.4, 3.3, "meters z", fontsize=7.5, color="#2C3E50")
arrow(2.2, 5.5, 2.2, 7.6, color="#2C3E50")
arrow(7.8, 7.6, 7.8, 5.5, color="#2C3E50")
ax.text(8.0, 6.4, "setpoints", fontsize=7.5, color="#2C3E50")
arrow(7.8, 4.2, 7.8, 2.3, color="#2C3E50")
ax.text(8.0, 3.2, "DER P*, V0", fontsize=7.5, color="#2C3E50")

# attacker (MITM on comms) -- placed in the gap between the physical and
# communication layers so it does NOT overlap the communication-box text
box(3.5, 3.05, 3.0, 0.7, "FDI attacker (MITM)", "#C0392B", tc="white", fs=8)
# tap the communications link: corrupted measurements pushed up to the control centre
ax.add_patch(FancyArrowPatch((5.0, 3.75), (5.0, 4.2), arrowstyle="-|>",
             mutation_scale=14, color=C_ATT, lw=2.0, zorder=6))
# stealthy-injection annotation, centred and clear of the "DER P*, V0" label
ax.text(5.0, 2.6, r"inject  $z_a = z + a,\ a = Hc$  (stealthy)", ha="center",
        fontsize=8, color=C_ATT, zorder=6)

ax.set_title("Stealthy FDI attack-injection architecture and closed loop", fontsize=9.5)
save(fig, "Fig_attack_pipeline")
print("Schematics saved to", OUT)
