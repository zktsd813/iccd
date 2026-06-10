# Interleave Initial Hotset Placement Sweep

This directory is the stable location for the experiment that varies the amount
of the 32G active hotset/window initially placed in local memory.

The directory name follows the experiment discussion, but the workload does not
use Linux `MPOL_INTERLEAVE`. Placement is controlled by first-touch policy.

## Layout

- `summary_ko.md`: readable Korean result summary.
- `interleave_sweep.csv`: aggregate data used by the figures.
- `figures/`: aggregate SVG/PDF plots.
- `raw/`: per-mode and per-local-size raw run directories.

## Experiment Shape

- Workload: shared-window BW read microbenchmark.
- Threads: 32.
- Active window: 32G.
- Target operations: 43686414250.
- Local memory values: 8G, 12G, 16G, 20G, 24G, 28G, 32G.
- Slow memory: 64G.
- Policies: migration off and migration on.
- NUMA scan timing and promotion latency knobs: Linux defaults.

## Initial Placement Modes

- `all_slow`: `[0, 32G)` is first-touched on node1 slow memory using
  `--hotset-pages <window_pages> --hotset-prefault-node 1`, then the thread
  memory policy is reset.
- `half_local`: `[0, local_mem/2)` is first-touched on node0 local memory and
  `[local_mem/2, 32G)` is first-touched on node1 slow memory using
  `--placement window-split:0,1 --window-split-local <local_mem/2>`.

Run:

```bash
./motivation/2_microbenchmark/run_interleave_sweep.sh
```
