# Design

## Runtime Model

The benchmark separates total allocation size from the currently active
logical working-set window.

- `arena_bytes`: total bytes mapped for the benchmark
- `window_bytes`: active working-set bytes touched by the current mode
- `window_offset_bytes`: current logical base of the active window
- `move_policy`: `fixed`, `pingpong`, `sweep`, or `random`
- `move_interval_ms`: how often the window advances
- `move_step_bytes`: logical delta applied at each move

Logical movement changes where the hot window sits inside the arena without
moving physical pages. The common use case is "allocate a large arena, then
shift which subrange is active over time", for example a `1G` arena with a
`256M` window that advances by `256M` or jumps randomly.

Initial NUMA placement is still available through `--placement`, but it is
not required for the core working-set movement model.

## Modes

### `bw`

Bandwidth mode operates on vectors in the current active window. The base
kernel set is:

- `read`
- `write`
- `copy`
- `triad`

`--bw-stride` spaces touches inside each tile and `--bw-block` controls the
tile size for block-interleaved traversal, so the same mode can cover pure
streaming, strided FFT-like walks, and blocked regular access.
Implementations should prefer the best available ISA at runtime while keeping
a scalar fallback for non-linear traversal shapes.
When more than one worker is requested, the active window is partitioned
across workers so each core drives its own slice.

### `pc`

Pointer-chase mode walks a permutation ring built over indexed slots inside
the active window. A single chain exposes latency, and higher chain counts
allow additional MLP while preserving dependent loads within each chain.
When multiple workers are active, each worker gets a disjoint slice and its
own ring inside that slice.

### `mix`

Mixed mode runs `pc` and `bw` thread groups concurrently. This is intentionally
not modeled as a read/write ratio in one loop because the goal is to create
simultaneous latency- and bandwidth-sensitive pressure.

### `skewed-hotset`

Skewed-hotset mode performs page-granular random access with a hot/cold split
inside the active window. A small hot page set is accessed with high
probability, while the rest of the window acts as the cold region. Operation
mix is controlled by read/write/rmw percentages so the same locality model can
cover read-mostly caches and update-heavy KV loops.

### `irregular-index`

Irregular-index mode performs indexed `gather`, `scatter`, or `rmw`
operations over the active window. The access stream is PRNG-driven and now
supports `uniform`, `zipf`, `clustered`, and `segmented` index distributions
so the mode can mimic long-tail hotness, bursty local neighborhoods, or phased
segment-by-segment traversal without requiring external traces.

## Request Shaping

The benchmark now exposes two direct request-shaping controls:

- `ops_per_pass`: per-worker batch size before the next outer-loop iteration
- `pause_ns`: optional sleep inserted after each completed worker batch

This keeps the working-set model intact while making per-core pressure easier
to control.

Mode-specific op semantics:

- `bw`: one op is one vector element processed by the active kernel
- `pc`: one op is one dependent pointer-chase step
- `skewed-hotset`: one op is one random hot/cold access
- `irregular-index`: one op is one indexed gather/scatter/rmw access

## CLI Contract

The implementation targets a single binary, `mbench`, with runtime options:

- `--mode bw|pc|mix|skewed-hotset|irregular-index`
- `--arena-size SIZE`
- `--window-size SIZE`
- `--window-offset SIZE`
- `--move-policy fixed|pingpong|sweep|random`
- `--move-step SIZE`
- `--move-interval-ms N`
- `--duration N`
- `--duration-ms N`
- `--sample-ms N`
- `--threads N`
- `--bw-threads N`
- `--pc-threads N`
- `--bw-kernel read|write|copy|triad`
- `--bw-stride N`
- `--bw-block SIZE`
- `--pc-chains N`
- `--ops-per-pass N`
- `--pause-ns N`
- `--hotset-pages N`
- `--hot-prob-pct 0..100`
- `--hotset-read-pct 0..100`
- `--hotset-write-pct 0..100`
- `--hotset-rmw-pct 0..100`
- `--index-kernel gather|scatter|rmw`
- `--index-distribution uniform|zipf|clustered|segmented`
- `--index-zipf-alpha FLOAT`
- `--index-cluster-size SIZE`
- `--index-cluster-span-ops N`
- `--index-segments N`
- `--index-segment-span-ops N`
- `--placement none|bind:LIST|interleave:LIST|preferred:LIST|split:LIST`
- `--prefault`
- `--no-prefault`
- `--hugepage none|thp|2m|1g`
- `--csv`
- `--quiet`
- `--no-summary`

Additional tuning flags are acceptable as long as the defaults stay small and
the options above remain stable.

## Reporting

Each run should emit:

- periodic stdout samples
- optional CSV samples
- a final summary with configuration, elapsed time, and core counters

## Recommended Profiles

Recommended starting points for paper-style workload classes:

- `graph`: `irregular-index` + `gather`, often with `segmented` or `clustered`
  indices, `4G` window, sweep movement, moderate `ops-per-pass`
- `kv/web/cache`: `skewed-hotset`, smaller hotset, `95%` hot probability,
  read/write/rmw mix, random movement
- `analytics/scan`: `bw` + `read` or `triad`, optionally with stride/block
  shaping, large fixed window, larger `ops-per-pass`
- `loaded latency`: `mix` with separate `pc` and `bw` groups plus optional
  `pause-ns` throttling

## Build Structure

- `src/core/`: config parsing, allocation, placement, timing, affinity,
  summary/report utilities, and main dispatch
- `src/kernels/`: `bw`, `pc`, `mix`, `skewed-hotset`, `irregular-index`
- `include/`: shared structs and function declarations
