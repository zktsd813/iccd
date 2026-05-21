# Local Fault Sampling 10%, 2000ms Hit: migration on

- run_id: `20260510Tfixed8g-remote16-split32-60s-on-lf10-hit2000`
- policy: `on`, candidate: `phase_fixed8g_remote_split32_stream4k_localft`
- kernel: `Linux kernel 6.18.0modified #172 SMP PREEMPT_DYNAMIC Sun May 10 07:45:36 UTC 2026 x86_64`
- initrd: `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-lf-hit2000-20260510.img`
- knobs: `node_balancing=2`, `scan_size=256MB`, `scan_period_min=1000ms`, `fast_scan=0`, `numa_local_fault_on_tiering=10`, `numa_local_fault_refault_hit_ms=2000`
- local memory utilization metric: `delta(numa_local_fault_refault_hit <= 2000ms) / delta(numa_local_fault_pte_updates)`
- PFN diagnostics total: candidates `27,680,957`, selected `2,247,743`, selected bp `812`
- Note: per-bucket ratios can be boundary-shifted because PTE arming and refault accounting happen at different times; phase/total ratios are more stable.

## Total
| mean Mops/s | hit<=2000ms | local fault PTE updates | utilization | local refault | refault/PTE | lost | promote GiB | demote GiB |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 773.60 | 1,838,434 | 2,247,743 | 81.79% | 2,033,375 | 90.46% | 214,368 | 16.54 | 16.65 |

## Phase Summary
| phase | mean Mops/s | hit<=2000ms | PTE updates | utilization | refault | refault/PTE | lost |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 Friendly fixed8g-hotset-remote | 1083.49 | 457,808 | 840,620 | 54.46% | 457,808 | 54.46% | 208,664 |
| 2 Unfriendly stream-read-32g-split16-4k | 445.38 | 1,350,041 | 1,380,873 | 97.77% | 1,370,834 | 99.27% | 5,136 |

## 10s Buckets
| time | phase | Mops/s | hit<=2000ms | PTE updates | utilization | refault | lost |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 0-10s | 1 Friendly | 289.36 | 66,933 | 449,745 | 14.88% | 66,933 | 30,939 |
| 10-20s | 1 Friendly | 401.21 | 3,847 | 3,847 | 100.00% | 3,847 | 38,281 |
| 20-30s | 1 Friendly | 387.22 | 24,593 | 24,727 | 99.46% | 24,593 | 0 |
| 30-40s | 1 Friendly | 1510.90 | 152,713 | 152,579 | 100.09% | 152,713 | 96,344 |
| 40-50s | 1 Friendly | 1969.93 | 157,085 | 157,085 | 100.00% | 157,085 | 16,181 |
| 50-60s | 1 Friendly | 1772.17 | 59,290 | 59,290 | 100.00% | 233,438 | 26,919 |
| 60-70s | 2 Unfriendly | 518.41 | 439,736 | 440,338 | 99.86% | 439,736 | 602 |
| 70-80s | 2 Unfriendly | 508.98 | 139,785 | 174,723 | 80.00% | 139,785 | 3 |
| 80-90s | 2 Unfriendly | 413.19 | 315,484 | 284,087 | 111.05% | 315,766 | 3,256 |
| 90-100s | 2 Unfriendly | 425.70 | 80,834 | 82,821 | 97.60% | 80,834 | 1 |
| 100-110s | 2 Unfriendly | 452.18 | 139,326 | 159,272 | 87.48% | 159,837 | 1,274 |
| 110-120s | 2 Unfriendly | 372.47 | 244,588 | 248,054 | 98.60% | 244,588 | 0 |

## Files
- `/Serverless/iccd/experiments/20260509-fixed8g-remote16-split32-60s-adaptive/summaries/localfault10_hit2000_on_10s.csv`
- `/Serverless/iccd/experiments/20260509-fixed8g-remote16-split32-60s-adaptive/summaries/localfault10_hit2000_on_5s.csv`
- `/Serverless/iccd/experiments/20260509-fixed8g-remote16-split32-60s-adaptive/summaries/localfault10_hit2000_on_phase_summary.csv`
- `/Serverless/iccd/experiments/20260509-fixed8g-remote16-split32-60s-adaptive/summaries/localfault10_hit2000_on_summary.json`
- artifacts: `/Serverless/iccd/experiments/20260509-fixed8g-remote16-split32-60s-adaptive/qemu-logs/phase_candidate_microbench/20260510Tfixed8g-remote16-split32-60s-on-lf10-hit2000/`
