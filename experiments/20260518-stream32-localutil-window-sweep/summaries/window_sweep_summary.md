# Stream32 local-util window sweep, 300s

Common setup: `stream_read_32g_split16_4kstride`, scan size 256MB, period min 1000ms, fast scan off, local fault sampling 10%, hit threshold 2000ms, threshold 80%, 3 consecutive windows, min PTE 1000. Metric is `access_pct = delta(local_fault_refault) / delta(local_fault_pte_updates)`.

## Summary
| window | off_s | local pte | refault | lost | promoted GiB | demoted GiB | mean MiB/s | median MiB/s | after-off MiB/s |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 20s | 60.9 | 944,009 | 922,922 | 21,087 | 12.95 | 12.36 | 1387.7 | 1314.0 | 1303.2 |
| 10s | 30.3 | 925,834 | 921,319 | 4,515 | 7.64 | 7.07 | 1426.4 | 1364.0 | 1375.5 |
| 5s | 15.9 | 504,148 | 504,148 | 0 | 4.02 | 3.75 | 3241.4 | 3270.0 | 3243.9 |

## Caveat
For short windows, `refault_delta` can include PTEs armed in the previous window but faulted in the current window. That is why some controller ratios exceed 100%. The current global counters are not tagged by `window_seq`; exact window-local accounting would need per-window tagging or a drain/grace interval before sampling.

## Window 20s
| event | t(s) | seq | pte | refault | hit | lost | access | fast | consec | nb |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| sample | 20.6 | 2 | 422,117 | 422,117 | 422,117 | 0 | 100.00% | 100.00% | 1 | 2 |
| sample | 40.8 | 3 | 313,521 | 287,808 | 287,514 | 10,838 | 91.79% | 91.70% | 2 | 2 |
| sample | 60.9 | 4 | 208,097 | 211,018 | 211,297 | 10,249 | 101.40% | 101.53% | 3 | 2 |
| off | 60.9 | 4 | 208,097 | 211,018 | 211,297 | 10,249 | 101.40% | 101.53% | 3 | 0 |

Off split from 5s live samples:

| interval | local_pte | refault | hit | lost | promote | demote | hint_fault | pte_update |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| <= off | 907,359 | 886,272 | 886,272 | 17,999 | 3,157,946 | 2,791,679 | 12,625,378 | 12,723,678 |
| > off | 36,650 | 36,650 | 36,650 | 3,088 | 237,458 | 447,870 | 747,112 | 750,511 |
## Window 10s
| event | t(s) | seq | pte | refault | hit | lost | access | fast | consec | nb |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| sample | 10.1 | 2 | 420,592 | 420,592 | 420,592 | 0 | 100.00% | 100.00% | 1 | 2 |
| sample | 20.2 | 3 | 311,880 | 304,527 | 304,470 | 4,515 | 97.64% | 97.62% | 2 | 2 |
| sample | 30.3 | 4 | 192,640 | 195,112 | 195,060 | 0 | 101.28% | 101.25% | 3 | 2 |
| off | 30.3 | 4 | 192,640 | 195,112 | 195,060 | 0 | 101.28% | 101.25% | 3 | 0 |

Off split from 5s live samples:

| interval | local_pte | refault | hit | lost | promote | demote | hint_fault | pte_update |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| <= off | 925,244 | 920,729 | 920,729 | 4,515 | 1,996,824 | 1,643,401 | 8,519,587 | 8,694,569 |
| > off | 590 | 590 | 590 | 0 | 5,926 | 209,151 | 14,051 | 39,263 |
## Window 5s
| event | t(s) | seq | pte | refault | hit | lost | access | fast | consec | nb |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| sample | 5.1 | 2 | 308,199 | 308,199 | 308,199 | 0 | 100.00% | 100.00% | 1 | 2 |
| sample | 10.8 | 3 | 112,381 | 112,381 | 112,384 | 0 | 100.00% | 100.00% | 2 | 2 |
| sample | 15.9 | 4 | 77,021 | 63,614 | 63,614 | 0 | 82.59% | 82.59% | 3 | 2 |
| off | 15.9 | 4 | 77,021 | 63,614 | 63,614 | 0 | 82.59% | 82.59% | 3 | 0 |

Off split from 5s live samples:

| interval | local_pte | refault | hit | lost | promote | demote | hint_fault | pte_update |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| <= off | 504,148 | 490,741 | 490,741 | 0 | 1,054,813 | 692,600 | 5,248,301 | 5,280,629 |
| > off | 0 | 13,407 | 13,407 | 0 | 2 | 289,837 | 13,407 | 0 |
