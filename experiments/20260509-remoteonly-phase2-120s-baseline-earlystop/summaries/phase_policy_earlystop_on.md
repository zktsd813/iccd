# Phase policy table with earlystop-on only

This view uses:

- `off`, `on`, `adaptive`: baseline run
  `20260509T0518Z-remoteonly-phase2-120s-baseline`
- `earlystop(on)`: diagnostic run
  `20260509T0532Z-remoteonly-phase2-120s-earlystop-pingpong`, policy `on`

The earlystop column is therefore migration-on plus
`NUMA_MIGRATION_STOP_ENABLED=1` and `NUMA_PINGPONG_STAT_ENABLED=1`.

## Phase Throughput

| phase | kind | off | on | adaptive | earlystop(on) | unit |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| 1 | friendly | 228.58 | 272.19 | 269.67 | 258.93 | Mops/s |
| 2 | unfriendly | 4513.00 | 2197.60 | 4199.70 | 2320.15 | MB/s |

## Phase Counters

| policy | phase | hint faults | promotions |
| --- | ---: | ---: | ---: |
| off | 1 | 0 | 0 |
| off | 2 | 0 | 0 |
| on | 1 | 10623217 | 1846272 |
| on | 2 | 9486696 | 2199556 |
| adaptive | 1 | 10475772 | 1826651 |
| adaptive | 2 | 2295452 | 0 |
| earlystop(on) | 1 | 8291797 | 936098 |
| earlystop(on) | 2 | 11637432 | 2116977 |

## Earlystop Timeline

The actual stop is inferred from `cg_earlystop_running` changing from `1` to
`0` in the live samples.

| elapsed | phase | relative to phase | state |
| ---: | --- | ---: | --- |
| 35.198s | P1 friendly | 35.198s | `earlystop_cnt=1` |
| 37.269s | P1 friendly | 37.269s | `earlystop_cnt=2` |
| 39.342s | P1 friendly | 39.342s | `earlystop_cnt=3` |
| 41.413s | P1 friendly | 41.413s | `earlystop_cnt=4` |
| 43.485s | P1 friendly | 43.485s | `earlystop_cnt=5` |
| 45.558s | P1 friendly | 45.558s | `earlystop_cnt=6` |
| 47.631s | P1 friendly | 47.631s | `earlystop_cnt=7` |
| 49.702s | P1 friendly | 49.702s | stopped: `earlystop_running 1 -> 0` |
| 106.596s | P1 friendly | 106.596s | restart check begins: `restart_cnt=1` |
| 125.156s | P2 unfriendly | 5.151s | restarted: `earlystop_running 0 -> 1` |

After P2 finished, `earlystop_cnt` rose to 3, 4, and 5 at 240.168s, 242.286s,
and 244.411s elapsed. That is after the measured 120s P2 window, so there was
no second stop during measured P2.

## Short Read

- `earlystop(on)` improves P2 over full `on`: `2320.15` vs `2197.60 MB/s`.
- It is still far below `adaptive` on P2: `2320.15` vs `4199.70 MB/s`.
- The tradeoff is visible in P1: `earlystop(on)` has less promotion and lower
  friendly throughput than full `on`.
