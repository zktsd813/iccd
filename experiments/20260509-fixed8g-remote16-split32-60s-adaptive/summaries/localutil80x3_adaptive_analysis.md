# Adaptive Local Utilization 80%x3

- run_id: `20260510Tfixed8g-remote16-split32-60s-adaptive-localutil80x3`
- policy: `adaptive_localutil`, starts with cgroup `node_balancing=2`
- trigger: 10s window, `hit<=2000ms / local_fault_pte_updates >= 80%`, 3 consecutive windows, minimum PTE updates 1000
- kernel: `Linux kernel 6.18.0modified #172 SMP PREEMPT_DYNAMIC Sun May 10 07:45:36 UTC 2026 x86_64 x86_64 x86_64 GNU/Linux`
- note: per-window utilization can exceed 100% when PTE arming and refault accounting fall on opposite sides of a 10s boundary; the controller intentionally uses the sampled window deltas it sees online.

## Controller
| event | elapsed | window | PTE delta | hit<=2000ms | utilization | consecutive | node_balancing |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| start | 0.0s | 0 | 0 | 0 | 0.00% | 0 | 2 |
| sample | 10.1s | 1 | 444,792 | 62,187 | 13.98% | 0 | 2 |
| sample | 20.2s | 2 | 10,438 | 10,256 | 98.25% | 1 | 2 |
| sample | 30.2s | 3 | 23,055 | 19,443 | 84.33% | 2 | 2 |
| sample | 40.3s | 4 | 153,844 | 157,456 | 102.34% | 3 | 2 |
| off | 40.3s | 4 | 153,844 | 157,456 | 102.34% | 3 | 0 |

## Total
| mean Mops/s | hit<=2000ms | local fault PTE updates | utilization | local refault | lost | promote GiB | demote GiB |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 830.92 | 249,342 | 632,129 | 39.44% | 466,527 | 165,602 | 6.75 | 6.32 |

## Phase Summary
| phase | mean Mops/s | hit<=2000ms | PTE updates | utilization | refault | lost | promoted | demoted |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 Friendly fixed8g-hotset-remote | 1093.26 | 249,342 | 632,129 | 39.44% | 466,527 | 165,602 | 1,769,138 | 1,656,136 |
| 2 Unfriendly stream-read-32g-split16-4k | 538.30 | 0 | 0 | 0.00% | 0 | 0 | 0 | 0 |

## 10s Buckets
| time | phase | Mops/s | hit<=2000ms | PTE updates | utilization | promoted | demoted |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 0-10s | 1 Friendly | 291.22 | 68,291 | 451,078 | 15.14% | 682,890 | 324,940 |
| 10-20s | 1 Friendly | 406.46 | 4,152 | 4,152 | 100.00% | 41,596 | 368,960 |
| 20-30s | 1 Friendly | 389.63 | 18,058 | 18,058 | 100.00% | 35,116 | 0 |
| 30-40s | 1 Friendly | 1469.96 | 158,841 | 158,841 | 100.00% | 1,009,536 | 962,236 |
| 40-50s | 1 Friendly | 1999.65 | 0 | 0 | 0.00% | 0 | 0 |
| 50-60s | 1 Friendly | 2002.64 | 0 | 0 | 0.00% | 0 | 0 |
| 60-70s | 2 Unfriendly | 535.02 | 0 | 0 | 0.00% | 0 | 0 |
| 70-80s | 2 Unfriendly | 538.34 | 0 | 0 | 0.00% | 0 | 0 |
| 80-90s | 2 Unfriendly | 538.71 | 0 | 0 | 0.00% | 0 | 0 |
| 90-100s | 2 Unfriendly | 539.10 | 0 | 0 | 0.00% | 0 | 0 |
| 100-110s | 2 Unfriendly | 538.47 | 0 | 0 | 0.00% | 0 | 0 |
| 110-120s | 2 Unfriendly | 540.15 | 0 | 0 | 0.00% | 0 | 0 |

## Files
- `/Serverless/iccd/experiments/20260509-fixed8g-remote16-split32-60s-adaptive/summaries/localutil80x3_controller.csv`
- `/Serverless/iccd/experiments/20260509-fixed8g-remote16-split32-60s-adaptive/summaries/localutil80x3_adaptive_10s.csv`
- `/Serverless/iccd/experiments/20260509-fixed8g-remote16-split32-60s-adaptive/summaries/localutil80x3_adaptive_5s.csv`
- `/Serverless/iccd/experiments/20260509-fixed8g-remote16-split32-60s-adaptive/summaries/localutil80x3_adaptive_phase_summary.csv`
- `/Serverless/iccd/experiments/20260509-fixed8g-remote16-split32-60s-adaptive/summaries/localutil80x3_adaptive_summary.json`
- artifacts: `/Serverless/iccd/experiments/20260509-fixed8g-remote16-split32-60s-adaptive/qemu-logs/phase_candidate_microbench/20260510Tfixed8g-remote16-split32-60s-adaptive-localutil80x3/`
