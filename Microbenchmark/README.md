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
- fixed-operation measured runs through `--target-ops`
- small, scriptable command-line interface for repeatable experiments

## Modes

- `bw`: sequential bandwidth-oriented kernels such as `read`, `write`,
  `copy`, and `triad`, with optional `--bw-stride` and `--bw-block`
  traversal shaping
- `pc`: true pointer-chasing over a permutation ring with configurable chain
  count to control exposed MLP. `--pc-chains 1` is a low-MLP dependent-load
  stream; larger chain counts keep each chain dependent but expose independent
  chains to the core.
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
- `--target-ops 1000000000`
- `--phase-boundary-probe LABEL:OFFSET:SIZE`
- `--pause-ns 100000`
- `--placement none|bind:0|interleave:0,1|split:0,1|window-split:0,1|arena-split:0,1`
- `--arena-split-local 32G`
- `--bw-kernel read|write|copy|triad`
- `--bw-stride 1`
- `--bw-block 2M`
- `--hotset-pages 64`
- `--hot-prob-pct 95`
- `--hotset-read-pct 100`
- `--hotset-write-pct 0`
- `--hotset-rmw-pct 0`
- `--hotset-shared-window`
- `--hotset-tail`
- `--hotset-background-pages 1024`
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

By default, each hotset worker receives a private slice and the hot pages are
at the start of that slice. `--hotset-shared-window` makes every worker access
the complete logical window while retaining an independent random sequence.
`--hotset-tail` places the hot pages at the end of the window and treats its
leading pages as the background set. These flags make a single global hot/cold
boundary explicit instead of relying on bandwidth-worker slicing behavior.
In tail mode, `--hotset-background-pages N` restricts background accesses to
the first `N` pages while leaving any gap between that prefix and the tail
hotset untouched. Its default value, zero, preserves the original behavior of
using every non-hot page as background.

```bash
./mbench --mode irregular-index --index-kernel rmw \
  --arena-size 1G --window-size 256M --move-policy random
```

`arena-split` first-touches the leading `--arena-split-local` bytes on the
first node and the rest of the entire arena on the second node. It uses only a
temporary thread memory policy and restores the default policy after prefault;
it does not leave an `mbind` policy on the mapping. The split is independent of
the active window, so a tail window remains remote initially. This placement
requires prefaulting and therefore rejects `--no-prefault`:

```bash
./mbench --mode skewed-hotset --arena-size 64G --window-size 4G \
  --window-offset 60G --placement arena-split:0,1 \
  --arena-split-local 32G --target-ops 1000000000
```

For a phase preset, `--phase-boundary-probe` adds an opt-in NUMA residency
snapshot after each phase 1 worker has stopped and before its paired phase 2
is applied. The option is repeatable and accepts arena-relative byte ranges:

```bash
./mbench --phase-preset sparse64-weighted8g --arena-size 64G \
  --window-size 64G --placement arena-split:0,1 \
  --arena-split-local 24G \
  --phase-boundary-probe local_background:0:24G \
  --phase-boundary-probe remote_hotset:60G:4G
```

Each range samples one page at deterministic 1 MiB intervals. The probe calls
`move_pages` for the current process with `nodes=NULL` and `flags=0`; it only
queries page locations and does not read, fault, or request migration of arena
pages. Each requested range emits one machine-readable stderr record:

```text
phase_boundary_residency boundary_index=1 after_phase_id=1 before_phase_id=2 label=remote_hotset offset_bytes=64424509440 size_bytes=4294967296 stride_bytes=1048576 samples=4096 node0=0 node1=4096 other_nodes=0 errors=0 query_errno=0
```

### MLP ladder / intermediate MLP

Use the `pc` mode to build a controlled MLP ladder without changing the access
model. Each chain still executes a true dependent pointer chase, but multiple
chains create independent misses that the core can overlap.

```bash
# Low MLP: one dependent chain.
./mbench --mode pc --threads 1 --pc-chains 1 \
  --arena-size 4G --window-size 4G --pc-pattern random \
  --ops-per-pass 1000000 --sample-ms 1000 --csv

# Middle MLP: four independent dependent chains on one worker.
./mbench --mode pc --threads 1 --pc-chains 4 \
  --arena-size 4G --window-size 4G --pc-pattern random \
  --ops-per-pass 1000000 --sample-ms 1000 --csv

# Aggregate middle MLP: modest per-core MLP with a few workers.
./mbench --mode pc --threads 4 --pc-chains 2 \
  --arena-size 4G --window-size 4G --pc-pattern random \
  --ops-per-pass 1000000 --sample-ms 1000 --csv
```

The helper script below runs the same idea as a repeatable benchmark and writes
one CSV per chain count:

```bash
Microbenchmark/scripts/mbench-mlp-ladder.sh --profile ladder --build
Microbenchmark/scripts/mbench-mlp-ladder.sh --profile mid
```

## Request Shaping

- `--threads` now fans out internal workers for `bw`, `pc`, `skewed-hotset`,
  and `irregular-index`. `mix` still uses `--pc-threads` and `--bw-threads`.
- `--ops-per-pass` sets per-worker batch size. For `pc`, `skewed-hotset`, and
  `irregular-index`, one op is one logical memory access. For `bw`, one op is
  one vector element processed by the selected kernel.
- `--target-ops` makes a non-phase measured run stop after the aggregate
  worker operation count reaches at least the target. The final summary reports
  elapsed seconds, ns/op, and ops/s for that fixed-operation run.
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
- `scripts/`: smoke runs and example sweeps, including
  `mbench-arena-split-smoke.sh` for validating arena-wide first-touch residency
