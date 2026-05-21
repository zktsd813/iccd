# Windowed local-util adaptive validation

## Configuration
- run: `20260518T064324Z-stream32-localutil-windowed`
- workload: `stream_read_32g_split16_4kstride`
- policy: `adaptive_localutil` with window advance
- scan: 256MB, period min 1000ms, fast scan off
- local fault sampling: 10%, refault hit threshold 2000ms
- controller: 70s window, access threshold 80%, 3 consecutive windows, min pte updates 1000
- metric: `access_pct = delta(numa_local_fault_refault) / delta(numa_local_fault_pte_updates)`
- secondary: `fast_pct = delta(numa_local_fault_refault_hit) / delta(numa_local_fault_pte_updates)`

## Result
- migration off event: yes
- off elapsed: 210.9s, window 3, window_seq 4
- total local pte/refault/hit/lost: 1,279,071 / 1,195,249 / 1,195,035 / 83,822
- total promoted/demoted: 7,694,333 / 7,399,298 pages = 29.35 / 28.23 GiB
- throughput steady mean/median: 1753.5 / 1786.0 MiB/s

## Controller Windows
| event | t(s) | seq | pte | refault | hit | lost | access | fast | consec | nb |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| sample | 70.3 | 2 | 422,217 | 422,217 | 422,217 | 0 | 100.00% | 100.00% | 1 | 2 |
| sample | 140.5 | 3 | 465,439 | 421,086 | 420,878 | 44,353 | 90.47% | 90.42% | 2 | 2 |
| sample | 210.8 | 4 | 391,063 | 351,632 | 351,577 | 38,427 | 89.91% | 89.90% | 3 | 2 |
| off | 210.9 | 4 | 391,063 | 351,632 | 351,577 | 38,427 | 89.91% | 89.90% | 3 | 0 |

## Files
- `summaries/windowed_controller.csv`
- `summaries/windowed_live_5s.csv`
- `summaries/throughput_10s.csv`
