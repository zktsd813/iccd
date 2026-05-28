# Single Workload Live Placement Plan

Date: 2026-05-22

Scope: single-tenant live placement sampling. Multi-tenant pairs are excluded.

## Workload List

Use these as the single-workload expansion set from
`/Serverless/Migration-friendly/scripts/bench`.

| workload | legacy CLI in Migration-friendly scripts | live-placement CLI policy |
| --- | --- | --- |
| `pr` | `gapbs/pr -g28 -i1000 -t1e-4 -n20` | Use prebuilt graph: `/root/pr -f /root/gapbs_graphs/kron_g28.sg -i20 -t1e-4 -n ${TRIALS}` |
| `bc` | `gapbs/bc -g28` | Use prebuilt graph: `/root/bc -f /root/gapbs_graphs/kron_g28.sg -i1 -n ${TRIALS}` |
| `liblinear` | `liblinear-multicore-2.47/train -s 6 -m 32 datasets/kdd12` | Same CLI, with path resolved in guest |
| `FT` | `NPB3.4.3/NPB3.4-OMP/bin/ft.H.x` | Same CLI |
| `LU` | `NPB3.4.3/NPB3.4-OMP/bin/lu.H.x` | Same CLI |
| `SP` | `NPB3.4.3/NPB3.4-OMP/bin/sp.H.x` | Same CLI |
| `gups` | `vmitosis-workloads/bin/bench_gups_mt` | Same CLI |
| `graph500` | `vmitosis-workloads/bin/bench_graph500_mt -s 28` | Same CLI |
| `btree` | `vmitosis-workloads/bin/bench_btree_mt` | Same CLI |
| `xsbench` | `XSBench/openmp-threading/XSBench -t 20 -g 130000 -p 30000000` | Prefer `-t ${OMP_THREADS}` if runtime is acceptable |
| `silo` | `silo/out-perf.masstree/benchmarks/dbtest --verbose --num-threads 32 --bench ycsb --scale-factor 550000 --ops-per-worker=200000000` | Use `--num-threads ${OMP_THREADS}` |

Optional, keep out of the first sweep:

| workload | reason |
| --- | --- |
| `redis`, `memcached` YCSB | Server/client two-process workflow. Not part of this single-process live placement sweep. |

## Experiment Shape

Default first sweep:

```text
WORKLOADS="pr bc FT LU SP gups graph500 btree xsbench silo"
CAPS="8g:2097152 16g:4194304"
policy=off
global numa_balancing=0
cgroup node_balancing=0
cgroup kswapd_demotion_enabled=0
cgroup node_capacity=<cap>
sample interval=1s
```

The result is intended to answer the same question as the PR/BC diagnostics:

- Does node0 capacity actually limit live placement?
- Which workload objects land in local memory by first-touch before migration?
- Is runtime dominated by local hot state, remote streaming state, or allocation-order artifacts?

PR/BC must use `-f /root/gapbs_graphs/kron_g28.sg`, not `-g28`, so graph
generation/build time and placement do not contaminate measured trials.

`liblinear` is part of the single-workload list, but stage it separately because
the `kdd12` input is about 21 GiB.
