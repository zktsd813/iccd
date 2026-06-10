# Controller Microbenchmark Runners

This directory contains host-side wrappers for the two controller
microbenchmarks used in the motivation experiments.

## Scripts

- `run_skewed_microbenchmark.sh`: RSS 32G, hotset 16G, local memory 24G,
  initial hotset placement 8G local + 8G slow, `skewed-hotset` random-page
  reads, target ops `87372828500`.
- `run_hot32_microbenchmark.sh`: RSS/hotset 32G, local memory 16G, initial
  placement 16G local + 16G slow, 4KB stride shared-window read, target ops
  `43686414250`.

Both scripts run `design/fault_bucket_controller/run_guest.sh` inside the VM,
copy back the controller CSV and fault-latency windows, and regenerate the
controller and histogram figures.

## Usage

```bash
motivation/microbenchmark/run_skewed_microbenchmark.sh
motivation/microbenchmark/run_hot32_microbenchmark.sh
```

Useful overrides:

```bash
RUN_ID=test WINDOW_SEC=5 LOCAL_RATE=5 REMOTE_RATE=5 \
  motivation/microbenchmark/run_hot32_microbenchmark.sh
```

Results are stored under `motivation/microbenchmark/results/<EXP_NAME>`.
Figure copies are also written to `motivation/microbenchmark/figure`.
