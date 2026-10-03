# Corrected Islanded-Microgrid FDI Simulation

> **This repository now covers both phases.**
> **Phase 1** (below) — the islanded-droop FDI simulation and the stealth/impact
> characterisation. **Phase 2** (see [Phase 2](#phase-2--ml-detector)) — the
> defender side: a semi-supervised detector, its evaluation pipeline, the
> reproduction tests and the pinned environment.
> Every seed used anywhere is listed in [Reproducibility and seeding](#reproducibility-and-seeding).

This replaces the previous `MATLAB/SimulateIsland.m` and `MATLAB/SimulateIsland_Q.m`,
which had physics and correctness defects that would not survive peer review
(detailed below). The pipeline is now MATLAB-generated with two Python helpers:

| File | Role |
|---|---|
| `MATLAB/SimulateMicrogridFDI.m` | **Simulation generator** (MATPOWER-free; verified in MATLAB R2026a) |
| `Python/Validation/DataPreprocessing.py` | (optional) builds `RegroupedData.csv` load input from the raw UCI file |
| `Python/Simulation/make_figures.py` | IEEE-style figures from the generated datasets |

> A Python reference implementation (`microgrid_fdi_sim.py`) was used to develop and
> cross-validate the model, then removed in favour of the MATLAB generator. Self-test
> T1 (`f = 49.9941 Hz`, `Vmin = 0.9221`, losses `58.7 kW`) was identical across both
> toolchains. MATLAB is now the single source of truth for data generation.

---

## Why the old simulation was wrong

1. **No real frequency dynamics.** Bus 1 was a MATPOWER *slack* with effectively
   infinite headroom, so it absorbed all power imbalance. The reported frequency,
   `f = f_nom − k_p·(P_gen − P_load)`, was therefore `≈ f_nom − k_p·losses ≈ const`.
   Frequency could not actually move.
2. **Impact came from non-convergence.** The only large `Δf` values were produced
   by the power-flow *failure* fallback, not by physics.
3. **1000× load-unit error.** kW dataset values were written into MW fields while
   generation was sized from `total/1000`.
4. **Dimensionally invalid attack vector.** A power quantity (MW) was injected into
   a voltage-*angle* state (rad) via an arbitrary `×0.6` factor.
5. **The P-f script never attacked** (`attack_prob = 0.00`), contradicting the paper.
6. **Circular / implausible stealth.** Stealth was true by construction with the
   same `H`, and (in Q-V) the attack always saturated the DER Q limits.

## What the corrected model does (and is physically correct)

- **True islanded droop power flow, no slack.** Unknowns `[θ₂..θ_N, V₁..V_N, f]`;
  the common system frequency `f` is solved from global active-power balance.
  Every grid-forming inverter (buses 1, 6, 18, 25) shares load via P-f and Q-V
  droop. Solved with Newton–Raphson and an analytic Jacobian.
- **AC WLS state estimation + chi-squared BDD** with a proper threshold
  `τ = χ²_{dof}(1−α)` (`dof = 65`, `α = 1% ⇒ τ ≈ 94.4`), reported alongside the
  empirical `μ+3σ`.
- **Stealthy FDI `a = H c`** built as a **minimum-footprint** attack
  (`min ‖Hc‖ s.t. target estimate bias`) so it passes both the residual test
  *and* gross meter-limit checks.
- **Faithful closed loop:** the operator's secondary control reacts to the
  attacker-biased estimate and mis-dispatches the DERs; the droop power flow is
  **re-solved** (converged) so the **real** frequency / voltage genuinely deviate.
- **Honest detectability study** (non-circular): each attack is also scored vs.
  (a) a same-norm naive random injection and (b) a limited-meter-access attacker.

## Parameters (use these in the paper's §8 / justification table)

| Symbol | Value | Basis |
|---|---|---|
| Base | 5 MVA, 12.66 kV, 50 Hz | Baran & Wu 33-bus |
| Grid-forming buses | 1, 6, 18, 25 (bus 1 = angle ref) | all droop, **no slack** |
| DER P ratings | 0.40, 0.20, 0.20, 0.20 pu | 2/1/1/1 MW |
| DER Q ratings | 0.30, 0.15, 0.15, 0.15 pu | — |
| `m_p` (P-f droop) | `0.01·f_nom / P_rate` Hz/pu | 1 % frequency droop |
| `n_q` (Q-V droop) | `0.05·V_nom / Q_rate` puV/puQ | 5 % voltage droop |
| Meter noise `σ` | 1e-3 pu | Class-0.5S smart meter |
| BDD threshold | `χ²₆₅(0.99) ≈ 94.4` | 1 % false-alarm rate |
| UFLS/OFLS | ∓0.20 Hz | first-stage relay band |
| UVLS/OVLS | ∓0.10 pu | ±10 % voltage band |
| Attack probability | 25 % (post-warmup) | — |
| Warmup | 400 steps | BDD calibration only |

## How to run (from the beginning)

```powershell
# 1. (OPTIONAL) build the real UCI load input. Skip to use the built-in synthetic load.
#    Needs RawDataset/household_power_consumption.txt from
#    https://archive.ics.uci.edu/dataset/235/individual+household+electric+power+consumption
cd Python/Validation
python DataPreprocessing.py            # -> RegroupedDataset/RegroupedData.csv

# 2. Generate the ML dataset with MATLAB (R2019a+; no MATPOWER required).
cd ../../MATLAB
#   real UCI load:
matlab -batch "SimulateMicrogridFDI('steps',3000,'warmup',400,'data','..\Python\Validation\RegroupedDataset\RegroupedData.csv')"
#   OR synthetic load:
matlab -batch "SimulateMicrogridFDI('steps',3000,'warmup',400)"
#   -> writes MATLAB/VectorDataset_PF_corrected/ and _QV_corrected/

# 3. Make the figures (Python helper). --base points at the folder holding the datasets.
cd ../Python/Simulation
python make_figures.py --base ../../MATLAB
```

The ML dataset is `features_z.csv` (X, 130 cols) + `labels.csv` (y) in each
`VectorDataset_*_corrected/` folder.

## Verified results (seed 42, 2600 logged steps, real UCI load)

| Metric | P-f (frequency) | Q-V (voltage) |
|---|---|---|
| FDI stealthy (J < τ) | 99.2 % | 99.0 % |
| Mean meter footprint | 0.293 pu | 0.0097 pu |
| Naive same-norm caught | 100 % | 100 % |
| Limited access (70 % meters) caught | 100 % | 81.7 % |
| Mean \|real deviation\| | 0.253 Hz | 0.110 pu |
| Max \|real deviation\| | 0.417 Hz | 0.153 pu |
| Protection events | 558 UFLS | 458 UVLS |
| Power-flow failures | **0** | **0** |

The ~1 % non-stealthy rate equals the chosen chi-square false-alarm rate (it is
noise, not the attack). Impact comes entirely from **converged** power flows.

## Findings worth stating in the paper

- A stealthy FDI on droop control causes **real, converged** frequency/voltage
  excursions that trip UFLS/UVLS — the threat is physical, not a residual artifact.
- The voltage (Q-V) attack hides in a ~0.01 pu meter footprint; the frequency
  (P-f) attack needs ~0.30 pu — frequency manipulation is intrinsically louder.
- Residual-based BDD is bypassed **by construction**, but stealth **requires broad
  meter compromise**: with only 70 % meter access the attack is caught 76–100 %.
  This — not residual checking — is the realistic defensive lever, and motivates
  the Phase-2 ML detector.

## Honest limitations (state these; reviewers will ask)

- State estimation is **linearised** about each operating point (standard for FDI
  stealth analysis); a full iterative AC-SE is a natural extension.
- Line admittance is held at nominal frequency (frequency-dependent reactance is
  an extension; it would only make `f` *more* observable, not less).
- The secondary controller is a single-step proportional restoration, not a full
  dynamic AGC loop.

---

# Phase 2 — ML detector

Phase 1 showed the chi-squared bad-data detector (BDD) is blind to the stealthy
`a = Hc` attack *by construction*. Phase 2 is the defender's side: a detector that
is **not** blind, trained only on attack-free operation and needing no network or
droop model.

| File | Role |
|---|---|
| `MATLAB/Phase2/GenerateDetectorData.m` | Phase-2 data generator — a *logging derivative* of the frozen Phase-1 simulator (adds load-segment offset, named outputs, variant/stealth logging, persistent-attacker mode, per-bus load jitter). Verified **bit-for-bit** against Phase 1 before use. |
| `MATLAB/Phase2/generate_all.m` | The main data campaign (TRAIN / VAL / 5x TEST / magnitude sweep / cadence cells). |
| `MATLAB/Phase2/generate_loadx.m` | Heterogeneous-load robustness cells (per-bus load jitter). |
| `Python/Detector/gridmodel.py` | Detector-side **iterative Gauss-Newton AC-WLS** state estimator (flat start, damped line search) + the physics (droop-consistency) features. Does *not* reuse the simulator's Jacobian. |
| `Python/Detector/models.py` | Detector zoo: semi-supervised (PCA-SPE, PCA-T2, autoencoder, OC-SVM, isolation forest) and supervised (LogReg, RF, HistGB, MLP). |
| `Python/Detector/run_eval.py` | Main evaluation matrix (thresholds, CIs, variants, contamination, cadence, ablations). |
| `Python/Detector/harm_conditioned.py` | **Headline analysis**: detection conditioned on physical harm (load shedding). |
| `Python/Detector/loadx_eval.py`, `contam_trim.py` | Robustness / mitigation studies. |
| `Python/Detector/reverify_all.py` | Independent re-derivation of every reported rate (must print `ALL CHECKS PASS`). |
| `Python/Detector/tests/test_repro.py` | Reproduction + integrity tests (metrics, leakage, determinism, estimator independence). |
| `Python/Detector/requirements.txt` | Pinned environment. |
| `Python/Detector/reproduce.sh` | One-command reproduction. |

Design and protocol: `DETECTOR_DESIGN.md`. Results record: `PHASE2_RESULTS.md`.

### Running Phase 2

```bash
# 1. Generate the Phase-2 datasets (MATLAB R2019a+; ~27 min + ~24 min).
#    NOT committed: ~754 MB, and fully regenerable because every run is seeded.
cd MATLAB/Phase2
matlab -batch generate_all
matlab -batch generate_loadx

# 2. Reproduce every number, figure and table in one command.
cd ../../Python/Detector
pip install -r requirements.txt
bash reproduce.sh
```

`reproduce.sh` ends with two gates that must both pass:
`reverify_all.py` -> `ALL CHECKS PASS`, and `tests/test_repro.py` -> `ALL TESTS PASSED`.

---

## Reproducibility and seeding

Every run in both phases is explicitly seeded; no result depends on an unseeded
draw. Re-running the commands above reproduces the committed numbers exactly.

**Phase 1 — `MATLAB/SimulateMicrogridFDI.m`**

| Run | Seed | Notes |
|---|---|---|
| Headline dataset | **42** | `rng(p.seed)`, default `seed = 42`; 3000 steps, 400 warmup. This is the seed behind `VectorDataset_*_corrected/`. |
| Multi-seed CI study | per-seed `rng(s)` | `'study'` mode loops over `p.seeds`. |
| Magnitude sweep | **7** | `rng(7)` fixed so only `magScale` varies. |
| Meter-access sweep | **7** | `rng(7)` fixed so only `access` varies. |

**Phase 2 — `MATLAB/Phase2/generate_all.m`** (all UCI load segments disjoint)

| Split | Seed(s) | UCI offset | Logged steps |
|---|---|---|---|
| TRAIN | 101 | 0 | 18,000 |
| VAL | 105 | 40,000 | 4,000 |
| TEST x5 | 201-205 | 80,000 ... 140,000 (15k apart) | 4,000 each |
| MAG (magScale 0.2-1.4) | 301 | 160,000 | 2,000 each |
| CAD (persistent attacker) + CADI100 control | 401 | 165,000 | 2,000 each |

**Phase 2 — `MATLAB/Phase2/generate_loadx.m`** (heterogeneous load)

| Split | Seed(s) | UCI offset | Jitter |
|---|---|---|---|
| LXTRAIN / LXVAL | 501 / 505 | 20,000 / 45,000 | 5 % |
| LXT5 x5 | 511-515 | 50,000 ... 74,000 (6k apart) | 5 % |
| LXT2 x2 | 521-522 | 168,000 / 174,000 | 2 % |

**Python side.** Every stochastic estimator takes `random_state = SEED` (`SEED = 0`
in `models.py`); subsampling uses `numpy.random.default_rng(SEED)`. `reproduce.sh`
additionally pins `OMP_NUM_THREADS`/`PYTHONHASHSEED` so results are stable across
machines with different BLAS thread counts. Re-running the pipeline twice produced
byte-identical outputs, including after deleting the physics-feature cache and
recomputing every state estimate from scratch.

**Bit-for-bit gate.** Before any Phase-2 data is trusted, `GenerateDetectorData.m`
is run at the frozen Phase-1 configuration (seed 42, 3000 steps, 400 warmup,
offset 0) and must reproduce the committed `VectorDataset_*_corrected/` files
**md5-identical** — all 22 files across both channels. This proves the Phase-2
generator changed only logging, never the physics or the RNG stream.
