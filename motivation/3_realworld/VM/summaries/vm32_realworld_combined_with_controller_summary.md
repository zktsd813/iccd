# VM32 Combined Results With Controller

Generated: 2026-06-10T02:18:06Z

## Included Raw Runs
- Previous combined: `/Serverless/iccd-git/motivation/3_realworld/VM/summaries/vm32_realworld_combined_summary.csv`
- Controller run: `/Serverless/iccd-git/motivation/3_realworld/VM/results/20260609T173739Z-vm32-controller-local16-32-48/summaries/summary.csv`

## Scope
- Combined rows: 152
- Failures in combined rows: 0
- Main vm32 configs: `migration_off`, `tiering_0x2`, `tpp_0x4`, `controller_0x2` at local sizes 16/32/48 GiB
- Previous 118 GiB controls retained: `all_local`, `all_slow` (no silo)

## Output Files
- `summaries/vm32_realworld_combined_with_controller_summary.csv`
- `summaries/vm32_realworld_elapsed_matrix_with_controller.csv`
- `summaries/vm32_realworld_speedup_vs_off_with_controller.csv`
- `graphs/vm32_realworld_elapsed_seconds_log_with_controller_and_controls.png`
- `graphs/vm32_realworld_elapsed_seconds_log_with_controller_and_controls.pdf`
- `graphs/vm32_realworld_speedup_vs_off_with_controller.png`
- `graphs/vm32_realworld_speedup_vs_off_with_controller.pdf`
- `graphs/vm32_controller_events_by_workload.png`
- `graphs/vm32_controller_events_by_workload.pdf`

## Controller Speedup vs migration_off
| Local GiB | Geomean | Min | Max |
| ---: | ---: | ---: | ---: |
| 16 | 1.022 | 0.775 | 1.314 |
| 32 | 0.937 | 0.586 | 1.252 |
| 48 | 1.002 | 0.735 | 1.755 |

## Config Counts
| Config | Rows |
| --- | ---: |
| migration_off | 33 |
| tiering_0x2 | 33 |
| tpp_0x4 | 33 |
| controller_0x2 | 33 |
| all_local | 10 |
| all_slow | 10 |
