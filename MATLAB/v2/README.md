# Corrected Phase-1 simulator (v2)

`SimulateMicrogridFDI_v2.m` extends the Phase-1 simulator
(`MATLAB/SimulateMicrogridFDI.m`, unchanged) with switchable options. They
replace the idealisations of the original study with a realistic defender and
a physically consistent attacker. With every v2 option at its default, v2
reproduces the committed datasets in `MATLAB/VectorDataset_PF_corrected/` and
`MATLAB/VectorDataset_QV_corrected/` byte for byte (self-test T1).

The test system is the modified IEEE 33-bus feeder operated as an island:
- no slack bus, with frequency solved from the droop power balance;
- grid-forming droop DERs at buses 1, 6, 18 and 25;
- 3,000 one-minute steps of the UCI household load (`Python/Validation/RegroupedDataset/RegroupedData.csv`), with a 400-step warm-up and an attack probability of 0.25 per step.

## What v2 changes

| Option | Original (default) | Corrected setting | Effect |
|---|---|---|---|
| `'vmeters'` | `'none'`: 130 power meters | `'der'` | Adds \|V\| meters at the DER buses (134 meters, χ² with 69 d.o.f.). |
| `'attack'` | `'linear'`: a = H c | `'ac'` | AC-consistent injection a = h(x+c) − h(x), with c designed as before (minimum-norm). |
| `'attmeters'` | `'all'` | `'legacy'` | The attacker is unaware of the \|V\| meters and leaves them untouched. |
| `'estimator'` | `'linear'`: one-shot WLS at the true state | `'acwls'` | Iterative nonlinear WLS (Levenberg–Marquardt): warm start from the previous accepted estimate, flat-start fallback, stop when max\|Δx\| < 1e-8 or after 50 iterations. |
| `'ctrlinput'` | `'oracle'`: x_true + c | `'estimate'` | The secondary controller acts on the estimator's output, noise included. |
| `'attknow'` | `'true'` | `'stale'` | The attacker builds H, c and h from the previous step's state. |
| `'fsource'` | `'inferred'` | `'measured'` | The frequency loop uses the measured frequency (noise `'fnoise'`, default 1 mHz) instead of the frequency inferred from the estimate. |
| `'outDir'` | `MATLAB/v2/out/<tag>` | — | Output folder. v2 refuses to write into the committed dataset folders. |

The original options (`'seed'`, `'steps'`, `'warmup'`, `'magScale'`, `'access'`,
`'attackprob'`, `'data'`) are kept. `'data','uci'` selects the repository's
`RegroupedData.csv`.

The event labels in the output CSVs (`UFLS`/`UVLS`) mark crossings of two
deviation criteria: frequency below −0.2 Hz, and lowest bus voltage below
0.90 p.u. They are screening criteria, not protection-relay settings.

## How to run (MATLAB R2026a; no toolboxes required)

```matlab
cd MATLAB/v2
v2_selftest                    % T0-T5, about 3 min; results in out/selftest_results.txt
v2_pilot('corrected', 1, 800, 200)   % one corrected pilot run, both channels

% the corrected configuration used in the study (C2), one seed:
o = SimulateMicrogridFDI_v2('seed',1,'data','uci', ...
      'vmeters','der','attack','ac','estimator','acwls', ...
      'ctrlinput','estimate','attknow','true');
```

**Full campaign** (configurations in `campaign/campaign_configs.m`):

```matlab
cd MATLAB/v2/campaign
run_campaign(1, 'run1')        % one worker; start up to 4 in parallel with ids 1..4
run_campaign('aggregate')      % tidy CSVs, 95% Student-t intervals, Fisher tests, figures
```

The full campaign (20 seeds × 3,000 steps × 2 channels × all configurations)
takes about 1 h on a 4-worker desktop.

## Self-tests (`v2_selftest.m`)

| Test | Checks |
|---|---|
| T0 | The augmented Jacobian matches finite differences, and the AC-WLS recovers the state from noise-free data. |
| T1 | **Regression:** with the defaults, all 22 committed CSVs are byte-identical. |
| T2 | AC-consistency: z_att − noise = h(x_true + c) to 1e-10, also checked against an independent branch-flow model. |
| T3 | AC-WLS on 500 normal steps: ≥ 99% converge, and the false-alarm count is inside the binomial 95% range for α = 1%. |
| T4 | The original linear attack is detected by AC-WLS with \|V\| meters (81/81 attacked P–f steps). |
| T5 | Timing: about 17 ms per step for the corrected configuration. |

All six pass. Note: T1 is exact with MATLAB's default multithreaded BLAS. With
`-singleCompThread`, round-off differences of up to 4e-7 appear, while labels
and events are unchanged.

## Results (20 seeds; `campaign/campaign_summary_main.csv`, `campaign/campaign_fisher.csv`)

Values are rates over attacked steps (mean of 20 seeds) and pooled Fisher exact
tests comparing alarm rates on attacked and normal steps.

| Config | Setting | P–f alarm, attacked / normal | P–f crossings | Q–V alarm, attacked / normal | Q–V crossings |
|---|---|---|---|---|---|
| C0 | original (linear attack, linear SE, no \|V\| meters, oracle controller) | 1.07% / 1.02% (p = 0.62) | 85.9% | 1.00% / 0.94% (p = 0.57) | 65.1% |
| C1 | corrected defender vs. the original linear attack | **100%** / 1.07% | 81.3% | 1.33% / 0.92% | **0%** |
| C2 | corrected defender vs. AC-consistent attack (also falsifies \|V\|) | 1.08% / 1.07% (p = 0.96) | **86.0%** | 1.09% / 0.92% (p = 0.089) | **65.1%** |
| C3 | C2 with a one-step-stale attacker | 1.09% / 1.07% | 86.0% | 1.07% / 0.92% | 65.1% |
| C4 | C2 with measured-frequency secondary control | 1.08% / 1.07% | **0%** | same as C2 | 65.1% |

- **C2 harmful-and-undetected steps** (cross a criterion without an alarm): 85.0% (P–f) and 64.3% (Q–V).
- **Normal steps:** no normal step crosses a criterion in any configuration.
- **Estimator convergence:** the AC-WLS converged on every step.
- **Magnitude sweep (C6, 10 seeds, 0.25×–1.5×):** the alarm rate stays at the false-alarm level, while harmful-and-undetected rises from 0 to about 98% (`campaign/figs/fig_b_sweep.*`).
- **C1 note:** the controller does not act on alarms, which is why detected C1 P–f attacks still cross. Holding the setpoints on an alarm removes that harm.

Figures: `campaign/figs/fig_a_alarm.*` (alarm rates C0–C3),
`fig_b_sweep.*` (magnitude sweep), `fig_c_fsource.*` (inferred vs. measured
frequency).

## Scope and limitations

- The model is quasi-static: one secondary-control update per one-minute step, constant-power loads, and no inverter dynamics.
- It covers a single feeder and a single load profile applied at every bus.
- The attacker knows the network model and the current state, and can write every meter.
- These results characterise the attack and its dependence on the control architecture; they are not a detector.
