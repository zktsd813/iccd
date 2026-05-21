# Shared-scan local-util window sweep, 300s

Workload: `stream_read_32g_split16_4kstride_sharedscan`, all 32 BW threads scan the full 32G window. Policy: `adaptive_localutil`, local fault sampling 10%, hit threshold 2000ms, threshold 80%, 3 consecutive windows, min PTE 1000, scan size 256MB, period 1000ms, fast scan off.

Baseline from previous shared-scan run: off `5271.0 MiB/s`, on `517.8 MiB/s`.

## Summary
| window | off_s | final MiB/s | after-off MiB/s | agg Mops/s | thread Mops/s | thread pass/s | promote GiB | demote GiB | hint | PTE |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 5s | 30.5 | 4888.5 | 5055.1 | 640.7 | 20.02 | 2.387 | 2.92 | 1.92 | 6,853,182 | 6,678,656 |
| 10s | 30.9 | 4938.2 | 5082.5 | 647.3 | 20.23 | 2.411 | 2.54 | 1.67 | 6,675,073 | 6,577,180 |
| 20s | 60.5 | 4784.4 | 5203.5 | 627.1 | 19.60 | 2.336 | 4.45 | 3.89 | 11,128,964 | 10,522,791 |

## Off Split From 5s Live Samples
| window | interval | local_pte | refault | hit | lost | promote | demote | hint | PTE |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 5s | <=off | 838,710 | 838,544 | 762,086 | 166 | 749,287 | 502,081 | 6,735,387 | 6,547,584 |
| 5s | >off | 885 | 885 | 885 | 0 | 16,682 | 0 | 117,795 | 131,072 |
| 10s | <=off | 775,466 | 775,466 | 753,366 | 0 | 232,324 | 0 | 5,567,719 | 5,399,013 |
| 10s | >off | 58,713 | 58,713 | 58,713 | 0 | 434,382 | 437,950 | 1,107,354 | 1,178,167 |
| 20s | <=off | 817,295 | 817,295 | 601,026 | 0 | 629,646 | 705,354 | 10,242,682 | 9,953,590 |
| 20s | >off | 60,372 | 60,372 | 60,372 | 0 | 536,131 | 314,880 | 886,282 | 569,201 |

## Notes
- `thread pass/s` uses one full sparse 32G scan = 8,388,608 ops/thread.
- Shared-scan sample medians can be misleading because worker accounting updates after large full-window passes; final average and ops/thread are the stable metrics.
- Short-window ratios can exceed 100% because refault counters are global and can include PTEs armed in the previous window.

## Window 5s
| event | t(s) | seq | pte | refault | hit | lost | access | fast | consec | nb |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| sample | 5.1 | 2 | 294,745 | 292,994 | 292,344 | 0 | 99.40% | 99.18% | 1 | 2 |
| sample | 10.2 | 3 | 112,591 | 117,025 | 117,342 | 0 | 103.93% | 104.21% | 2 | 2 |
| sample | 15.3 | 4 | 20,253 | 4 | 4 | 0 | 0.01% | 0.01% | 0 | 2 |
| sample | 20.4 | 5 | 157,284 | 138,210 | 101,078 | 0 | 87.87% | 64.26% | 1 | 2 |
| sample | 25.4 | 6 | 157,285 | 209,716 | 170,392 | 0 | 133.33% | 108.33% | 2 | 2 |
| sample | 30.5 | 7 | 71,197 | 77,587 | 77,587 | 166 | 108.97% | 108.97% | 3 | 2 |
| off | 30.5 | 7 | 71,197 | 77,587 | 77,587 | 166 | 108.97% | 108.97% | 3 | 0 |

30s throughput:

| interval | mean MiB/s | median MiB/s |
|---|---:|---:|
| 0-30s | 3390.0 | 4416.0 |
| 30-60s | 4981.0 | 5050.9 |
| 60-90s | 5049.9 | 5056.0 |
| 90-120s | 5013.3 | 5063.6 |
| 120-150s | 5177.6 | 5248.0 |
| 150-180s | 5068.8 | 5154.6 |
| 180-210s | 4981.4 | 5088.0 |
| 210-240s | 5079.5 | 5152.0 |
| 240-270s | 5064.5 | 5184.0 |
| 270-300s | 5077.3 | 4960.0 |
## Window 10s
| event | t(s) | seq | pte | refault | hit | lost | access | fast | consec | nb |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| sample | 10.6 | 2 | 406,022 | 406,022 | 406,018 | 0 | 100.00% | 99.99% | 1 | 2 |
| sample | 20.7 | 3 | 199,056 | 199,056 | 176,960 | 0 | 100.00% | 88.89% | 2 | 2 |
| sample | 30.9 | 4 | 229,101 | 229,101 | 229,101 | 0 | 100.00% | 100.00% | 3 | 2 |
| off | 30.9 | 4 | 229,101 | 229,101 | 229,101 | 0 | 100.00% | 100.00% | 3 | 0 |

30s throughput:

| interval | mean MiB/s | median MiB/s |
|---|---:|---:|
| 0-30s | 3639.5 | 4864.0 |
| 30-60s | 5062.4 | 4992.0 |
| 60-90s | 5070.9 | 5122.6 |
| 90-120s | 5134.9 | 5181.4 |
| 120-150s | 5094.4 | 5282.6 |
| 150-180s | 5053.9 | 5021.5 |
| 180-210s | 5083.7 | 5213.4 |
| 210-240s | 5038.8 | 5184.0 |
| 240-270s | 5115.8 | 5216.0 |
| 270-300s | 5088.0 | 5184.0 |
## Window 20s
| event | t(s) | seq | pte | refault | hit | lost | access | fast | consec | nb |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| sample | 20.1 | 2 | 414,937 | 414,937 | 257,651 | 0 | 100.00% | 62.09% | 1 | 2 |
| sample | 40.3 | 3 | 153,316 | 153,316 | 94,333 | 0 | 100.00% | 61.52% | 2 | 2 |
| sample | 60.5 | 4 | 309,413 | 309,413 | 309,413 | 0 | 100.00% | 100.00% | 3 | 2 |
| off | 60.5 | 4 | 309,413 | 309,413 | 309,413 | 0 | 100.00% | 100.00% | 3 | 0 |

30s throughput:

| interval | mean MiB/s | median MiB/s |
|---|---:|---:|
| 0-30s | 2272.0 | 1024.0 |
| 30-60s | 3944.4 | 4800.0 |
| 60-90s | 5166.9 | 5248.0 |
| 90-120s | 5265.1 | 5344.0 |
| 120-150s | 5156.3 | 5183.9 |
| 150-180s | 5192.5 | 5248.0 |
| 180-210s | 5299.2 | 5248.0 |
| 210-240s | 5158.4 | 5344.0 |
| 240-270s | 5222.4 | 5181.4 |
| 270-300s | 5166.9 | 5344.0 |
