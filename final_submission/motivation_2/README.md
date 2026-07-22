# Microbench package

Source run: `/Serverless/iccd-git/submission_socc/final_experiments/runs/20260714T193541Z-eval1-microbench-gups64-v3-v4abi`

Policies: on, off, tpp

Workload model: gups-based two-phase microbenchmark, 64 GiB RSS, 32 GiB local arena split / 32 GiB remote split. The VM exposes 34 GiB fast memory to leave guest OS headroom while the benchmark arena split is fixed at 32/32 GiB.

Top-level CSV files:

- `summary.csv`: elapsed time plus total and phase-wise migration counters.
- `phase_summary.csv`: one row per policy and phase.
- `controller_events.csv`: controller transitions when `ours` is included.

Figures are in `figure/`. Raw VM results and logs are under `raw/`; run scripts and the microbenchmark source/binary are under `scripts/`.
