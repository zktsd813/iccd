# Scan256 Moving-60s Compare

Requested comparison: `NUMA_SCAN_SIZE_MB=256`; 1000ms case with `NUMA_FAST_SCAN=0`; 250ms case with `NUMA_FAST_SCAN=1`. Both use the moving 4GiB hotset candidate and `LIVE_SAMPLE_SEC=5`.

## Run Settings

| case | period_min_ms | fast_scan | scan_size_mb | effective_scan_size_mb | offset sequence |
| --- | ---: | ---: | ---: | ---: | --- |
| 1000ms-fastoff-scan256 | 1000 | 0 | 256 | 256 | 16G -> 20G -> 44G |
| 250ms-faston-scan256 | 250 | 1 | 256 | 256 | 16G -> 20G -> 44G |

## Overall

| case | promote_GiB | demote_GiB | hint_faults | mean_Mops/s | median_Mops/s |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1000ms-fastoff-scan256 | 0.00 | 0.00 | 18 | 261.7 | 292.0 |
| 250ms-faston-scan256 | 4.00 | 4.00 | 2,202,034 | 996.6 | 228.6 |

## Window Follow Timing

| case | phase | promote_GiB | hint_faults | demote_GiB | first_promo_s | promo_1GiB_s | promo_2GiB_s | promo_4GiB_s |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1000ms-fastoff-scan256 | window1 | 0.00 | 0 | 0.00 | NA | NA | NA | NA |
| 1000ms-fastoff-scan256 | window2 | 0.00 | 0 | 0.00 | NA | NA | NA | NA |
| 1000ms-fastoff-scan256 | post | 0.00 | 18 | 0.00 | NA | NA | NA | NA |
| 250ms-faston-scan256 | window1 | 4.00 | 1,153,445 | 4.00 | 5.1 | 10.1 | 10.1 | 20.2 |
| 250ms-faston-scan256 | window2 | 0.00 | 1,048,576 | 0.00 | NA | NA | NA | NA |
| 250ms-faston-scan256 | post | 0.00 | 13 | 0.00 | NA | NA | NA | NA |

Window2 throughput recovery from raw 1s mbench rows, relative to the 60s boundary:

| case | first_500Mops_s | first_1Gops_s | first_1.5Gops_s | first_1.8Gops_s |
| --- | ---: | ---: | ---: | ---: |
| 1000ms-fastoff-scan256 | NA | NA | NA | NA |
| 250ms-faston-scan256 | NA | NA | NA | NA |

## 10s Timeline: 1000ms-fastoff-scan256

| time_s | phase | mean_Mops/s | promote_GiB | hint_faults | demote_GiB | anon_n0_end_GiB |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 0-10 | w1 16G | 228.3 | 0.000 | 0 | 0.000 | 14.99 |
| 10-20 | w1 16G | 228.2 | 0.000 | 0 | 0.000 | 14.99 |
| 20-30 | w1 16G | 228.2 | 0.000 | 0 | 0.000 | 14.99 |
| 30-40 | w1 16G | 228.1 | 0.000 | 0 | 0.000 | 14.99 |
| 40-50 | w1 16G | 228.2 | 0.000 | 0 | 0.000 | 14.99 |
| 50-60 | w1 16G | 228.2 | 0.000 | 0 | 0.000 | 14.99 |
| 60-70 | w2 20G | 292.7 | 0.000 | 0 | 0.000 | 14.99 |
| 70-80 | w2 20G | 293.4 | 0.000 | 0 | 0.000 | 14.99 |
| 80-90 | w2 20G | 293.3 | 0.000 | 0 | 0.000 | 14.99 |
| 90-100 | w2 20G | 293.7 | 0.000 | 0 | 0.000 | 14.99 |
| 100-110 | w2 20G | 293.7 | 0.000 | 0 | 0.000 | 14.99 |
| 110-120 | w2 20G | 294.0 | 0.000 | 0 | 0.000 | 14.99 |

## 10s Timeline: 250ms-faston-scan256

| time_s | phase | mean_Mops/s | promote_GiB | hint_faults | demote_GiB | anon_n0_end_GiB |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 0-10 | w1 16G | 1806.6 | 2.000 | 576,726 | 1.195 | 15.12 |
| 10-20 | w1 16G | 1804.8 | 2.000 | 576,719 | 2.806 | 14.31 |
| 20-30 | w1 16G | 1804.9 | 0.000 | 0 | 0.000 | 14.31 |
| 30-40 | w1 16G | 1806.0 | 0.000 | 0 | 0.000 | 14.31 |
| 40-50 | w1 16G | 1806.4 | 0.000 | 0 | 0.000 | 14.31 |
| 50-60 | w1 16G | 1805.9 | 0.000 | 0 | 0.000 | 14.31 |
| 60-70 | w2 20G | 226.1 | 0.000 | 0 | 0.000 | 14.31 |
| 70-80 | w2 20G | 228.4 | 0.000 | 1,048,576 | 0.000 | 14.31 |
| 80-90 | w2 20G | 228.3 | 0.000 | 0 | 0.000 | 14.31 |
| 90-100 | w2 20G | 228.3 | 0.000 | 0 | 0.000 | 14.31 |
| 100-110 | w2 20G | 228.2 | 0.000 | 0 | 0.000 | 14.31 |
| 110-120 | w2 20G | 228.0 | 0.000 | 0 | 0.000 | 14.31 |

## Initial Reading

- `1000ms-fastoff-scan256` produced effectively no NUMA hint faults during the two measured windows and therefore no promotion/demotion. Throughput stayed near remote-memory speed: about 228 Mops/s in window1 and 293 Mops/s in window2.
- `250ms-faston-scan256` promoted the first 4GiB window quickly: about 2GiB in 0-10s and another 2GiB in 10-20s. That raised window1 throughput to about 1.8 Gops/s.
- In window2, `250ms-faston-scan256` saw a 4GiB-sized hint-fault wave in 70-80s but did not promote the second window. Throughput stayed around 228 Mops/s for the rest of the run.
- So this requested split does separate scan behavior, but it does not produce sustained follow-the-moving-hotset behavior at 256MB scan size. The fast-on/250 case follows the first window only in this run.
