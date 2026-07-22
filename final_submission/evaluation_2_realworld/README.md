# Evaluation 2 Realworld

Scope: existing realworld VM results only. No new experiment is run by the packaging script.

Local memory sizes: 16, 32, 48 GiB
Workloads: pr, bc, gups, btree, graph500, silo
Policies: off, on, tpp, ours

Final selected design for `ours`: `capacity_rank_latency_local_remote_restart_v3`.
Sanity anchor: local16/bc/ours elapsed_s=682.95.


Top-level files:

- `summary.csv`: compact per-case result table with elapsed time, promotion, demotion, and source paths.
- `source_map.csv`: copied artifact provenance.
- `figure/`: elapsed, normalized elapsed, and migration-volume figures.
- `raw/`: copied raw per-case artifacts including workload stdout, run config, host logs, VM config logs, and controller logs where applicable.
- `scripts/`: archived scripts/manifests used by the selected runs plus this packaging script.
- `workload_stdout/`, `vm_configs/`: convenience copies indexed by local/policy/workload.
