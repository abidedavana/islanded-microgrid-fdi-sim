# Phase 2 — Detector Results (2026-07-17/18 run)

Companion to `DETECTOR_DESIGN.md` (protocol) and `PHASE2_NOTES.md` (lessons).
All numbers from `Python/Detector/results/` (eval_PF.json, eval_QV.json,
eval_crosschannel.json, contam_trim.json, latency.json; tables/ + figures/).
Reproduction: `MATLAB/Phase2/generate_all.m` (data, ~27 min) then
`python run_eval.py && python contam_trim.py && python make_detector_figures.py`.
Everything seeded; generator verified bit-for-bit vs the frozen Phase-1 sim
before use (PHASE2_NOTES E6). Thresholds: every detector calibrated once on
clean VAL at 1% FPR (same alpha as the BDD); TEST = 5 disjoint runs, t-CIs.

## 0. HARM-CONDITIONED HEADLINE (the paper's lead; `harm_conditioned.py`)

The operative metric is detection **conditioned on the attack shedding load**
(TPR_S), + harmful-but-undetected HBU=1-TPR_S. Pooled TEST+MAG stealthy attacks.

| QV detector | access | TPR\|harm | TPR\|harmless | HBU |
|---|---|---|---|---|
| Residual BDD | — | 0.000 | 0.000 | 1.000 |
| PCA-SPE F1 | model-free | 0.909 | 0.275 | 0.091 |
| AE-MLP F1 | model-free | 0.897 | 0.261 | 0.103 |
| PCA-SPE F3 | +droop model | 0.980 | 0.422 | 0.020 |
| AE-MLP F3 | +droop model | 0.999 | 0.621 | 0.001 |
| Physics oracle | +model† | 0.999 | 0.728 | 0.001 |

PF: all non-degenerate detectors TPR|harm=1.000, HBU=0.000.
Three findings: (1) manifold detector **self-triages** by harm (0.909 vs 0.275 —
3.3x more likely to catch a harmful attack); raw 0.706 understates protection.
(2) **Gap**: model-free leaves 9.1% of *harmful* QV attacks undetected, localized
to the ~0.8x magnitude band (FigD5 right). (3) **Closed**: droop-model physics
features (F3) → HBU 0.1%, matching oracle, at unchanged 1% FPR. This is the
"find a gap, solve it" arc. Independently reproduced by scratch `the_gap.py`.
Figure: FigD5_harm. Table: tables/T5_harm.csv.

### 0b. Within-magnitude triage (paper §VI-B / Table IV) — triage is NOT just magnitude
At FIXED attack magnitude, model-free F1 still separates harmful vs harmless QV
attacks (harmful/harmless split decided by operating point, not attacker):
mag 0.6: 1.000/0.269 · 0.8: 0.791/0.345 · 1.0: 0.913/0.408 · 1.2: 0.941/0.405 ·
1.4: 0.964/0.481. PF uniformly 1.000/1.000 (no sparing). Defuses the "just
magnitude" objection. Source: `harm_conditioned.json` within_magnitude block;
test: `test_within_magnitude_triage`.

## 1. Conventional unconditional TPR (Table I, for comparability — understates)

| Detector | PF | QV | realized FPR (PF/QV) |
|---|---|---|---|
| Residual BDD (incumbent) | 0.000±0.000 | 0.000±0.000 | 0.009 / 0.009 |
| **PCA-SPE F1 (pre-registered headline, semi-sup, raw z)** | **1.000±0.000** | **0.706±0.061** | 0.013 / 0.010 |
| AE-MLP F3 (best semi-sup, post-hoc) | 1.000±0.000 | 0.938±0.025 | 0.012 / 0.008 |
| PCA-SPE F3 | 1.000±0.000 | 0.832±0.053 | 0.015 / 0.009 |
| Physics oracle (droop residuals, exact params) | 1.000±0.000 | 0.972±0.009 | 0.007 / 0.008 |
| Supervised (LogReg/RF/HistGB/MLP, F1) | 1.000 | 1.000 | ~0.004–0.013 |
| IForest F1 (reported failure) | 0.038±0.025 | 0.022±0.018 | 0.017 / 0.016 |

Notes: AE-MLP F3 as "best semi-supervised" is a post-hoc label (semi-sup model
selection cannot use TPR without attack labels); the pre-registered headline
number is PCA-SPE F1. PCA-T2 0.47, OC-SVM 0.41 on QV — full matrix in
`tables/T1_main.csv`.

## 2. The two channels are qualitatively different (paper's central asymmetry)

- **PF is loud in every honest lens**: 0.29 pu meter footprint; detector-side
  *iterative* AC-WLS cannot even fit attacked snapshots (clean J ≤ 178 vs
  attack J ≥ 3,950 — the O(c²) mismatch of PHASE2_NOTES E2, huge because PF
  needs |c| ~ 0.4–1.1 pu) → an SE-upgrade alone defeats the PF attack; report
  as baseline. Every detector except IForest: TPR 1.0 at every magnitude.
- **QV is the genuinely stealthy channel**: 0.0097 pu footprint; iterative-SE
  residual blind (97.6% of stealthy attacks under the clean 99th pct; attack
  J median = clean median). The attack hides in the near-unobservable
  voltage-level direction of the power-only measurement set (cond(HᵀH)≈3.5e11,
  E8). Detection must come from operational priors — the droop manifold.

## 3. Stealth–impact frontier (QV, magnitude sweep, fixed deployed thresholds)

| magScale | mean dev (pu) | P(shed) | SPE-F1 | SPE-F3 | Oracle | BDD |
|---|---|---|---|---|---|---|
| 0.2 | 0.045 | 0.000 | 0.012 | 0.024 | 0.098 | 0 |
| 0.4 | 0.061 | 0.000 | 0.074 | 0.124 | 0.448 | 0 |
| 0.6 | 0.078 | 0.032 | 0.292 | 0.408 | 0.736 | 0 |
| 0.8 | 0.094 | 0.392 | 0.520 | 0.676 | 0.908 | 0 |
| 1.0 | 0.111 | 0.686 | 0.754 | 0.852 | 0.976 | 0 |
| 1.4 | 0.140 | 0.946 | 0.938 | 0.974 | 0.996 | 0 |

Detection rises with magnitude *ahead of* harm: the undetected residue is
concentrated in attacks that do not shed load. This is the frontier thesis
(PHASE2_NOTES E2) quantified, incl. below-training magnitudes (0.2–0.8).
Latency (persistent episodes, CAD cells): when an episode is detectable at
all, median time-to-alarm is 1 step (p90 ≤ 2); missed episodes are the
small-design ones. PF: 100% of episodes at step 1.

## 4. Defense-in-depth (variant coverage, QV)

naive same-norm: BDD 0.999, SPE 0.999 (sanity holds). RF misses 32% of naive
injections (supervised overfit to the trained family — report). Limited
access (70%): BDD 0.769, SPE 0.536, **BDD ∪ SPE 0.815** — the union beats
either alone; ML covers the BDD-evading remainder only partially, supervised
RF covers 0.992 of it. Layered residual+manifold is the deployment story.

## 5. Supervised generalization stress (cross-channel)

Train PF → test QV: LogReg 0.002, MLP 0.006, RF 0.134, HistGB 0.164 (F1);
only HistGB **F3** transfers (0.937) — the physics features carry the
generalization. QV → PF: F1 models all 1.0 (PF is loud), but LogReg/MLP F3
collapse to 0.00. Conclusion: supervised numbers are attack-family-
conditional; the semi-sup manifold detector needs no transfer.

## 6. Contamination (training-hygiene sensitivity — a real vulnerability)

QV PCA-SPE: 0.71 (clean) → 0.53 / 0.41 / 0.13 / 0.03 at 0.5/1/2/5%
contamination. PF collapses at 0.5% (attack outliers capture the subspace).
One-pass 10% trim partially repairs QV (0.53→0.68 at 0.5%; 0.13→0.29 at 2%)
but NOT PF (contaminated-fit scores rank attacks low, trim removes wrong
rows). Robust-PCA / attack-free calibration window are required; state
plainly in the paper.

## 7. Temporal features (E1 cadence guard — negative result, by design)

Δz features never help and actively dilute the semi-sup detector under
persistent attacks (QV SPE F1d 0.36–0.61 vs F1 0.67–0.93 across cadence
cells incl. the i.i.d.-redraw control). RF F1d ≈ F1 in-family. The design
doc's original exclusion of Δ-features is now empirically grounded, not
assumed. Caveat: the CAD100 cell holds ONE design draw for the whole run
(persist + attackProb 1.0) — cadence conclusions cite CAD025–075 + CADI100.

## 8. Heterogeneous-load robustness (E9 LOADX — user-approved, done)

Per-bus multiplicative load jitter (5% std) thickens the rank-1 manifold.
Generator option `loadjitter` added; default path re-verified bit-for-bit
(VERIFY42B md5 MATCH). loadx_eval.json:

| Channel | Condition | TPR (stealthy) | realized FPR |
|---|---|---|---|
| PF | reference (homogeneous) | 1.000 | 0.013 |
| PF | shift (mis-calibrated)  | 1.000 | 0.588 |
| PF | retrained (matched)     | 1.000 | 0.018 |
| QV | reference (homogeneous) | 0.706 | 0.010 |
| QV | shift (mis-calibrated)  | 0.930 | 0.563 |
| QV | retrained (matched)     | 0.440 | 0.015 |

Reading: **PF fully robust.** **QV degrades but survives** (0.71→0.44 at
matched 5% retrain, FPR held) — a thicker normal manifold genuinely masks more
of the 0.0097 pu footprint; still >> BDD's 0.000, frontier intact. **Shift row
is a deployment lesson**: a homogeneous-calibrated detector on heterogeneous
data blows FPR to ~0.56 — calibration window MUST match deployment regime
(our protocol already calibrates on same-regime held-out data). Consequence for
claims: QV *absolute* numbers in §1 are optimistic to the degree a real feeder
is more heterogeneous than this model; the *mechanism* (manifold detection +
frontier) transfers. Multi-feeder field-data study = the Transactions-grade
next step. This is now Table II + §VI-H + limitation (ii) in the paper.

## 9. Honest-limitations register (additions from this run)

- Rank-1 load model (E9): quantified above (QV 0.71→0.44 under 5% jitter);
  stated as limitation (ii) with the field-data study as next step.
- 1% FPR at 1-min scans ≈ 14.4 false alarms/day — alarm-budget discussion
  needed; thresholds are per-scan, not per-day.
- Semi-sup model selection cannot be validated without labeled attacks;
  pre-registration + full-matrix reporting is our answer.
- Tree-ensemble thresholds calibrate poorly at small FPR (score granularity);
  realized FPRs reported for all models.
- Single test system, simulated data, no HIL (carried from Phase 1).
