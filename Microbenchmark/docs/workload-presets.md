# Workload Presets

This note maps the current workloads under `/Serverless/benchmark` to
`Microbenchmark/mbench` presets. The goal is not algorithmic equivalence. The
goal is to preserve the dominant memory-access shape that matters for migration
and locality experiments.

These presets were chosen by reading the workload code, especially:

- `gapbs/src/pr.cc`, `gapbs/src/bc.cc`
- `vmitosis-workloads/gups/gups.c`, `vmitosis-workloads/graph500/omp-csr/omp-csr.c`, `vmitosis-workloads/btree/btree.c`
- `XSBench/openmp-threading/Simulation.c`
- `silo/benchmarks/ycsb.cc`
- `liblinear-multicore-2.47/linear.cpp`
- `NPB3.4.3/NPB3.4-OMP/FT/ft.f90`, `LU/blts.f90`, `SP/sp.f90`

## Baseline Assumptions

The examples below assume the current host-side microbenchmark flow:

```bash
THREADS=32
ARENA=32G
SAMPLE_MS=1000
```

Additional notes:

- `mbench` ignores `--duration` and always runs with a fixed `20s` warmup plus
  `200s` measured phase.
- `--arena-size` should usually match the intended total RSS target.
- `--window-size` should usually reflect the active region or hot working set,
  not necessarily the full RSS.
- The commands below are starting points. If a workload is more or less
  pressure-heavy than the surrogate, first tune `--ops-per-pass` and
  `--pause-ns` before changing the mode.

## Quick Map

| Workload | Closest mode | Main knobs |
| --- | --- | --- |
| `pr` | `irregular-index/gather` | `segmented`, sweep window |
| `bc` | `irregular-index/gather` | `clustered`, sweep window |
| `graph500` | `irregular-index/gather` | `clustered`, sweep window |
| `gups` | `irregular-index/rmw` | `uniform`, random/full-window |
| `btree` | `pc` | `pc-chains=1`, random window |
| `xsbench` | `irregular-index/gather` | `zipf`, fixed window |
| `silo` | `skewed-hotset` | high hot probability, read-mostly |
| `liblinear` | `irregular-index/rmw` | mild `zipf`, fixed window |
| `FT` | `bw/copy` | stride + block, fixed window |
| `LU` | `bw/triad` | small stride, smaller block, fixed window |
| `SP` | `bw/triad` | near-linear stride, medium block, fixed window |

## Workload Presets

### `pr`

Code basis: `gapbs/src/pr.cc` iterates over `g.in_neigh(u)` and gathers
`outgoing_contrib[v]` in pull mode.

Recommended preset:

```bash
./mbench --mode irregular-index --threads "${THREADS}" \
  --index-kernel gather \
  --index-distribution segmented \
  --index-segments 16 \
  --index-segment-span-ops 8192 \
  --arena-size "${ARENA}" --window-size 8G \
  --move-policy sweep --move-step 512M --move-interval-ms 1000 \
  --ops-per-pass 65536 --pause-ns 100000 --sample-ms "${SAMPLE_MS}"
```

Why: `pr` is dominated by repeated irregular gathers over graph neighborhoods,
but it advances through the graph in a phase-like full-graph iteration, so
`segmented` is a better starting point than fully uniform random access.

### `bc`

Code basis: `gapbs/src/bc.cc` performs BFS frontier expansion plus backward
propagation, with irregular neighbor walks and atomic-like update pressure on
`path_counts`.

Recommended preset:

```bash
./mbench --mode irregular-index --threads "${THREADS}" \
  --index-kernel gather \
  --index-distribution clustered \
  --index-cluster-size 8M \
  --index-cluster-span-ops 4096 \
  --arena-size "${ARENA}" --window-size 8G \
  --move-policy sweep --move-step 512M --move-interval-ms 1000 \
  --ops-per-pass 65536 --pause-ns 100000 --sample-ms "${SAMPLE_MS}"
```

Why: `bc` is still graph-irregular, but the frontier structure creates bursts
of neighborhood-local work. `clustered` usually fits that better than fully
uniform indexing.

### `graph500`

Code basis: `vmitosis-workloads/graph500/omp-csr/omp-csr.c` alternates top-down
and bottom-up BFS steps over CSR neighbors, with CAS-style visited-tree
updates.

Recommended preset:

```bash
./mbench --mode irregular-index --threads "${THREADS}" \
  --index-kernel gather \
  --index-distribution clustered \
  --index-cluster-size 16M \
  --index-cluster-span-ops 4096 \
  --arena-size "${ARENA}" --window-size 8G \
  --move-policy sweep --move-step 512M --move-interval-ms 1000 \
  --ops-per-pass 65536 --pause-ns 100000 --sample-ms "${SAMPLE_MS}"
```

Why: the graph walk is irregular, but active frontier regions create more local
bursts than a uniform random stream would.

### `gups`

Code basis: `vmitosis-workloads/gups/gups.c` repeatedly chooses random indices
and performs XOR updates on a large table.

Recommended preset:

```bash
./mbench --mode irregular-index --threads "${THREADS}" \
  --index-kernel rmw \
  --index-distribution uniform \
  --arena-size "${ARENA}" --window-size 32G \
  --move-policy random --move-step 512M --move-interval-ms 1000 \
  --ops-per-pass 65536 --pause-ns 0 --sample-ms "${SAMPLE_MS}"
```

Why: this is the cleanest direct match in the current suite. GUPS is almost
exactly full-window uniform random RMW pressure.

### `btree`

Code basis: `vmitosis-workloads/btree/btree.c` descends internal nodes by key
comparison and pointer following, then performs random lookups.

Recommended preset:

```bash
./mbench --mode pc --threads "${THREADS}" \
  --pc-chains 1 \
  --arena-size "${ARENA}" --window-size 4G \
  --move-policy random --move-step 256M --move-interval-ms 1000 \
  --ops-per-pass 65536 --pause-ns 100000 --sample-ms "${SAMPLE_MS}"
```

Why: the dominant cost is dependent pointer chasing through tree nodes. This
mode does not model the hot root / colder leaves split explicitly, but it gets
the latency-sensitive dependency right.

### `xsbench`

Code basis: `XSBench/openmp-threading/Simulation.c` performs repeated table
lookups, index-grid indirection, and binary-search-driven cross-section gathers.

Recommended preset:

```bash
./mbench --mode irregular-index --threads "${THREADS}" \
  --index-kernel gather \
  --index-distribution zipf \
  --index-zipf-alpha 1.2 \
  --arena-size "${ARENA}" --window-size 8G \
  --move-policy fixed \
  --ops-per-pass 65536 --pause-ns 100000 --sample-ms "${SAMPLE_MS}"
```

Why: XSBench is table-lookup heavy with reuse concentrated in a subset of the
tables rather than flat uniform randomness, so a mild `zipf` skew is the best
single-mode approximation.

### `silo`

Code basis: `silo/benchmarks/ycsb.cc` uses Zipfian key selection and, in this
tree, the default transaction mix is currently `100,0,0,0`, so the workload is
effectively read-only unless the benchmark mix is changed.

Recommended preset for the current repo default:

```bash
./mbench --mode skewed-hotset --threads "${THREADS}" \
  --hotset-pages 65536 --hot-prob-pct 95 \
  --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 \
  --arena-size "${ARENA}" --window-size 4G \
  --move-policy random --move-step 64M --move-interval-ms 1000 \
  --ops-per-pass 65536 --pause-ns 100000 --sample-ms "${SAMPLE_MS}"
```

If you switch back to a more traditional YCSB-A style mix, start with:

```bash
./mbench --mode skewed-hotset --threads "${THREADS}" \
  --hotset-pages 65536 --hot-prob-pct 95 \
  --hotset-read-pct 80 --hotset-write-pct 20 --hotset-rmw-pct 0 \
  --arena-size "${ARENA}" --window-size 4G \
  --move-policy random --move-step 64M --move-interval-ms 1000 \
  --ops-per-pass 65536 --pause-ns 100000 --sample-ms "${SAMPLE_MS}"
```

Why: key popularity is explicitly Zipfian and hotset-driven. The new
read/write/rmw ratio knobs are the right control surface here.

### `liblinear`

Code basis: `liblinear-multicore-2.47/linear.cpp` repeatedly performs sparse
dot products and sparse `axpy` updates over indexed feature vectors.

Recommended preset:

```bash
./mbench --mode irregular-index --threads "${THREADS}" \
  --index-kernel rmw \
  --index-distribution zipf \
  --index-zipf-alpha 1.1 \
  --arena-size "${ARENA}" --window-size 8G \
  --move-policy fixed \
  --ops-per-pass 65536 --pause-ns 100000 --sample-ms "${SAMPLE_MS}"
```

Why: the training loop mixes sparse gathers with weight-vector updates. The
current suite does not have a dedicated sparse-dot kernel, so `rmw` plus a mild
skew is the best compact surrogate.

### `FT`

Code basis: `NPB3.4.3/NPB3.4-OMP/FT/ft.f90` performs repeated FFT stages and
scratch copies over structured arrays.

Recommended preset:

```bash
./mbench --mode bw --threads "${THREADS}" \
  --bw-kernel copy \
  --bw-stride 4 --bw-block 2M \
  --arena-size "${ARENA}" --window-size 16G \
  --move-policy fixed \
  --ops-per-pass 1048576 --pause-ns 100000 --sample-ms "${SAMPLE_MS}"
```

Why: `FT` is regular and bandwidth-oriented, but pure contiguous streaming is
too simple. A modest stride plus a larger block better matches stage-local
structured traversal.

### `LU`

Code basis: `NPB3.4.3/NPB3.4-OMP/LU/blts.f90` reads nearby grid neighbors and
updates structured state in an SSOR solver.

Recommended preset:

```bash
./mbench --mode bw --threads "${THREADS}" \
  --bw-kernel triad \
  --bw-stride 2 --bw-block 512K \
  --arena-size "${ARENA}" --window-size 16G \
  --move-policy fixed \
  --ops-per-pass 524288 --pause-ns 100000 --sample-ms "${SAMPLE_MS}"
```

Why: `LU` is still regular-array traffic, but it is more stencil-like and less
purely streaming than `FT`, so a smaller stride and smaller block is a better
starting point.

### `SP`

Code basis: `NPB3.4.3/NPB3.4-OMP/SP/sp.f90` repeatedly calls `adi` on a
structured grid, and the benchmark documentation emphasizes cache-friendly and
blocked regular access.

Recommended preset:

```bash
./mbench --mode bw --threads "${THREADS}" \
  --bw-kernel triad \
  --bw-stride 1 --bw-block 1M \
  --arena-size "${ARENA}" --window-size 16G \
  --move-policy fixed \
  --ops-per-pass 524288 --pause-ns 100000 --sample-ms "${SAMPLE_MS}"
```

Why: `SP` is the most regular of the solver-like group here. It still benefits
from block shaping, but usually wants less stride distortion than `FT`.

## When To Deviate

- If the real workload has stronger hot/cold skew than the surrogate, increase
  `--hot-prob-pct` or `--index-zipf-alpha`.
- If the real workload looks too bursty, decrease `--index-cluster-span-ops`
  or `--index-segment-span-ops`.
- If the surrogate is too throughput-heavy for a solver workload, lower
  `--ops-per-pass` or increase `--pause-ns` before switching modes.
- If a structured solver still looks too unlike the target workload, the next
  feature to add is a dedicated stencil or structured-neighbor mode rather than
  more `bw` knob tuning.
