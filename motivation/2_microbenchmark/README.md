# 2 Microbenchmark: Fixed-Ops Migration Overhead

This experiment re-runs the current unfriendly microbenchmark as a fixed
operation count workload and attributes the migration-on slowdown with side
metrics.

## Workload

Label:

```text
stream_read_32g_split16_4kstride
```

Command shape inside the guest:

```bash
numactl --cpunodebind=0 /root/mbench \
  --mode bw --bw-kernel read \
  --arena-size 32G --window-size 32G \
  --move-policy fixed \
  --placement window-split:0,1 \
  --window-split-local 16G \
  --bw-stride 512 --bw-block 4K \
  --threads 32 --bw-shared-window --csv --target-ops "${TARGET_OPS}"
```

One operation is one 8-byte `read` touch at the configured 4 KiB stride.

## Run

Build and run through the host harness:

```bash
./motivation/2_microbenchmark/run_host.sh
```

Useful overrides:

```bash
TARGET_OPS=50000000000 ./motivation/2_microbenchmark/run_host.sh
TARGET_SECONDS=180 ./motivation/2_microbenchmark/run_host.sh
SMOKE=1 ./motivation/2_microbenchmark/run_host.sh
BW_SHARED_WINDOW=0 ./motivation/2_microbenchmark/run_host.sh
```

If `TARGET_OPS` is unset, the guest runs a short migration-off calibration and
chooses a fixed target intended to run for `TARGET_SECONDS` seconds under the
off policy. The same target is then used for all measured cases.

Default VM placement is host-CXL:

```text
FAST_MEM=20G, SLOW_MEM=64G
HOST_CPUS=0-31, GUEST_CPUS=32, GUEST_NODE0_CPUS=0-31
FAST_HOST_NODE=0, SLOW_HOST_NODE=2
```

## Local Memory Sweep

The local-memory sweep keeps the hotset at 32G and runs the shared-window
32-thread unfriendly case while changing the VM fast memory size and initial
local placement together:

```bash
./motivation/2_microbenchmark/run_localmem_sweep.sh
```

Defaults:

```text
LOCAL_MEM_VALUES="8G 12G 16G 20G 24G 28G 32G"
FAST_MEM=<local>, WINDOW_SPLIT_LOCAL=<local>
SLOW_MEM=64G
THREADS=32, ARENA_SIZE=32G, WINDOW_SIZE=32G, BW_SHARED_WINDOW=1
CASES="off on"
TARGET_OPS=43686414250
USE_KERNEL_DEFAULT_NUMA_SCAN=1
```

Default output is the stable directory `motivation/2_microbenchmark/varying_local`:

```text
varying_local/summary_ko.md
varying_local/local_mem_sweep.csv
varying_local/figures/
varying_local/raw/
```

When `WINDOW_SPLIT_LOCAL` equals `WINDOW_SIZE` for the 32G point, the guest
harness uses `--placement bind:0` instead of `window-split:0,1` because the
microbenchmark requires a non-empty remote split for `window-split`.

`USE_KERNEL_DEFAULT_NUMA_SCAN=1` prevents the guest harness from writing NUMA
scan period/size debugfs knobs; snapshots still record the runtime values.
Raw per-local-size outputs are kept under `varying_local/raw/local-*G/`.

## Interleave Initial Placement Sweep

The interleave sweep keeps the hotset/window at 32G and changes how much of the
hotset starts in local memory:

```bash
./motivation/2_microbenchmark/run_interleave_sweep.sh
```

Modes:

```text
all_slow:   32G starts on slow node1
half_local: local_mem/2 starts on local node0, the rest starts on slow node1
```

Default output is `motivation/2_microbenchmark/interleave` with raw per-run
results under `interleave/raw/<mode>/local-*G/`. The experiment name does not
mean Linux `MPOL_INTERLEAVE`; placement is first-touch based.

## Cases

- `off`: global NUMA balancing `0`, ftrace disabled.
- `on`: global NUMA balancing `2`, ftrace disabled.
- `on_trace`: global NUMA balancing `2`, ftrace enabled for migration
  attribution.
- `off_trace`: optional, enabled by setting `CASES="off on off_trace on_trace"`.

Headline execution-time figures use trace-disabled `off` and `on` runs. The
trace-enabled case is diagnostic only because ftrace can perturb runtime.

## Outputs

Host results go under:

```text
motivation/2_microbenchmark/results/<experiment-name>/
```

Latest figures are copied/generated under:

```text
motivation/2_microbenchmark/figure/
```

Main outputs:

- `summaries/summary.csv`: fixed-ops elapsed time, ns/op, CPU time, perf,
  vmstat, PSI, and trace event counts.
- `summaries/migration_stages.csv`: ftrace `mm_migrate_stage` totals by stage.
- `summaries/summary.md`: short headline summary.
- `figure/fixed_ops_execution_time.svg`: y-axis is wall-clock seconds to finish
  the same target operation count.
- `figure/migration_overhead_side_metrics.svg`: extra wall time, system CPU
  seconds, PSI stall proxy, and traced migration time as side metrics.
- `figure/migration_activity_timeline.svg`: progress rate and migrated GiB over
  time for the migration-on run.

`system_cpu_s` and traced migration time are CPU/trace durations across kernel
work. They are intentionally not stacked inside the wall-clock bar for the
32-thread workload.
