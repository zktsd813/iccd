# Microbenchmark

`Microbenchmark/` contains a standalone C workload generator for stressing
memory systems with a configurable active working set, movable hot windows,
and multiple memory-pressure modes.

## Goals

- runtime-configurable working-set size
- movable logical hot window inside a larger arena
- optional initial NUMA placement
- separate `bw`, `pc`, `mix`, `skewed-hotset`, and `irregular-index` execution modes
- direct request shaping with per-pass operation count and optional inter-pass pause
- small, scriptable command-line interface for repeatable experiments

## Modes

- `bw`: sequential bandwidth-oriented kernels such as `read`, `write`,
  `copy`, and `triad`, with optional `--bw-stride` and `--bw-block`
  traversal shaping
- `pc`: true pointer-chasing over a permutation ring with configurable chain
  count to control exposed MLP
- `mix`: concurrent `bw` and `pc` thread groups in one process
- `skewed-hotset`: page-granular hot/cold random access with configurable hot
  set size, hot-access probability, and read/write/rmw ratio
- `irregular-index`: irregular indexed `gather`, `scatter`, or `rmw`
  operations over the active window, with `uniform`, `zipf`, `clustered`, or
  `segmented` index streams

## Memory Model

- `arena`: total mapped address range owned by the benchmark
- `window`: active subrange within the arena used by the current workload
- `window offset`: current logical location of the active window
- `move policy`: how the active window hops over time

The main requirement is logical window movement inside one preallocated arena.
For example, allocate `1G`, use the first `256M` as the active window, then
later switch to the next or a random `256M` region without any physical page
migration.

## Build

```bash
make
```

The project uses `gcc`, `pthread`, and `libnuma`.

## Common Flags

- `--mode bw|pc|mix|skewed-hotset|irregular-index`
- `--arena-size 32M`
- `--window-size 4M`
- `--window-offset 0`
- `--move-policy fixed|pingpong|sweep|random`
- `--move-step 2M`
- `--duration 1`
- `--sample-ms 250`
- `--threads 1`
- `--pc-threads 1`
- `--bw-threads 1`
- `--pc-chains 1`
- `--ops-per-pass 65536`
- `--pause-ns 100000`
- `--placement none|bind:0|interleave:0,1|split:0,1`
- `--bw-kernel read|write|copy|triad`
- `--bw-stride 1`
- `--bw-block 2M`
- `--hotset-pages 64`
- `--hot-prob-pct 95`
- `--hotset-read-pct 100`
- `--hotset-write-pct 0`
- `--hotset-rmw-pct 0`
- `--index-kernel gather|scatter|rmw`
- `--index-distribution uniform|zipf|clustered|segmented`
- `--index-zipf-alpha 1.2`
- `--index-cluster-size 2M`
- `--index-cluster-span-ops 4096`
- `--index-segments 8`
- `--index-segment-span-ops 4096`

Example:

```bash
./mbench --mode bw --arena-size 1G --window-size 256M \
  --move-policy sweep --move-step 256M --move-interval-ms 1000
```

```bash
./mbench --mode skewed-hotset --arena-size 1G --window-size 256M \
  --hotset-pages 1024 --hot-prob-pct 95 --move-policy sweep
```

```bash
./mbench --mode irregular-index --index-kernel rmw \
  --arena-size 1G --window-size 256M --move-policy random
```

## Request Shaping

- `--threads` now fans out internal workers for `bw`, `pc`, `skewed-hotset`,
  and `irregular-index`. `mix` still uses `--pc-threads` and `--bw-threads`.
- `--ops-per-pass` sets per-worker batch size. For `pc`, `skewed-hotset`, and
  `irregular-index`, one op is one logical memory access. For `bw`, one op is
  one vector element processed by the selected kernel.
- `--pause-ns` sleeps after each worker batch and is the simplest way to lower
  per-core request pressure without changing the working-set model.
- `--bw-stride` and `--bw-block` reshape the regular walk so `bw` can model
  strided FFT-like traffic or block-interleaved solver traffic.
- `--hotset-read-pct`, `--hotset-write-pct`, and `--hotset-rmw-pct` let
  `skewed-hotset` approximate read-mostly caches, write-heavy KV paths, and
  mixed get/update loops.
- `--index-distribution` adds non-uniform locality for `irregular-index`:
  `zipf` for long-tail hotness, `clustered` for bursty local neighborhoods,
  and `segmented` for phased region-by-region traversal.

Example:

```bash
./mbench --mode irregular-index --threads 4 --index-kernel gather \
  --index-distribution zipf --index-zipf-alpha 1.3 \
  --arena-size 1G --window-size 256M \
  --ops-per-pass 65536 --pause-ns 100000
```

```bash
./mbench --mode bw --threads 4 --bw-kernel read \
  --bw-stride 8 --bw-block 512K \
  --arena-size 1G --window-size 256M \
  --ops-per-pass 65536 --pause-ns 100000
```

```bash
./mbench --mode skewed-hotset --threads 4 \
  --hotset-pages 16384 --hot-prob-pct 95 \
  --hotset-read-pct 80 --hotset-write-pct 10 --hotset-rmw-pct 10 \
  --arena-size 1G --window-size 256M \
  --ops-per-pass 65536 --pause-ns 100000
```

## Recommended Profiles

These are starting points that roughly match common workload families from
recent tiered-memory and CXL papers.

For workload-by-workload presets derived from the actual benchmark code under
`/Serverless/benchmark`, see `docs/workload-presets.md`.

- `graph / pagerank / bc / sssp`

```bash
./mbench --mode irregular-index --threads 4 --index-kernel gather \
  --index-distribution segmented --index-segments 16 --index-segment-span-ops 8192 \
  --arena-size 16G --window-size 4G \
  --move-policy sweep --move-step 512M --move-interval-ms 1000 \
  --ops-per-pass 65536 --pause-ns 100000 --duration 10 --sample-ms 1000
```

- `kv / web / cache / redis-like`

```bash
./mbench --mode skewed-hotset --threads 4 \
  --arena-size 16G --window-size 1G \
  --hotset-pages 16384 --hot-prob-pct 95 \
  --hotset-read-pct 80 --hotset-write-pct 10 --hotset-rmw-pct 10 \
  --move-policy random --move-step 64M --move-interval-ms 1000 \
  --ops-per-pass 65536 --pause-ns 100000 --duration 10 --sample-ms 1000
```

- `analytics / scan / data warehouse`

```bash
./mbench --mode bw --threads 4 --bw-kernel read \
  --bw-stride 4 --bw-block 1M \
  --arena-size 16G --window-size 8G \
  --move-policy fixed \
  --ops-per-pass 1048576 --pause-ns 100000 --duration 10 --sample-ms 1000
```

- `loaded-latency / contention`

```bash
./mbench --mode mix --pc-threads 2 --bw-threads 2 --pc-chains 1 \
  --bw-kernel read --arena-size 16G --window-size 4G \
  --ops-per-pass 65536 --pause-ns 100000 --duration 10 --sample-ms 1000
```

## Output

The binary prints periodic samples to stdout and can also emit CSV. Each run
ends with a compact summary that includes the effective configuration and the
main throughput or pointer-chase rate counters.

## Files

- `docs/design.md`: runtime model and CLI contract
- `docs/workload-presets.md`: workload-specific `mbench` presets derived from
  the benchmark implementations under `/Serverless/benchmark`
- `src/core/`: config, allocation, placement, timing, and reporting
- `src/kernels/`: bandwidth, pointer-chase, mixed-mode, skewed-hotset, and
  irregular-index kernels
- `scripts/`: smoke runs and example sweeps
