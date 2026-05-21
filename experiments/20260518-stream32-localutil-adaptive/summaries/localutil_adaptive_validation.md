# stream32 localutil adaptive validation
## Result
- run: `20260518T061350Z-stream32-localutil-adaptive`
- kernel: 6.18.0modified #174
- workload: `stream_read_32g_split16_4kstride`, policy `adaptive_localutil`
- scan: 256MB, period min 1000ms, fast scan off
- local fault: rate 10%, hit threshold 2000ms
- controller: 10s window, threshold 80%, consecutive 3, min pte updates 1000
- migration off event: no
- reason not off: third qualifying window failed `min_pte_updates=1000`; utilization stayed high but pte delta collapsed after the first scan.
- throughput mean/median: 1861.7/1845.0 MiB/s
- total local pte/hit/refault/lost: 422,175 / 422,175 / 422,175 / 0
- total promoted/demoted: 7,954,486 / 7,637,717 pages = 30.34 / 29.14 GiB

## Controller 10s windows
| t(s) | pte_delta | hit_delta | util | consec | node_balancing |
|---:|---:|---:|---:|---:|---:|
| 10.1 | 420,343 | 420,383 | 100.00% | 1 | 2 |
| 20.2 | 1,459 | 1,419 | 97.25% | 2 | 2 |
| 30.2 | 257 | 257 | 100.00% | 0 | 2 |
| 40.3 | 14 | 14 | 100.00% | 0 | 2 |
| 50.4 | 0 | 0 | 0.00% | 0 | 2 |
| 60.5 | 39 | 39 | 100.00% | 0 | 2 |
| 70.6 | 1 | 1 | 100.00% | 0 | 2 |
| 80.6 | 3 | 3 | 100.00% | 0 | 2 |
| 90.7 | 0 | 0 | 0.00% | 0 | 2 |
| 100.7 | 2 | 2 | 100.00% | 0 | 2 |
| 110.8 | 51 | 51 | 100.00% | 0 | 2 |
| 120.9 | 0 | 0 | 0.00% | 0 | 2 |
| 130.9 | 6 | 6 | 100.00% | 0 | 2 |
| 141.0 | 0 | 0 | 0.00% | 0 | 2 |
| 151.0 | 0 | 0 | 0.00% | 0 | 2 |
| 161.0 | 0 | 0 | 0.00% | 0 | 2 |
| 171.1 | 0 | 0 | 0.00% | 0 | 2 |
| 181.2 | 0 | 0 | 0.00% | 0 | 2 |
| 191.2 | 0 | 0 | 0.00% | 0 | 2 |
| 201.3 | 0 | 0 | 0.00% | 0 | 2 |

## Files
- `summaries/localutil_controller_10s.csv`
- `summaries/localfault_live_5s.csv`
- raw case dir under `qemu-logs/phase_candidate_microbench/20260518T061350Z-stream32-localutil-adaptive/...`
