# 1000ms Rerun vs 250ms Fine-Grained Check

All runs use `NUMA_FAST_SCAN=1`, `NUMA_SCAN_SIZE_MB=4096`, moving 60s hotset, and the same observed offset sequence `16G -> 20G -> 44G`. The 1000ms-rerun was collected after noticing that the previous period comparison reused an older 1000ms run.

## Overall

| case | period_ms | promote_GiB | demote_GiB | hint_faults | mean_Mops/s | median_Mops/s | initial_live_promote_pages |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1000ms-rerun | 1000 | 8.19 | 7.44 | 5,142,811 | 1163.5 | 1794.2 | 153,894 |
| 250ms | 250 | 8.03 | 7.23 | 5,746,264 | 1380.1 | 1800.8 | 0 |
| 1000ms-old-reused | 1000 | 8.01 | 8.26 | 4,988,863 | 1123.3 | 1255.9 | 296,554 |

## Window2 Follow Timing

Times are relative to the 60s boundary into the second active window. Throughput thresholds use raw 1s `mbench.stdout.csv` rows and ignore the row ending exactly at 60s because that row covers the previous interval.

| case | w2_promote_GiB | w2_hint_faults | first_promo_gt1k_s | promo_1GiB_s | promo_2GiB_s | promo_4GiB_s | first_1Gops_s | first_1.5Gops_s | first_1.8Gops_s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1000ms-rerun | 4.12 | 3,127,564 | 5.5 | 30.6 | 55.8 | 60.9 | 37.0 | 37.0 | 38.0 |
| 250ms | 3.34 | 2,773,738 | 30.6 | 30.6 | 55.8 | NA | 37.0 | 37.0 | 38.0 |
| 1000ms-old-reused | 4.99 | 3,037,014 | 5.4 | 10.4 | 25.6 | 50.7 | 32.0 | 32.0 | 32.0 |

## Window2 5s Promotion Deltas

### 1000ms-rerun

| interval_s | promote_GiB | hint_faults | demote_GiB |
| --- | ---: | ---: | ---: |
| 60.466-65.488 | 0.591 | 170,352 | 0.000 |
| 65.488-70.512 | 0.000 | 0 | 0.000 |
| 70.512-75.539 | 0.000 | 0 | 0.000 |
| 75.539-80.575 | 0.000 | 1,048,578 | 0.000 |
| 80.575-85.614 | 0.000 | 0 | 0.000 |
| 85.614-90.638 | 1.248 | 953,347 | 0.944 |
| 90.638-95.666 | 0.008 | 128,159 | 0.893 |
| 95.666-100.698 | 0.000 | 0 | 0.688 |
| 100.698-105.734 | 0.000 | 0 | 0.000 |
| 105.734-110.768 | 0.000 | 0 | 0.000 |
| 110.768-115.828 | 2.022 | 591,440 | 0.420 |
| 115.828-120.859 | 0.252 | 235,688 | 1.201 |

### 250ms

| interval_s | promote_GiB | hint_faults | demote_GiB |
| --- | ---: | ---: | ---: |
| 60.388-65.415 | 0.000 | 0 | 0.000 |
| 65.415-70.444 | 0.000 | 0 | 0.000 |
| 70.444-75.474 | 0.000 | 0 | 0.000 |
| 75.474-80.510 | 0.000 | 1,048,578 | 0.000 |
| 80.510-85.549 | 0.000 | 0 | 0.000 |
| 85.549-90.582 | 1.747 | 1,092,338 | 0.782 |
| 90.582-95.614 | 0.008 | 2,248 | 0.804 |
| 95.614-100.644 | 0.000 | 0 | 0.000 |
| 100.644-105.675 | 0.000 | 0 | 0.000 |
| 105.675-110.704 | 0.000 | 0 | 0.000 |
| 110.704-115.761 | 1.455 | 426,047 | 0.631 |
| 115.761-120.793 | 0.131 | 204,527 | 0.974 |

## Interpretation

- The rerun invalidates the strong reading that only `250ms` has a late second-window burst. The new `1000ms` run also has its effective second-window recovery around 37s after the boundary, essentially identical to `250ms`.
- The old reused `1000ms` run was the outlier for window2: it reached 1GiB promotion by 10.4s and 2GiB by 25.6s, while the rerun reaches those at 30.6s and 55.8s.
- Both rerun-1000ms and 250ms show a full 4GiB-sized hint-fault wave around 75-80s with zero promotion, followed by the first large promotion wave around 85.5-90.6s. This points to scan/refault eligibility or scanner phase alignment, not a simple `scan_period_min_ms=250` regression.
- The offset sequence is not the differentiator here; all three runs used `16G -> 20G -> 44G`.
