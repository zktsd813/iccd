# HSS32 Split16 Scan256 Fast-Scan Period Sweep

Date: 2026-05-09 UTC

## Setup

- Workload: `stream_read_32g_split16_4kstride`, HSS32 16:16 initial placement
- New runs: `NUMA_SCAN_SIZE_MB=256`, `NUMA_FAST_SCAN=1`, period min `500ms` and `250ms`
- Reference: existing `1000ms / fast_scan=0` scan256 split16 run
- Kernel: `6.18.0modified #163`; cgroup cap 16G; MGLRU `0x0007`; live stats every 5s

## Ops Summary

| case | avg Mops/s | on/off vs baseline off | promoted | demoted | hint faults | PTE updates |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| off baseline | 563.81 | 1.000x | 0.00 GiB | 0.00 GiB | 0 | 0.00 GiB |
| 1000ms no-fast | 258.28 | 0.458x | 30.08 GiB | 29.04 GiB | 22,819,726 | 84.04 GiB |
| 500ms fast | 272.04 | 0.482x | 33.60 GiB | 32.68 GiB | 49,979,601 | 188.65 GiB |
| 250ms fast | 275.54 | 0.489x | 32.78 GiB | 32.12 GiB | 61,833,065 | 232.60 GiB |

## Initial Placement

| case | node0 anon | node1 anon |
| --- | ---: | ---: |
| off baseline | 14.60 GiB | 17.40 GiB |
| 1000ms no-fast | 14.60 GiB | 17.40 GiB |
| 500ms fast | 14.60 GiB | 17.40 GiB |
| 250ms fast | 14.60 GiB | 17.40 GiB |

## Artifacts

- `/Serverless/iccd/experiments/20260509-hss32-split16-scan256-fastscan-period/graphs/hss32_split16_scan256_period_ops_avg_bar.svg`
- `/Serverless/iccd/experiments/20260509-hss32-split16-scan256-fastscan-period/graphs/hss32_split16_scan256_period_ops_timeseries.svg`
- `/Serverless/iccd/experiments/20260509-hss32-split16-scan256-fastscan-period/graphs/hss32_split16_scan256_period_hint_faults_10s.svg`
- `/Serverless/iccd/experiments/20260509-hss32-split16-scan256-fastscan-period/graphs/hss32_split16_scan256_period_pte_updates_10s.svg`
- `/Serverless/iccd/experiments/20260509-hss32-split16-scan256-fastscan-period/graphs/hss32_split16_scan256_period_hint_pte_totals.svg`
- `/Serverless/iccd/experiments/20260509-hss32-split16-scan256-fastscan-period/summaries/ops_10s.csv`
- `/Serverless/iccd/experiments/20260509-hss32-split16-scan256-fastscan-period/summaries/migration_10s.csv`
- 500ms raw root: `/Serverless/iccd/experiments/20260509-hss32-split16-scan256-fastscan-period/qemu-logs/phase_candidate_microbench/20260509Thss32-split16-scan256-fast500/guest-artifacts/20260509Thss32-split16-scan256-fast500`
- 250ms raw root: `/Serverless/iccd/experiments/20260509-hss32-split16-scan256-fastscan-period/qemu-logs/phase_candidate_microbench/20260509Thss32-split16-scan256-fast250/guest-artifacts/20260509Thss32-split16-scan256-fast250`
