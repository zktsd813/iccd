# PR Allocation Lifetime And Cross-Workload Comparison

Date: 2026-07-11

## Conclusion

PR does allocate and release large memory at every trial boundary, but it does
not continuously replace its whole working set.

- The generated graph remains resident across all eight trials.
- Each PR trial allocates two 2 GiB float arrays, uses them for up to 20 PR
  iterations, and releases them at the trial boundary.
- The much larger approximately 70 GiB resident drop happens once during GAPBS
  graph construction. It is builder cleanup, not PR trial churn.
- At the controller windows where local occupancy `L` is only 4-5 GiB, total
  process residency `L + R` remains approximately 71.29 GiB. Those windows
  show remote-biased placement, not application deallocation.
- BC repeats more large allocation than PR. Therefore repeated allocation by
  itself cannot explain a PR-only controller problem.

## PR Memory Lifetime

The evaluated command is:

```text
gapbs/pr -g 29 -i 20 -t 1e-4 -n 8
```

The generated graph has 536,870,911 vertices and 8,493,563,827 undirected
edges. Its final CSR footprint is approximately:

```text
vertex index:       (N + 1) * 8 bytes       =  4.000 GiB
neighbor IDs:       (2 * E) * 4 bytes       = 63.282 GiB
final graph:                                  67.282 GiB
```

`PageRankPullGS()` creates the following arrays on every call:

```text
scores[N]:                 float             = 2.000 GiB
outgoing_contrib[N]:       float             = 2.000 GiB
trial-local peak:                              4.000 GiB
```

Both arrays are fully written. `outgoing_contrib` is destroyed when
`PageRankPullGS()` returns. `scores` is moved into the trial's `result` and is
destroyed at the end of the `BenchmarkKernel()` loop iteration. `pvector`
implements this storage with `new[]` and `delete[]`.

Consequently, PR has a persistent approximately 67.28 GiB graph plus a 4 GiB
trial workspace. The workspace allocation/release sequence occurs eight times,
once per trial, rather than once per PageRank iteration.

Relevant source locations are:

```text
/Serverless/benchmark/gapbs/src/pr.cc:34-60
/Serverless/benchmark/gapbs/src/benchmark.h:97-123
/Serverless/benchmark/gapbs/src/pvector.h:29-35,72-80
```

## One-Time GAPBS Builder Cleanup

PR and BC both use the same generated-graph builder. The builder temporarily
holds an edge list and intermediate CSR data. It explicitly scopes the edge
list so that it is destroyed early, then constructs a squished graph. This
causes the one-time setup peak and drop seen in both workloads.

An important timing detail is that GAPBS prints `Build Time` inside
`MakeGraphFromEL()`. Edge-list destruction and `SquishGraph()` execute after
that timer is printed. Therefore:

```text
Generate Time + printed Build Time != exact first-trial start
```

The completed sweep records the following largest adjacent-sample drops:

| Workload | Local 16 | Local 32 | Local 48 |
| --- | ---: | ---: | ---: |
| PR | -70.000 GiB at 438 s | -70.000 GiB at 394 s | -70.000 GiB at 366 s |
| BC | -70.000 GiB at 442 s | -69.996 GiB at 399 s | -70.000 GiB at 326 s |

This common approximately 70 GiB drop is not a PR-specific phase behavior.

The builder order also explains the remote-biased surviving graph. The final
squished graph is allocated while older builder data occupies much of the
local tier. Releasing the old data creates local free capacity, but does not
automatically relocate the surviving graph into it. Page-identity tracing was
not enabled, so this page-level explanation is an inference from the source
order and placement trace. The constant total residency below is direct
evidence that low `L` is placement, not deallocation.

## Low Local Occupancy Is Not Low Total Residency

The PR START windows that motivated this audit have nearly constant total
residency across the low-local and refill observations:

| Local configuration | Low-local observation | Following refill observation |
| ---: | ---: | ---: |
| 16 GiB | `4.02 + 67.27 = 71.29 GiB` | `14.63 + 56.65 = 71.28 GiB` |
| 32 GiB | `5.15 + 66.14 = 71.29 GiB` | `22.73 + 48.56 = 71.29 GiB` |
| 48 GiB | `5.17 + 66.12 = 71.29 GiB` | `22.99 + 48.30 = 71.29 GiB` |

The first term is local residency and the second term is remote residency.
The local increase is matched by a remote decrease. It is migration and
placement recovery, not a new approximately 66 GiB application allocation.

There is also a useful numerical match: PR's low local occupancy is close to
its 4 GiB trial workspace, while its approximately 67.28 GiB persistent CSR is
mostly remote. BC's low-placement observations similarly retain roughly
11-12 GiB locally, close to BC's 11.98 GiB simultaneously live trial
workspace. This suggests that freshly first-touched scratch buffers dominate
`L` while the persistent graph remains remote. Page identities were not
recorded, so this is a strongly supported interpretation rather than direct
object-to-NUMA-node proof. Either way, it shows why instantaneous local
residency is not a stable proxy for physical local-tier capacity.

## Cross-Workload Source Comparison

| Workload | Large-memory lifetime in the evaluated run |
| --- | --- |
| PR | Keeps the 67.28 GiB graph; allocates and releases a 4 GiB workspace in each of eight trials. |
| BC | Uses the same persistent graph and eight-trial loop. Each trial has approximately 11.98 GiB of simultaneously live large workspace; approximately 13.98 GiB is cumulatively allocated because `depths` and `deltas` occur sequentially. |
| GUPS | Allocates and initializes one 64 GiB table, updates it in place, and deliberately does not free it before exit. |
| BTree | Allocates the payloads and tree during build. Node splits allocate and free small temporary arrays, but the measured lookup loop performs no bulk heap allocation. |
| Graph500 | Allocates the edge list, graph, and BFS buffers in stages and reuses them. It frees a 1 GiB `has_adj` array once before BFS and a 4 GiB validation buffer once after validation; there is no repeated per-BFS bulk allocation in this one-BFS run. |
| Silo | Loads an 800-million-record table once. The measured workload is 100% reads. Each worker constructs and destroys transaction objects in a preallocated buffer and resets a preallocated string arena; it does not allocate and free database records per transaction. |

BC is the strongest counterexample. Its simultaneously live trial workspace
contains approximately:

```text
scores                 2.000 GiB
path_counts            4.000 GiB
successor bitmap       1.978 GiB
sliding queue          2.000 GiB
max(depths, deltas)    2.000 GiB
total                 11.978 GiB
```

`depths` is destroyed when `PBFS()` returns before `deltas` is constructed,
so they do not overlap as active allocations. Both are nevertheless allocated
once in each BC trial.

## Resident Trace Comparison

The table uses `N0_GiB + N1_GiB` from every completed controller run. The late
median is the median of the latter half of nonempty samples. It is a compact
description of the trace, not a phase marker.

| Workload | Setup peak across 16/32/48 | Late median across 16/32/48 | Trace shape |
| --- | ---: | ---: | --- |
| PR | 138.033 GiB | 71.315 GiB | One builder drop, then a sampled 4 GiB trial-boundary sawtooth. |
| BC | 138.029-138.033 GiB | 78.059-78.098 GiB | Same builder drop and larger repeated trial workspace. |
| GUPS | 64.030 GiB | 64.030 GiB | Allocate once and remain flat. |
| BTree | 65.914 GiB | 65.914 GiB | Build once and remain flat during lookup. |
| Graph500 | 110.575-110.595 GiB | 104.524 GiB | Staged setup and one-off validation allocation, not repeated churn. |
| Silo | 115.714-115.715 GiB | 115.714 GiB | Load once and remain flat during read transactions. |

Silo's own output confirms that `USERTABLE` remains at 800,000,000 records,
with `+0 records` and `logical memory delta: 0 MB` during the transaction
region. Its reported physical memory delta is approximately 300 MB, which is
small allocator/runtime growth rather than bulk database replacement.

## Interpretation For The Controller

PR's 4 GiB trial-boundary allocation can perturb NUMA placement and can make
short-lived resident changes. A nominal 5-second RSS sampler also misses some
of the short free-to-next-allocation gaps, so source lifetime is more reliable
than the count of visible RSS steps.

It does not, however, explain the persistent low-`L` START condition:

1. The low-`L` observations keep approximately 71.29 GiB total residency.
2. BC performs more repeated allocation but does not reproduce the same
   PR-specific controller outcome.
3. The relevant controller risk is interpreting current local placement as
   required capacity and repeatedly acting on an access-conditioned fault CDF,
   not failing to notice that PR released its whole working set.

## Data Sources

```text
motivation/3_realworld/VM/results/20260711T-inverse-capacity-baseline-nosilo-local16-32-48
motivation/3_realworld/VM/results/20260711T-inverse-capacity-silo-local16-32-48
```

Primary source locations used for the cross-workload audit are:

```text
GAPBS builder:  /Serverless/benchmark/gapbs/src/builder.h:317-364
BC:             /Serverless/benchmark/gapbs/src/bc.cc:51-149
GUPS:           /Serverless/benchmark/vmitosis-workloads/gups/gups.c:88-155
BTree:          /Serverless/benchmark/vmitosis-workloads/btree/btree.c:789-840,1535-1622
Graph500:       /Serverless/benchmark/vmitosis-workloads/graph500/graph500.c:120-250
Silo YCSB:      /Serverless/benchmark/silo/benchmarks/ycsb.cc:35-201
Silo txn reuse: /Serverless/benchmark/silo/benchmarks/ndb_wrapper_impl.h:164-228
Silo arena:     /Serverless/benchmark/silo/str_arena.h:17-34,100-123
```
