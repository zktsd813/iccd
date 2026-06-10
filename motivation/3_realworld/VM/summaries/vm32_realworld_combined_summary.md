# VM32 Realworld Combined Results

Generated: 2026-06-09

## Included Raw Runs
- `vm32_local16_32_48`: `/Serverless/iccd-git/motivation/3_realworld/VM/results/20260608T120942Z-guestlocal-progress2-vm32-local16-32-48`
- `control_all_local_118_nosilo`: `/Serverless/iccd-git/motivation/3_realworld/VM/results/20260609T_alllocal118_nosilo`
- `control_all_slow_118_nosilo`: `/Serverless/iccd-git/motivation/3_realworld/VM/results/20260609T_allslow118_nosilo`

## Scope
- Combined rows: 119
- Failures in combined rows: 0
- Main vm32 rows: 99 (local sizes 16/32/48 GiB, configs migration_off/tiering_0x2/tpp_0x4)
- Control rows: 20 (118 GiB, all_local/all_slow, no silo)
- `silo` is present in the prior local16/32/48 vm32 run, but excluded from the new 118 GiB all_local/all_slow controls because all_local+silo OOMed. The failed OOM archive remains under `20260609T_alllocal118_nosilo/summaries/summary_all_with_silo_oom.csv`.

## Output Files
- `summaries/vm32_realworld_combined_summary.csv`
- `summaries/vm32_realworld_controls_118_summary.csv`
- `summaries/vm32_realworld_main_local16_32_48_summary.csv`
- `summaries/vm32_realworld_elapsed_matrix.csv`
- `summaries/vm32_realworld_controls_118_elapsed_ratio.csv`

## Workloads
- Combined: bc, btree, faster_uniform, faster_ycsb_a, graph500, gups, liblinear, pr, redis_uniform, redis_ycsb_a, silo
- 118 GiB controls: bc, btree, faster_uniform, faster_ycsb_a, graph500, gups, liblinear, pr, redis_uniform, redis_ycsb_a

## Row Counts
| Suite | Source Run | Rows |
| --- | --- | ---: |
| control_118 | control_all_local_118_nosilo | 10 |
| control_118 | control_all_slow_118_nosilo | 10 |
| main_vm32 | vm32_local16_32_48 | 99 |

## 118 GiB Control Elapsed Time
| Workload | all_local s | all_slow s | slow/local |
| --- | ---: | ---: | ---: |
| bc | 225 | 990 | 4.40 |
| btree | 443 | 1164 | 2.63 |
| faster_uniform | 286 | 294 | 1.03 |
| faster_ycsb_a | 279 | 286 | 1.03 |
| graph500 | 225 | 388 | 1.72 |
| gups | 279 | 746 | 2.67 |
| liblinear | 162 | 314 | 1.94 |
| pr | 420 | 1718 | 4.09 |
| redis_uniform | 178 | 217 | 1.22 |
| redis_ycsb_a | 278 | 379 | 1.36 |

## Config Counts
| Config | Rows |
| --- | ---: |
| all_local | 10 |
| all_slow | 10 |
| migration_off | 33 |
| tiering_0x2 | 33 |
| tpp_0x4 | 33 |

## Local Size Counts
| Local GiB | Rows |
| ---: | ---: |
| 16 | 33 |
| 32 | 33 |
| 48 | 33 |
| 118 | 20 |

