# Corrected Islanded-Microgrid FDI Simulation

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

## Reproducibility and seeding

Every run in this repository is explicitly seeded - no reported number depends on
an unseeded draw.

| Run | Seed | Produces |
|---|---|---|
| **Headline dataset** | **42** (`p.seed`, the default) | `MATLAB/VectorDataset_PF_corrected/` and `_QV_corrected/` - every committed CSV and figure |
| Multi-seed statistical study | `p.seeds` (default `1:6`); `rng(s)` per seed | `Study_CIs.csv` |
| Attack-magnitude sweep | **7** - `rng(7)` before every cell, so only `magScale` varies | `Study_mag_sweep.csv` |
| Meter-access sweep | **7** - `rng(7)` before every cell, so only `access` varies | `Study_access_sweep.csv` |

### Verified: the committed data regenerates exactly

Re-running the headline command reproduces all **22** committed dataset files
(11 per channel, both channels) **md5-identical**:

```powershell
cd MATLAB
matlab -batch "SimulateMicrogridFDI('steps',3000,'warmup',400,'data','..\Python\Validation\RegroupedDataset\RegroupedData.csv')"
```

This was checked rather than assumed: a from-scratch regeneration was md5-compared
against the committed `features_z`, `labels`, `J_residual`, `J_naive`, `J_limited`,
`footprint`, `design`, `perceived`, `real_deviation`, `bdd_tau` and `events` files
for both channels - 22/22 match.

### RNG consumption order

If you extend or port the generator and want to stay bit-compatible with the
committed data, the order of random draws matters:

1. `selftest()` runs **before** the channels and consumes draws - do not skip it.
2. Then, per simulation step:
   `randn(130)` meter noise -> `rand()` attack decision ->
   *(only when attacked)* `rand()` attack magnitude -> `randn(130)` naive
   same-norm vector -> `rand(130)` limited-access meter mask.

A derivative generator that adds **logging only**, without inserting new draws,
stays bit-for-bit compatible with the committed datasets.

### Figure channel labels

`Fig1_BDD_stealth_*` plots the dimensionless normalised residual `J/tau`, which
aggregates all 130 meters (65 active-power: 33 `P`-injections + 32 `P`-flows;
65 reactive-power: 33 `Q`-injections + 32 `Q`-flows). Because those axes carry no
active/reactive cue on their own, each figure states its channel in the title:
**P-f = ACTIVE power (P)**, **Q-V = REACTIVE power (Q) via the Q-V droop**.
