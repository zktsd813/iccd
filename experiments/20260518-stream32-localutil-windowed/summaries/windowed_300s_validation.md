# Windowed local-util adaptive validation, 300s workload

## Configuration
- run: `20260518T065500Z-stream32-localutil-windowed-300s`
- workload: `stream_read_32g_split16_4kstride`, forced duration 300s
- policy: `adaptive_localutil` with per-window `memory.numa_local_fault_window` advance
- scan: 256MB, period min 1000ms, fast scan off
- local fault sampling: 10%, hit threshold 2000ms
- controller: 70s window, access threshold 80%, 3 consecutive windows, min pte updates 1000
- access metric: `delta(local_fault_refault) / delta(local_fault_pte_updates)`
- fast metric: `delta(local_fault_refault_hit) / delta(local_fault_pte_updates)`

## Result
- migration off event: yes
- off elapsed: 211.7s, window 3, window_seq 4
- total local pte/refault/hit/lost: 1,261,713 / 1,196,158 / 1,194,768 / 65,555
- total promoted/demoted: 7,509,814 / 7,353,707 pages = 28.65 / 28.05 GiB
- throughput steady mean/median: 1589.3 / 1426.0 MiB/s
- throughput mean before/after off: 1719.2 / 1342.2 MiB/s

## Controller Windows
| event | t(s) | seq | pte | refault | hit | lost | access | fast | consec | nb |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| sample | 71.2 | 2 | 422,177 | 422,177 | 422,177 | 0 | 100.00% | 100.00% | 1 | 2 |
| sample | 141.4 | 3 | 458,078 | 416,476 | 415,086 | 36,358 | 90.91% | 90.61% | 2 | 2 |
| sample | 211.6 | 4 | 381,378 | 350,750 | 350,770 | 29,197 | 91.96% | 91.97% | 3 | 2 |
| off | 211.7 | 4 | 381,378 | 350,750 | 350,770 | 29,197 | 91.96% | 91.97% | 3 | 0 |

## Off Split From 5s Live Samples
| interval | local_pte | local_refault | local_hit | local_lost | promote | demote | hint_fault | pte_update |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| <= off | 1,241,105 | 1,173,336 | 1,171,946 | 65,513 | 7,323,092 | 6,975,269 | 21,282,435 | 21,340,973 |
| > off | 20,608 | 22,822 | 22,822 | 42 | 186,722 | 378,438 | 436,950 | 406,007 |

## Files
- `summaries/windowed_300s_controller.csv`
- `summaries/windowed_300s_live_5s.csv`
- `summaries/windowed_300s_throughput_10s.csv`
