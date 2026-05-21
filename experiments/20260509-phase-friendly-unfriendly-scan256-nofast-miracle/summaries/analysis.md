# Friendly/Unfriendly Phase Scan256 No-Fast Miracle

Date: 2026-05-09 UTC

## Setup

- Workload: `phase_move15s4g_split32_stream4k_localft`
- Phase order: friendly moving 4 GiB hotset in phases 1/3/5, split32 streaming 4 KiB-stride unfriendly in phases 2/4/6
- Policies: `off`, `on`, `oracle_cgroup_global0` (`Miracle`)
- Scan: `NUMA_SCAN_SIZE_MB=256`, effective `256`; `NUMA_FAST_SCAN=0`; `NUMA_SCAN_PERIOD_MIN_MS=1000`, effective `1000`
- Kernel: `Linux kernel 6.18.0modified #163 SMP PREEMPT_DYNAMIC Sat May  9 12:53:28 UTC 2026 x86_64 x86_64 x86_64 GNU/Linux`
- VM: 32 vCPU, 96G memory, node0 host node0 32G, node1 host node2 64G, KVM enabled
- Cgroup cap: 16G (`CAPACITY_PAGES=4194304`); MGLRU `0x0007`; earlystop/pingpong disabled
- Initial anon placement: node0 `14.60 GiB`, node1 `49.40 GiB`

## Overall Results

| policy | overall mean | overall median | vs off | promoted | demoted | hint faults | PTE updates |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| off | 833.30 Mops/s | 563.61 Mops/s | 1.000x | 0.00 GiB | 0.00 GiB | 0 | 0.00 GiB |
| on | 740.74 Mops/s | 439.17 Mops/s | 0.889x | 55.06 GiB | 54.28 GiB | 66,074,129 | 278.55 GiB |
| Miracle | 673.86 Mops/s | 437.13 Mops/s | 0.809x | 24.03 GiB | 23.67 GiB | 24,402,262 | 135.84 GiB |

## Phase-Type Results

| policy | friendly mean | friendly vs off | unfriendly mean | unfriendly vs off |
| --- | ---: | ---: | ---: | ---: |
| off | 1087.25 Mops/s | 1.000x | 4508.53 MiB/s | 1.000x |
| on | 1124.39 Mops/s | 1.034x | 3013.77 MiB/s | 0.668x |
| Miracle | 968.74 Mops/s | 0.891x | 3155.10 MiB/s | 0.700x |

## Phase-By-Phase Results

Mean throughput is reported in each phase's native unit: friendly phases use
Mops/s, and unfriendly phases use MiB/s.

| phase | kind | off | on | Miracle | on/off | Miracle/off |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | friendly | 1072.64 Mops/s | 1154.57 Mops/s | 1145.60 Mops/s | 1.076x | 1.068x |
| 2 | unfriendly | 4511.91 MiB/s | 3128.36 MiB/s | 3393.10 MiB/s | 0.693x | 0.752x |
| 3 | friendly | 1094.72 Mops/s | 1167.32 Mops/s | 921.89 Mops/s | 1.066x | 0.842x |
| 4 | unfriendly | 4502.34 MiB/s | 2641.40 MiB/s | 3664.60 MiB/s | 0.587x | 0.814x |
| 5 | friendly | 1094.39 Mops/s | 1051.26 Mops/s | 838.73 Mops/s | 0.961x | 0.766x |
| 6 | unfriendly | 4511.33 MiB/s | 3271.55 MiB/s | 2407.59 MiB/s | 0.725x | 0.534x |

## Notes

- Under this scan256/no-fast/1000ms setting, full `on` improves friendly mean only slightly (`1.034x`) and hurts unfriendly throughput (`0.668x`).
- Miracle reduces migration volume versus full `on` (`0.437x` promoted, `0.436x` demoted), but in this run it does not improve overall mixed ops because friendly phases are lower than full `on`.
- The Miracle controller log confirms cgroup node balancing `2` on friendly phases and `0` on unfriendly phases while global NUMA balancing stays `0`.

## Artifacts

- `/Serverless/iccd/experiments/20260509-phase-friendly-unfriendly-scan256-nofast-miracle/graphs/phase_fu_scan256_nofast_overall_ops_bar.svg`
- `/Serverless/iccd/experiments/20260509-phase-friendly-unfriendly-scan256-nofast-miracle/graphs/phase_fu_scan256_nofast_phase_type_bar.svg`
- `/Serverless/iccd/experiments/20260509-phase-friendly-unfriendly-scan256-nofast-miracle/graphs/phase_fu_scan256_nofast_phase_by_phase_throughput.svg`
- `/Serverless/iccd/experiments/20260509-phase-friendly-unfriendly-scan256-nofast-miracle/graphs/phase_fu_scan256_nofast_phase_by_phase_ratio.svg`
- `/Serverless/iccd/experiments/20260509-phase-friendly-unfriendly-scan256-nofast-miracle/graphs/phase_fu_scan256_nofast_migration_totals.svg`
- `/Serverless/iccd/experiments/20260509-phase-friendly-unfriendly-scan256-nofast-miracle/graphs/phase_fu_scan256_nofast_timeseries.svg`
- `/Serverless/iccd/experiments/20260509-phase-friendly-unfriendly-scan256-nofast-miracle/summaries/summary.csv`
- `/Serverless/iccd/experiments/20260509-phase-friendly-unfriendly-scan256-nofast-miracle/summaries/phase_summary.csv`
- `/Serverless/iccd/experiments/20260509-phase-friendly-unfriendly-scan256-nofast-miracle/summaries/phase_ratios.csv`
- `/Serverless/iccd/experiments/20260509-phase-friendly-unfriendly-scan256-nofast-miracle/summaries/timeseries.csv`
- `/Serverless/iccd/experiments/20260509-phase-friendly-unfriendly-scan256-nofast-miracle/summaries/migration_samples.csv`
- raw root: `/Serverless/iccd/experiments/20260509-phase-friendly-unfriendly-scan256-nofast-miracle/qemu-logs/phase_candidate_microbench/20260509Tphase-split32-scan256-nofast-miracle/guest-artifacts/20260509Tphase-split32-scan256-nofast-miracle`
