# BC g28 node0=16G root-cgroup global2 run

## Setup

- VM topology: node0 = 16G, node1 = 80G, CPUs 0-31 on node0.
- Workload shell was moved to root cgroup before running BC.
- Confirmed cgroup: `0::/`.
- Policy: `/proc/sys/kernel/numa_balancing=2`.
- Demotion: `demotion_enabled=true`, `demotion_target=0 1; 1 -1`.
- Workload: `/root/bc -f /root/gapbs_graphs/kron_g28.sg -i1 -n8`.
- Before run: `sync; echo 3 > /proc/sys/vm/drop_caches`.
- Runtime state: `mglru=0x0007`, `scan_size_mb=256`, `scan_period_min_ms=1000`.

## Result

| case | Read Time (s) | Avg Trial Time (s) | elapsed (s) |
|---|---:|---:|---:|
| global2_rootcg | 30.93495 | 55.13737 | 476 |

## Trial times

| t1 | t2 | t3 | t4 | t5 | t6 | t7 | t8 |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 53.06987 | 45.09279 | 44.78287 | 65.22373 | 58.72298 | 60.07170 | 47.73687 | 66.39816 |

## VM stat deltas

| counter | delta |
|---|---:|
| `numa_hint_faults` | 30,669,498 |
| `numa_pte_updates` | 30,669,464 |
| `numa_pages_migrated` | 2,625,006 |
| `pgpromote_success` | 2,625,006 |
| `pgpromote_candidate` | 3,378,499 |
| `pgdemote_kswapd` | 5,593,940 |
| `pgmigrate_success` | 8,959,207 |
| `pgmigrate_fail` | 240 |

## Interpretation

This confirms the previous `pgpromote_success=0` result was not a real global-tiering behavior. Once the workload ran from root cgroup, the patched task policy path used the global sysctl and NUMA hint scanning occurred.

Compared with the previous non-root global2 run, this root-cgroup run enabled real hint-fault based promotion but was slower. The likely reason is that BC now pays the full hint-fault scan and migration cost on top of reclaim demotion.
