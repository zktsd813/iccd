# Fixed8G Friendly -> Unfriendly Early Stop Diagnostic

## Setup
- candidate: `phase_fixed8g_remote_split32_stream4k_localft`
- phases: 60s fixed 8G remote friendly (`16G..24G`) -> 60s split32 stream unfriendly
- policies: `off,on,adaptive_cgroup`
- scan: `NUMA_SCAN_SIZE_MB=256`, `NUMA_SCAN_PERIOD_MIN_MS=1000`, `NUMA_FAST_SCAN=0`
- early stop knobs: `NUMA_MIGRATION_STOP_ENABLED=1`, `NUMA_PINGPONG_STAT_ENABLED=1`
- live sample interval: 1s; kernel earlystop daemon checks every 2s
- kernel: `Linux kernel 6.18.0modified #163 SMP PREEMPT_DYNAMIC Sat May  9 12:53:28 UTC 2026`
- MGLRU: `0x0007`

## Result
Actual early stop did not fire in this 120s run. In the `on` run, `cg_migration_stop_effective` stayed 1 and `cg_earlystop_running` stayed 1 for all effective samples, so there was no `running 1->0` transition and no restart. The early-stop detector did see some ping-pong signal in phase 2: `cg_earlystop_current_demote_promoted` rose to 1,482,686 pages, but `cg_earlystop_cnt` only reached 2 and then fell back to 0. The kernel stop path requires the counter to reach 8, so migration kept running.

For `adaptive_cgroup`, early stop was effective during phase 1. At phase 2 the adaptive controller disabled cgroup node balancing, so `cg_migration_stop_effective` switched 1->0 at the first live sample after the phase boundary: elapsed 60.745s, about 0.745s into phase 2. That is policy-driven disable, not early stop.

## Stop Overview
| policy | effective samples | stop observed | first stop ms | running=0 effective samples | max current demote-promoted | max current ms | max cnt | max cnt ms | restart final |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| off | 0 | no |  | 0 | 0 | 50 | 0 | 50 | 0 |
| on | 121 | no |  | 0 | 1482686 | 123090 | 2 | 92010 | 0 |
| adaptive_cgroup | 59 | no |  | 0 | 0 | 60 | 0 | 60 | 0 |

## Phase Summary
| policy | phase | phase name | throughput | hint faults | PTE updates | promoted GiB | demoted GiB | demote-promoted pages | promote-candidate-demoted pages |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| off | 1 | fixed8g-hotset-remote | 227.16 Mops/s | 0 | 0 | 0.00 | 0.00 | 0 | 0 |
| off | 2 | stream-read-32g-split16-4k | 4505.50 MB/s | 0 | 0 | 0.00 | 0.00 | 0 | 0 |
| on | 1 | fixed8g-hotset-remote | 1197.10 Mops/s | 4136238 | 16424065 | 8.00 | 7.47 | 58 | 64 |
| on | 2 | stream-read-32g-split16-4k | 3633.33 MB/s | 13298051 | 12820791 | 8.36 | 7.88 | 983303 | 1519394 |
| adaptive_cgroup | 1 | fixed8g-hotset-remote | 1196.61 Mops/s | 4120318 | 16409115 | 8.00 | 7.48 | 0 | 6 |
| adaptive_cgroup | 2 | stream-read-32g-split16-4k | 4468.93 MB/s | 0 | 0 | 0.00 | 0.00 | 0 | 0 |

## Detected Transitions
| policy | event | prev ms | ms | phase-rel ms | change | current demote-promoted | cnt | hint delta | PTE delta | promote delta | demote delta |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| on | earlystop_cnt_transition | 87867 | 88894 | 28894 | 0->1 | 301182 | 1 | 0 | 0 | 0 | 0 |
| on | earlystop_cnt_transition | 90978 | 92010 | 32010 | 1->2 | 359451 | 2 | 170552 | 264279 | 36961 | 44415 |
| on | earlystop_cnt_transition | 93037 | 94059 | 34059 | 2->1 | 418215 | 1 | 151228 | 77081 | 29822 | 23855 |
| on | earlystop_cnt_transition | 99273 | 100328 | 40328 | 1->0 | 521467 | 0 | 163544 | 342855 | 15362 | 15362 |
| on | earlystop_cnt_transition | 105513 | 106542 | 46542 | 0->1 | 732990 | 1 | 293374 | 258952 | 51078 | 51078 |
| on | earlystop_cnt_transition | 107580 | 108606 | 48606 | 1->2 | 808400 | 2 | 343185 | 219763 | 50260 | 45331 |
| on | earlystop_cnt_transition | 109653 | 110683 | 50683 | 2->1 | 921383 | 1 | 440352 | 198656 | 79927 | 93336 |
| on | earlystop_cnt_transition | 115815 | 116835 | 56835 | 1->0 | 982961 | 0 | 2 | 2 | 2 | 0 |
| adaptive_cgroup | effective_transition | 59723 | 60745 | 745 | 1->0 | 0 | 0 | 1574383 | 81362 | 0 | 0 |

## Focus Timeline
| policy | window | phase | run start | run end | current start | current end | cnt start | cnt end | hint delta | PTE delta | promote delta | demote delta |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| on | 80-90s | 2 | 1 | 1 | 38349 | 301182 | 0 | 1 | 2309405 | 1852760 | 236022 | 262833 |
| on | 90-100s | 2 | 1 | 1 | 301182 | 521467 | 1 | 0 | 1625722 | 1945536 | 296958 | 270135 |
| on | 100-110s | 2 | 1 | 1 | 521467 | 828112 | 0 | 2 | 2057311 | 2027173 | 306526 | 306584 |
| on | 110-120s | 2 | 1 | 1 | 828112 | 983361 | 2 | 0 | 607838 | 198661 | 93400 | 155456 |
| adaptive_cgroup | 50-60s | 1 | 1 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| adaptive_cgroup | 60-70s | 2 | 1 | 1 | 0 | 0 | 0 | 0 | 1574383 | 81362 | 0 | 0 |
| adaptive_cgroup | 70-80s | 2 | 1 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

## Files
- `phase_summary.csv`: throughput and phase-window migration counters
- `earlystop_overview.csv`: stop/restart overview per policy
- `earlystop_events.csv`: all detected `effective`, `running`, `earlystop_cnt`, `restart_cnt` transitions
- `earlystop_timeline.csv`: full 1s live timeline with deltas
- `earlystop_10s.csv`: 10s aggregate timeline
