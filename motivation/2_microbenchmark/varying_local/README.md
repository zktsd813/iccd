# Varying Local Memory Sweep

This directory is the stable location for the shared-window 32-thread
microbenchmark sweep that varies the VM fast/local memory size.

## Layout

- `summary_ko.md`: readable Korean result summary.
- `local_mem_sweep.csv`: aggregate data used by the figures.
- `figures/`: aggregate SVG/PDF plots.
- `raw/`: per-local-size raw run directories, including guest results, host logs,
  per-run summaries, and metadata.

## Experiment Shape

- Workload: shared-window BW read microbenchmark.
- Threads: 32.
- Active window: 32G.
- Target operations: 43686414250.
- Local memory values: 8G, 12G, 16G, 20G, 24G, 28G, 32G.
- Slow memory: 64G.
- Policies: migration off and migration on.
- NUMA scan timing and promotion latency knobs: Linux defaults.

For local sizes below 32G, the initial active-window placement is a contiguous
first-touch split: `[0, local_mem)` on node0 and `[local_mem, 32G)` on node1.
The 32G point has no remote split and uses `--placement bind:0`.
