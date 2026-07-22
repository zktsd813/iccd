# Local16 fault-overhead evaluation

Source run: `/Serverless/iccd-git/submission_socc/final_experiments/runs/20260714T230038Z-eval4-fault-overhead-local16`

This run keeps NUMA balancing/protected-state sampling active while disabling migration:
`numa_balancing=2`, `migration_enabled=0`, `local_fault_scan_size_mb=64`, `local_fault_scan_period_ms=1000`, `demotion_enabled=false`.

`summary.csv` compares this mode against the local16 migration-off baseline from `evaluation_2_realworld/summary.csv`.
