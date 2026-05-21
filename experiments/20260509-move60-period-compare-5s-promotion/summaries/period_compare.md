# Moving 60s Period Compare

Comparing the same moving-60s hotset workload with `NUMA_FAST_SCAN=1` and `NUMA_SCAN_SIZE_MB=4096`.
The default run uses the implicit `scan_period_min_ms=1000`; the second run sets `scan_period_min_ms=250`.

## Overall

| case | period_min_ms | promotions | promote_GiB | demotions | demote_GiB | hint_faults | mean_Mops/s | median_Mops/s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1000ms-default | 1000 | 2,098,610 | 8.01 | 2,166,539 | 8.26 | 4,988,863 | 1123.3 | 1255.9 |
| 250ms | 250 | 2,106,145 | 8.03 | 1,894,166 | 7.23 | 5,746,264 | 1380.1 | 1800.8 |

## Window Totals And Follow Speed

`first_promo` is the end time of the first 5s bucket with >1000 promoted pages after the window starts. `1000Mops_s` and `1500Mops_s` are also bucket end times, so they are coarse 5s indicators.

| case | window | offset_GiB | promote_GiB | hint_faults | demote_GiB | first_promo_s | promo_1GiB_s | promo_2GiB_s | promo_4GiB_s | 1000Mops_s | 1500Mops_s |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1000ms-default | window1 | 16 | 2.86 | 1,840,714 | 3.26 | 15.2 | 15.2 | 40.3 | NA | 25.2 | 50.4 |
| 1000ms-default | window2 | 20 | 4.99 | 3,037,014 | 5.01 | 5.4 | 10.4 | 25.6 | 50.7 | 35.6 | 35.6 |
| 250ms | window1 | 16 | 4.00 | 2,377,522 | 3.32 | 5.1 | 5.1 | 20.2 | 40.3 | 5.1 | 5.1 |
| 250ms | window2 | 20 | 3.34 | 2,773,738 | 3.19 | 30.6 | 30.6 | 55.8 | NA | 40.6 | 40.6 |

## 5s Promotion Deltas

| case | interval_s | window | offset_GiB | promote_pages | promote_GiB | hint_faults | demote_pages | ops_Mops/s |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1000ms-default | 0.1-5.1 | window1 | 16 | 0 | 0.00 | 0 | 0 | 398.4 |
| 1000ms-default | 5.1-10.1 | window1 | 16 | 2 | 0.00 | 2 | 0 | 397.0 |
| 1000ms-default | 10.1-15.2 | window1 | 16 | 332,691 | 1.27 | 1,081,846 | 340,529 | 399.9 |
| 1000ms-default | 15.2-20.2 | window1 | 16 | 0 | 0.00 | 5 | 88,704 | 371.5 |
| 1000ms-default | 20.2-25.2 | window1 | 16 | 0 | 0.00 | 0 | 0 | 1259.1 |
| 1000ms-default | 25.2-30.3 | window1 | 16 | 0 | 0.00 | 0 | 0 | 1258.6 |
| 1000ms-default | 30.3-35.3 | window1 | 16 | 5 | 0.00 | 5 | 0 | 1231.7 |
| 1000ms-default | 35.3-40.3 | window1 | 16 | 416,872 | 1.59 | 758,398 | 195,581 | 1257.4 |
| 1000ms-default | 40.3-45.3 | window1 | 16 | 418 | 0.00 | 458 | 229,568 | 1257.4 |
| 1000ms-default | 45.3-50.4 | window1 | 16 | 0 | 0.00 | 0 | 0 | 1802.4 |
| 1000ms-default | 50.4-55.4 | window1 | 16 | 0 | 0.00 | 0 | 0 | 1802.4 |
| 1000ms-default | 55.4-60.4 | window1 | 16 | 0 | 0.00 | 0 | 0 | 1798.4 |
| 1000ms-default | 60.4-65.4 | window2 | 20 | 3,202 | 0.01 | 3,525 | 0 | 119.5 |
| 1000ms-default | 65.4-70.4 | window2 | 20 | 296,836 | 1.13 | 326,513 | 429,888 | 498.7 |
| 1000ms-default | 70.4-75.5 | window2 | 20 | 0 | 0.00 | 0 | 0 | 506.3 |
| 1000ms-default | 75.5-80.5 | window2 | 20 | 0 | 0.00 | 1,048,578 | 0 | 506.7 |
| 1000ms-default | 80.5-85.6 | window2 | 20 | 508,876 | 1.94 | 762,765 | 150,656 | 506.6 |
| 1000ms-default | 85.6-90.6 | window2 | 20 | 30,598 | 0.12 | 339,761 | 289,216 | 441.7 |
| 1000ms-default | 90.6-95.6 | window2 | 20 | 0 | 0.00 | 0 | 0 | 1873.7 |
| 1000ms-default | 95.6-100.7 | window2 | 20 | 0 | 0.00 | 0 | 0 | 1875.9 |
| 1000ms-default | 100.7-105.7 | window2 | 20 | 0 | 0.00 | 0 | 0 | 1873.3 |
| 1000ms-default | 105.7-110.7 | window2 | 20 | 410,483 | 1.57 | 451,614 | 131,421 | 1801.2 |
| 1000ms-default | 110.7-115.8 | window2 | 20 | 57,176 | 0.22 | 104,258 | 310,976 | 1800.7 |
| 1000ms-default | 115.8-120.8 | window2 | 20 | 0 | 0.00 | 0 | 0 | 1802.5 |
| 250ms | 0.0-5.1 | window1 | 16 | 442,929 | 1.69 | 1,140,629 | 0 | 1861.2 |
| 250ms | 5.1-10.1 | window1 | 16 | 67,235 | 0.26 | 612,336 | 349,888 | 1860.2 |
| 250ms | 10.1-15.2 | window1 | 16 | 0 | 0.00 | 0 | 81,792 | 1851.8 |
| 250ms | 15.2-20.2 | window1 | 16 | 506,119 | 1.93 | 589,028 | 438,129 | 1802.0 |
| 250ms | 20.2-25.2 | window1 | 16 | 0 | 0.00 | 0 | 0 | 1804.2 |
| 250ms | 25.2-30.2 | window1 | 16 | 4 | 0.00 | 4 | 0 | 1799.6 |
| 250ms | 30.2-35.3 | window1 | 16 | 1 | 0.00 | 1 | 0 | 1800.7 |
| 250ms | 35.3-40.3 | window1 | 16 | 32,294 | 0.12 | 35,524 | 0 | 1802.1 |
| 250ms | 40.3-45.3 | window1 | 16 | 0 | 0.00 | 0 | 0 | 1801.5 |
| 250ms | 45.3-50.3 | window1 | 16 | 0 | 0.00 | 0 | 0 | 1801.1 |
| 250ms | 50.3-55.4 | window1 | 16 | 0 | 0.00 | 0 | 0 | 1797.7 |
| 250ms | 55.4-60.4 | window1 | 16 | 0 | 0.00 | 0 | 0 | 1800.7 |
| 250ms | 60.4-65.4 | window2 | 20 | 0 | 0.00 | 0 | 0 | 228.4 |
| 250ms | 65.4-70.4 | window2 | 20 | 0 | 0.00 | 0 | 0 | 47.8 |
| 250ms | 70.4-75.5 | window2 | 20 | 0 | 0.00 | 0 | 0 | 430.2 |
| 250ms | 75.5-80.5 | window2 | 20 | 0 | 0.00 | 1,048,578 | 0 | 430.7 |
| 250ms | 80.5-85.5 | window2 | 20 | 0 | 0.00 | 0 | 0 | 431.8 |
| 250ms | 85.5-90.6 | window2 | 20 | 458,030 | 1.75 | 1,092,338 | 204,948 | 431.8 |
| 250ms | 90.6-95.6 | window2 | 20 | 2,048 | 0.01 | 2,248 | 210,816 | 316.4 |
| 250ms | 95.6-100.6 | window2 | 20 | 0 | 0.00 | 0 | 0 | 1910.0 |
| 250ms | 100.6-105.7 | window2 | 20 | 0 | 0.00 | 0 | 0 | 1906.6 |
| 250ms | 105.7-110.7 | window2 | 20 | 0 | 0.00 | 0 | 0 | 1903.6 |
| 250ms | 110.7-115.8 | window2 | 20 | 381,536 | 1.46 | 426,047 | 165,440 | 1907.6 |
| 250ms | 115.8-120.8 | window2 | 20 | 34,324 | 0.13 | 204,527 | 255,377 | 1799.9 |
