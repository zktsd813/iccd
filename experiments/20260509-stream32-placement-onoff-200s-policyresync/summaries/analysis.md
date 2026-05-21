# Stream32 Placement Sweep

Date: 2026-05-09 UTC

## Setup

- Kernel: `6.18.0modified #163` with policy-resync patch
- Initrd: `initramfs-6.18.0modified-policy-resync-20260509.img`
- Workload shape: 32 GiB streaming read, 4 KiB stride, 32 threads, 200s measured window after 20s warmup
- VM: 32 vCPU, 96G, node0 32G on host node0, node1 64G on host node2, KVM
- Cgroup cap: 16G (`CAPACITY_PAGES=4194304`)
- Migration policy: off/on, `GLOBAL_NUMA_ON=0`, `NODE_BALANCING_ON=2`, MGLRU `0x0007`
- Scan: `NUMA_SCAN_SIZE_MB=4096`, effective period min `1000ms`, `NUMA_FAST_SCAN=0`, live stats every 5s

## Ops Summary

| placement | off Mops/s | on Mops/s | on/off | on promoted | on demoted | on hints | on PTE updates |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0G local / 32G remote | 65.03 | 214.52 | 3.299x | 25.52 GiB | 10.34 GiB | 18,146,815 | 66.67 GiB |
| 8G local / 24G remote | 280.95 | 232.00 | 0.826x | 16.36 GiB | 9.17 GiB | 15,664,042 | 58.12 GiB |
| 16G local / 16G remote | 563.37 | 218.48 | 0.388x | 11.55 GiB | 10.96 GiB | 14,072,061 | 52.53 GiB |

## Initial Placement

| placement | policy | node0 anon | node1 anon |
| --- | --- | ---: | ---: |
| 0G local / 32G remote | off | 0.00 GiB | 32.00 GiB |
| 0G local / 32G remote | on | 0.00 GiB | 32.00 GiB |
| 8G local / 24G remote | off | 8.00 GiB | 24.00 GiB |
| 8G local / 24G remote | on | 8.00 GiB | 24.00 GiB |
| 16G local / 16G remote | off | 14.60 GiB | 17.40 GiB |
| 16G local / 16G remote | on | 14.60 GiB | 17.40 GiB |

## Artifacts

- Ops time series: `/Serverless/iccd/experiments/20260509-stream32-placement-onoff-200s-policyresync/graphs/ops_timeseries.svg`
- Ops average bar: `/Serverless/iccd/experiments/20260509-stream32-placement-onoff-200s-policyresync/graphs/ops_avg_bar.svg`
- 10s ops CSV: `/Serverless/iccd/experiments/20260509-stream32-placement-onoff-200s-policyresync/summaries/ops_10s.csv`
- 10s migration CSV: `/Serverless/iccd/experiments/20260509-stream32-placement-onoff-200s-policyresync/summaries/migration_10s.csv`
- Raw run root: `/Serverless/iccd/experiments/20260509-stream32-placement-onoff-200s-policyresync/qemu-logs/phase_candidate_microbench/20260509Tstream32-placement-policyresync/guest-artifacts/20260509Tstream32-placement-policyresync`
## Per-Placement Ops Graphs

- `/Serverless/iccd/experiments/20260509-stream32-placement-onoff-200s-policyresync/graphs/ops_timeseries_remote.svg`
- `/Serverless/iccd/experiments/20260509-stream32-placement-onoff-200s-policyresync/graphs/ops_timeseries_split8.svg`
- `/Serverless/iccd/experiments/20260509-stream32-placement-onoff-200s-policyresync/graphs/ops_timeseries_split16.svg`

