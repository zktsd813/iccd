# Microbench package

Source run: `/Serverless/iccd-git/submission_socc/final_experiments/runs/20260714T193541Z-eval1-microbench-gups64-v3-v4abi`

Policies: on, off, tpp, ours

Workload model: gups-based two-phase microbenchmark, 64 GiB RSS, 32 GiB local arena split / 32 GiB remote split. The VM exposes 34 GiB fast memory to leave guest OS headroom while the benchmark arena split is fixed at 32/32 GiB.

Top-level CSV files:

- `summary.csv`: elapsed time plus total and phase-wise migration counters.
- `phase_summary.csv`: one row per policy and phase.
- `controller_events.csv`: controller transitions when `ours` is included.
- `throughput_timeseries_compare_on_tpp_ours.csv`: 1 s throughput samples and 5 s moving average for the RSS 64 GiB / hotset 48 GiB case study.
- `throughput_summary_on_tpp_ours.csv`: aggregate throughput summary for the same on/tpp/ours comparison.

Figures are in `figure/`, including `throughput_timeseries_compare_on_tpp_ours.{png,pdf,svg}`. Raw VM results and logs are under `raw/`; run scripts and the microbenchmark source/binary are under `scripts/`.
