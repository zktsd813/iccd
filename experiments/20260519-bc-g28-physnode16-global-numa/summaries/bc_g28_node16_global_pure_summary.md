# BC g28 physical node0=16G global NUMA run

## Setup

- Kernel: current VM kernel (`6.18.0modified`, KVM).
- VM topology: node0 = 16G, CPUs 0-31; node1 = 80G.
- No cgroup capacity, cgroup migration knobs, or userspace controller were used.
- Workload: `/root/bc -f /root/gapbs_graphs/kron_g28.sg -i1 -n8`.
- Graph build was excluded; GAPBS loaded the serialized graph with `-f`.
- Before each case: `sync; echo 3 > /proc/sys/vm/drop_caches`.
- Runtime state: `mglru=0x0007`, `scan_size_mb=256`, `scan_period_min_ms=1000`.

## Cases

| case | global NUMA | demotion | demotion target | Read Time (s) | Avg Trial Time (s) | elapsed (s) |
|---|---:|---|---|---:|---:|---:|
| off | 0 | false | `0 -1; 1 -1` | 27.95439 | 46.42319 | 401 |
| global2 | 2 | true | `0 1; 1 -1` | 23.68597 | 44.43432 | 380 |

## Trial times

| case | t1 | t2 | t3 | t4 | t5 | t6 | t7 | t8 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| off | 53.10129 | 47.48541 | 40.59316 | 51.56669 | 47.60861 | 46.55481 | 39.41550 | 45.06008 |
| global2 | 53.18716 | 46.39577 | 39.62242 | 47.20928 | 44.37167 | 45.33825 | 37.19298 | 42.15707 |

## VM stat deltas

| case | hint faults | PTE updates | NUMA migrated | promote success | demote kswapd | migrate success |
|---|---:|---:|---:|---:|---:|---:|
| off | 0 | 0 | 0 | 0 | 0 | 0 |
| global2 | 0 | 0 | 0 | 0 | 2,376,392 | 2,376,392 |

## Notes

- `global2` was faster than pure off here: average trial time improved from 46.42319s to 44.43432s, about 4.3%.
- The counter path shows no NUMA hint-fault scan in either case. The observed migration in `global2` came through reclaim/kswapd demotion (`pgdemote_kswapd`), not `numa_hint_faults`/`numa_pte_updates`.
- An earlier diagnostic run accidentally left global demotion enabled in both `0x0` and `0x2`; that run is preserved under `20260519T100627Z-bcg28-node16-global`, but this summary uses the corrected pure-off run under `20260519T102223Z-bcg28-node16-global-pure-kvm`.
