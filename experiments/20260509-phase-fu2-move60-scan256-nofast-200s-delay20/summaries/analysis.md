# Phase FU2 Delay20 Result

Policy `oracle_cgroup_global0_delay20` keeps cgroup NUMA balancing on for the first 20s of phase 2, then turns it off.

## Controller

```text
2026-05-09T17:24:46Z phase=1 kind=friendly policy=oracle_cgroup_global0_delay20 global=0 cgroup_node_balancing=2
2026-05-09T17:28:07Z phase=2 kind=sparse policy=oracle_cgroup_global0_delay20 global=0 cgroup_node_balancing=2
2026-05-09T17:28:27Z phase=2 kind=sparse policy=oracle_cgroup_global0_delay20 action=delayed_off delay_sec=20 global=0 cgroup_node_balancing=0
```

## Setup

- `kernel=Linux kernel 6.18.0modified #163 SMP PREEMPT_DYNAMIC Sat May  9 12:53:28 UTC 2026 x86_64 x86_64 x86_64 GNU/Linux`
- `lru_gen_enabled=0x0007`
- `numa_scan_size_mb=256`
- `effective_numa_scan_size_mb=256`
- `numa_scan_period_min_ms=1000`
- `effective_numa_scan_period_min_ms=1000`
- `numa_fast_scan=0`
- `phase_ms=200000`
- `phase_repeat=1`
- `phase_sparse_off_delay_sec=20`
- Candidate: `phase_move60s4g_remote_split32_stream4k_localft`
- Compared against previous same-setup run: `/Serverless/iccd/experiments/20260509-phase-fu2-move60-scan256-nofast-200s-miracle`

## Throughput

Stream phase uses Mops/s as the primary ops metric; MB/s is bytes/second using the benchmark byte counter.

| policy | phase1 Mops/s | phase2 Mops/s | phase2 MB/s | phase2/off |
| --- | ---: | ---: | ---: | ---: |
| off | 228.48 | 562.69 | 4501.54 | 1.000x |
| on | 1431.81 | 344.79 | 2758.31 | 0.613x |
| Miracle | 1415.76 | 267.35 | 2138.82 | 0.475x |
| Delay20 | 1476.13 | 249.05 | 1992.43 | 0.443x |

## Delay20 Phase 2 Windows

| window | Mops/s | MB/s | samples |
| --- | ---: | ---: | ---: |
| 0-20s | 405.00 | 3239.99 | 20 |
| 20-40s | 238.05 | 1904.42 | 20 |
| 20-200s | 231.73 | 1853.81 | 180 |
| 40-200s | 230.94 | 1847.49 | 160 |
| 0-200s | 249.05 | 1992.43 | 200 |

## Delay20 Migration Windows

| window | hint faults | PTE updates | promoted | demoted |
| --- | ---: | ---: | ---: | ---: |
| phase1_live | 8,840,030 | 78.77 GiB | 15.50 GiB | 14.94 GiB |
| phase2_live | 5,873,927 | 23.22 GiB | 4.57 GiB | 5.14 GiB |
| phase2_on_window | 5,873,927 | 23.22 GiB | 4.57 GiB | 3.96 GiB |
| phase2_after_off | 0 | 0.00 GiB | 0.00 GiB | 1.18 GiB |

## Files
- `/Serverless/iccd/experiments/20260509-phase-fu2-move60-scan256-nofast-200s-delay20/summaries/phase_summary.csv`
- `/Serverless/iccd/experiments/20260509-phase-fu2-move60-scan256-nofast-200s-delay20/summaries/phase2_10s.csv`
- `/Serverless/iccd/experiments/20260509-phase-fu2-move60-scan256-nofast-200s-delay20/summaries/delay20_phase2_windows.csv`
- `/Serverless/iccd/experiments/20260509-phase-fu2-move60-scan256-nofast-200s-delay20/summaries/delay20_migration_windows.csv`
