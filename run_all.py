#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
run_all.py  --  one-shot runner for the microgrid FDI pipeline.

Runs everything in order, no folder-hopping:
  1. (if needed) build RegroupedData.csv from the raw UCI load file
  2. generate the dataset with MATLAB  -> MATLAB/VectorDataset_*_corrected/
  3. make the figures with Python

Usage (from anywhere):
    python run_all.py                 # real UCI load, 3000 steps (default)
    python run_all.py --steps 5000    # change number of steps
    python run_all.py --synthetic     # skip UCI load, use built-in synthetic profile
    python run_all.py --rebuild       # force-rebuild RegroupedData.csv from the raw file

This script only *calls* the existing tools (MATLAB generator + Python helpers).
It runs nothing hidden -- read it top to bottom; every command is printed as it runs.
"""
import argparse
import glob
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))


def say(msg):
    print(f"\n==> {msg}", flush=True)


def die(msg):
    print(f"\nERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def find_matlab():
    """Locate the MATLAB executable (PATH first, then common install dirs)."""
    exe = shutil.which("matlab")
    if exe:
        return exe
    for base in (r"C:\Program Files\MATLAB", r"C:\Program Files (x86)\MATLAB"):
        hits = sorted(glob.glob(os.path.join(base, "R*", "bin", "matlab.exe")),
                      reverse=True)
        if hits:
            return hits[0]
    return None


def run(cmd, cwd=None):
    """Run a command, echoing it first; return its exit code."""
    printable = cmd if isinstance(cmd, str) else " ".join(cmd)
    print(f"   $ {printable}", flush=True)
    return subprocess.run(cmd, cwd=cwd).returncode


def main():
    ap = argparse.ArgumentParser(
        description="Run the microgrid FDI pipeline end to end.")
    ap.add_argument("--steps", type=int, default=3000)
    ap.add_argument("--warmup", type=int, default=400)
    ap.add_argument("--synthetic", action="store_true",
                    help="use the built-in synthetic load instead of the UCI data")
    ap.add_argument("--rebuild", action="store_true",
                    help="force-rebuild RegroupedData.csv from the raw UCI file")
    args = ap.parse_args()

    py = sys.executable
    matlab = find_matlab()
    if not matlab:
        die("MATLAB not found. Install it or add 'matlab' to your PATH.")

    reg = os.path.join(ROOT, "Python", "Validation",
                       "RegroupedDataset", "RegroupedData.csv")
    raw = os.path.join(ROOT, "Python", "Validation",
                       "RawDataset", "household_power_consumption.txt")

    # ---- Step 1: load input ----
    use_data = False
    if args.synthetic:
        say("Step 1/3: synthetic load selected (--synthetic). Skipping UCI prep.")
    else:
        if args.rebuild or not os.path.exists(reg):
            if os.path.exists(raw):
                say("Step 1/3: building RegroupedData.csv from the raw UCI file...")
                os.makedirs(os.path.dirname(reg), exist_ok=True)
                rc = run([py, "DataPreprocessing.py"],
                         cwd=os.path.join(ROOT, "Python", "Validation"))
                if rc != 0:
                    die("DataPreprocessing.py failed.")
            else:
                say("Step 1/3: no raw UCI file found -> using synthetic load.")
        else:
            say("Step 1/3: using existing RegroupedData.csv (real UCI load).")
        use_data = os.path.exists(reg)

    # ---- Step 2: MATLAB generation ----
    say(f"Step 2/3: generating dataset with MATLAB ({args.steps} steps). "
        f"This takes a few minutes...")
    if use_data:
        cmd = (f"SimulateMicrogridFDI('steps',{args.steps},"
               f"'warmup',{args.warmup},'data','{reg}')")
    else:
        cmd = f"SimulateMicrogridFDI('steps',{args.steps},'warmup',{args.warmup})"
    rc = run([matlab, "-batch", cmd], cwd=os.path.join(ROOT, "MATLAB"))
    if rc != 0:
        die(f"MATLAB generation failed (exit {rc}).")

    # ---- Step 3: figures ----
    say("Step 3/3: generating figures...")
    rc = run([py, os.path.join(ROOT, "Python", "Simulation", "make_figures.py"),
              "--base", os.path.join(ROOT, "MATLAB")])
    if rc != 0:
        die("make_figures.py failed.")

    # ---- done ----
    say("DONE.")
    print("Dataset + figures are in:")
    print("  " + os.path.join(ROOT, "MATLAB", "VectorDataset_PF_corrected"))
    print("  " + os.path.join(ROOT, "MATLAB", "VectorDataset_QV_corrected"))
    print("ML inputs per folder:  features_z.csv (X, 130 cols) + labels.csv (y)")


if __name__ == "__main__":
    main()
