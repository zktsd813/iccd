# Stream32 Placement Sweep, Scan256

Date: 2026-05-09 UTC

## Setup

- Kernel: `6.18.0modified #163` with policy-resync patch
- Workload: 32 GiB streaming read, 4 KiB stride, 32 threads, 200s measured window after 20s warmup
- Scan: `NUMA_SCAN_SIZE_MB=256`, effective period min `1000ms`, `NUMA_FAST_SCAN=0`
- VM: 32 vCPU, 96G, node0 32G on host node0, node1 64G on host node2, KVM
- Cgroup cap: 16G, MGLRU `0x0007`, live stats every 5s

## Ops Summary

| placement | off Mops/s | on Mops/s | on/off | on promoted | on demoted | on hints | on PTE updates |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0G local / 32G remote | 65.02 | 265.59 | 4.085x | 43.77 GiB | 28.24 GiB | 25,461,906 | 92.75 GiB |
| 8G local / 24G remote | 280.55 | 267.90 | 0.955x | 35.55 GiB | 27.90 GiB | 23,435,666 | 85.84 GiB |
| 16G local / 16G remote | 563.81 | 258.28 | 0.458x | 30.08 GiB | 29.04 GiB | 22,819,726 | 84.04 GiB |

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

- `/Serverless/iccd/experiments/20260509-stream32-placement-scan256-onoff-200s-policyresync/graphs/ops_avg_bar.svg`
- `/Serverless/iccd/experiments/20260509-stream32-placement-scan256-onoff-200s-policyresync/graphs/ops_timeseries.svg`
- `/Serverless/iccd/experiments/20260509-stream32-placement-scan256-onoff-200s-policyresync/graphs/ops_timeseries_remote.svg`
- `/Serverless/iccd/experiments/20260509-stream32-placement-scan256-onoff-200s-policyresync/graphs/ops_timeseries_split8.svg`
- `/Serverless/iccd/experiments/20260509-stream32-placement-scan256-onoff-200s-policyresync/graphs/ops_timeseries_split16.svg`
- `/Serverless/iccd/experiments/20260509-stream32-placement-scan256-onoff-200s-policyresync/summaries/ops_10s.csv`
- `/Serverless/iccd/experiments/20260509-stream32-placement-scan256-onoff-200s-policyresync/summaries/migration_10s.csv`
- Raw run root: `/Serverless/iccd/experiments/20260509-stream32-placement-scan256-onoff-200s-policyresync/qemu-logs/phase_candidate_microbench/20260509Tstream32-placement-scan256-policyresync/guest-artifacts/20260509Tstream32-placement-scan256-policyresync`
