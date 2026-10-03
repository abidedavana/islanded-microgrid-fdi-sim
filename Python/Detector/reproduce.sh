#!/usr/bin/env bash
# One-command reproduction of the Phase-2 detector results from the released
# (generated) benchmark data. Regenerating the DATA itself is a separate MATLAB
# step (see ../../MATLAB/Phase2/generate_all.m and generate_loadx.m); this script
# reproduces every reported number and figure from that data.
#
# Usage:   bash reproduce.sh
# Fast integrity check only (no figures, ~3 min):
#          python reverify_all.py && python tests/test_repro.py
set -euo pipefail

# Pin thread counts + hash seed for cross-machine determinism. (On the reference
# machine the pipeline is already byte-reproducible without this; pinning makes
# it robust to BLAS thread-order differences on other hardware.)
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 \
       NUMEXPR_NUM_THREADS=1 PYTHONHASHSEED=0

cd "$(dirname "$0")"
echo "== [1/8] main evaluation matrix =="        ; python run_eval.py
echo "== [2/8] harm-conditioned analysis (lead) ="; python harm_conditioned.py
echo "== [3/8] contamination mitigation =="       ; python contam_trim.py
echo "== [4/8] heterogeneous-load robustness =="   ; python loadx_eval.py
echo "== [5/8] figures + tables =="                ; python make_detector_figures.py
echo "== [6/8] harm-conditioned figure =="         ; python make_harm_figure.py
echo "== [7/8] INDEPENDENT re-derivation =="       ; python reverify_all.py
echo "== [8/8] reproduction/integrity tests =="    ; python tests/test_repro.py
echo
echo "DONE. Results in results/ (JSON), results/tables/ (CSV), results/figures/ (PDF+PNG)."
echo "Steps [7] and [8] must both end in ALL CHECKS PASS / ALL TESTS PASSED."
