# 6-phase mulshift4g/block2m-sparse64 result

- Run: `phase6_block2m_20260507T084711Z`
- Candidate: `phase_mulshift4g_block2m_sparse64` newly added for this run.
- Phase layout: 1/3/5 friendly `mulshift-hotset-4g-fixed`; 2/4/6 unfriendly `sparse-stride-read-64g-block2m`.
- Policies: `off`, `on`, `adaptive_cgroup`. `adaptive_cgroup` uses cgroup balancing 2 for friendly phases and 0 for sparse phases with global NUMA balancing 0.
- Local refault sampling: `NUMA_PROMOTE_SAMPLE_STAT_ENABLED=1`, sample rate 10.

## Aggregate

| policy | kind | phases | mean Mops/s | mean MB/s | promoted GiB | hint faults | local hint faults | sampled refault | refault avg | blocked |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| off | friendly | 3 | 403.08 | 25797.3 | 0.00 | 0.0M | 0.00M | 0.00M | 0.00 us | 0.00M |
| off | unfriendly | 3 | 32.70 | 261.6 | 0.00 | 0.0M | 0.00M | 0.00M | 0.00 us | 0.00M |
| on | friendly | 3 | 2863.22 | 183245.9 | 4.02 | 5.6M | 0.11M | 0.11M | 3.27 us | 0.53M |
| on | unfriendly | 3 | 50.23 | 401.9 | 4.49 | 29.7M | 0.12M | 0.12M | 2.65 us | 0.13M |
| adaptive_cgroup | friendly | 3 | 3647.40 | 233433.3 | 4.08 | 1.2M | 0.11M | 0.11M | 3.07 us | 0.00M |
| adaptive_cgroup | unfriendly | 3 | 42.75 | 342.0 | 0.00 | 0.0M | 0.00M | 0.00M | 0.00 us | 0.00M |

## Phase Detail

| policy | phase | kind | Mops/s | MB/s | promoted GiB | hint faults | local hint | sampled refault | refault avg | blocked | N0 anon end |
|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| off | 1 | friendly | 399.53 | 25570.1 | 0.00 | 0.0M | 0.00M | 0.00M | 0.00 us | 0.00M | 0.00 |
| off | 2 | unfriendly | 32.13 | 257.1 | 0.00 | 0.0M | 0.00M | 0.00M | 0.00 us | 0.00M | 1.45 |
| off | 3 | friendly | 408.47 | 26142.3 | 0.00 | 0.0M | 0.00M | 0.00M | 0.00 us | 0.00M | 1.45 |
| off | 4 | unfriendly | 32.99 | 263.9 | 0.00 | 0.0M | 0.00M | 0.00M | 0.00 us | 0.00M | 1.45 |
| off | 5 | friendly | 401.24 | 25679.5 | 0.00 | 0.0M | 0.00M | 0.00M | 0.00 us | 0.00M | 1.45 |
| off | 6 | unfriendly | 32.99 | 263.9 | 0.00 | 0.0M | 0.00M | 0.00M | 0.00 us | 0.00M | 1.45 |
| on | 1 | friendly | 2486.51 | 159136.7 | 4.00 | 1.2M | 0.10M | 0.10M | 3.13 us | 0.00M | 4.00 |
| on | 2 | unfriendly | 50.04 | 400.3 | 4.49 | 13.7M | 0.12M | 0.12M | 2.65 us | 0.13M | 15.60 |
| on | 3 | friendly | 3031.92 | 194042.9 | 0.02 | 2.2M | 0.00M | 0.00M | 33.33 us | 0.27M | 15.62 |
| on | 4 | unfriendly | 50.62 | 404.9 | 0.00 | 5.2M | 0.00M | 0.00M | 0.00 us | 0.00M | 15.62 |
| on | 5 | friendly | 3071.22 | 196558.0 | 0.00 | 2.2M | 0.00M | 0.00M | 0.00 us | 0.27M | 15.62 |
| on | 6 | unfriendly | 50.05 | 400.4 | 0.00 | 10.8M | 0.00M | 0.00M | 0.00 us | 0.00M | 15.62 |
| adaptive_cgroup | 1 | friendly | 2337.45 | 149596.9 | 4.08 | 1.2M | 0.11M | 0.11M | 3.07 us | 0.00M | 4.08 |
| adaptive_cgroup | 2 | unfriendly | 42.37 | 338.9 | 0.00 | 0.0M | 0.00M | 0.00M | 0.00 us | 0.00M | 6.68 |
| adaptive_cgroup | 3 | friendly | 4299.54 | 275170.5 | 0.00 | 0.0M | 0.00M | 0.00M | 0.00 us | 0.00M | 6.68 |
| adaptive_cgroup | 4 | unfriendly | 42.08 | 336.6 | 0.00 | 0.0M | 0.00M | 0.00M | 0.00 us | 0.00M | 7.17 |
| adaptive_cgroup | 5 | friendly | 4305.19 | 275532.5 | 0.00 | 0.0M | 0.00M | 0.00M | 0.00 us | 0.00M | 7.17 |
| adaptive_cgroup | 6 | unfriendly | 43.79 | 350.3 | 0.00 | 0.0M | 0.00M | 0.00M | 0.00 us | 0.00M | 8.97 |

## Adaptive Controller

```text
2026-05-07T09:01:36Z phase=1 kind=friendly policy=adaptive_cgroup global=0 cgroup_node_balancing=2
2026-05-07T09:02:36Z phase=2 kind=sparse policy=adaptive_cgroup global=0 cgroup_node_balancing=0
2026-05-07T09:03:36Z phase=3 kind=friendly policy=adaptive_cgroup global=0 cgroup_node_balancing=2
2026-05-07T09:04:36Z phase=4 kind=sparse policy=adaptive_cgroup global=0 cgroup_node_balancing=0
2026-05-07T09:05:37Z phase=5 kind=friendly policy=adaptive_cgroup global=0 cgroup_node_balancing=2
2026-05-07T09:06:37Z phase=6 kind=sparse policy=adaptive_cgroup global=0 cgroup_node_balancing=0
```

## Notes

- Friendly 평균 Mops/s: off 403.08, on 2863.22, adaptive 3647.40.
- Unfriendly 평균 Mops/s: off 32.70, on 50.23, adaptive 42.75.
- Adaptive sparse phases show nearly zero sampled refault/promotion because cgroup balancing is disabled during phases 2/4/6.
- All policies returned 0; no timeout/failure was observed.
