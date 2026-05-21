# Local Fault Sampling 10%: migration on

- run_id: `20260510Tfixed8g-remote16-split32-60s-on-localfault10`
- policy: `on`, candidate: `phase_fixed8g_remote_split32_stream4k_localft`
- knobs: `node_balancing=2`, `scan_size=256MB`, `scan_period_min=1000ms`, `fast_scan=0`, `numa_local_fault_on_tiering=10`, `numa_local_fault_refault_hit_ms=1000`
- ratio reported here: `delta(numa_local_fault_refault_hit) / delta(numa_local_fault_refault)`, not kernel `numa_local_fault_refault_rate_pct`.
- counter buckets use the first live sample at or after each bucket boundary; adjacent buckets share the boundary sample and do not overlap.

## Total
| mean Mops/s | local refault | <=1000ms | hit/refault | sampled | PTE updates | lost | promote GiB | demote GiB |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 702.13 | 1,608,016 | 887,146 | 55.17% | 1,881,819 | 1,881,819 | 273,803 | 15.23 | 14.29 |

## Phase Summary
| phase | mean Mops/s | local refault | <=1000ms | hit/refault | sampled | PTE updates | lost |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 Friendly fixed8g-hotset-remote | 957.69 | 771,358 | 186,027 | 24.12% | 1,055,749 | 1,055,749 | 265,000 |
| 2 Unfriendly stream-read-32g-split16-4k | 459.26 | 836,658 | 701,119 | 83.80% | 826,070 | 826,070 | 8,803 |

## 10s Buckets
| time | phase | Mops/s | local refault | <=1000ms | hit/refault | sampled | PTE updates | lost |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0-10s | 1 | 291.12 | 9 | 9 | 100.00% | 382,809 | 382,809 | 31,540 |
| 10-20s | 1 | 402.37 | 0 | 0 | 0.00% | 0 | 0 | 37,770 |
| 20-30s | 1 | 387.08 | 0 | 0 | 0.00% | 113,600 | 113,600 | 0 |
| 30-40s | 1 | 791.65 | 65,931 | 57,537 | 87.27% | 240,370 | 240,370 | 118,720 |
| 40-50s | 1 | 1947.99 | 6,019 | 4,892 | 81.28% | 88,650 | 88,650 | 64,410 |
| 50-60s | 1 | 1984.50 | 699,399 | 123,589 | 17.67% | 230,320 | 230,320 | 12,560 |
| 60-70s | 2 | 626.82 | 60,131 | 60,131 | 100.00% | 67,710 | 67,710 | 0 |
| 70-80s | 2 | 475.31 | 341,260 | 280,070 | 82.07% | 314,290 | 314,290 | 0 |
| 80-90s | 2 | 407.99 | 41,410 | 37,300 | 90.07% | 47,210 | 47,210 | 0 |
| 90-100s | 2 | 399.53 | 121,357 | 78,620 | 64.78% | 139,410 | 139,410 | 2,364 |
| 100-110s | 2 | 434.78 | 205,569 | 185,842 | 90.40% | 195,700 | 195,700 | 6,210 |
| 110-120s | 2 | 394.38 | 66,931 | 59,156 | 88.38% | 61,750 | 61,750 | 229 |
