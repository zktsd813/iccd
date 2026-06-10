# VM32 Real-World Motivation Experiment

This experiment runs the real-world/candidate workload suite inside a 2-node VM:

- VM node0: 32 vCPUs, fast DRAM backed by host NUMA node0.
- VM node1: CPU-less 128G slow memory backed by host CXL NUMA node2.
- Host SMT is disabled before the run and restored on exit by default.

Default sweep:

- Local fast memory: `16G`, `32G`, `48G`.
- Policies: `migration_off`, `tiering_0x2`, `tpp_0x4`.
- Workloads: `pr`, `bc`, `gups`, `graph500`, `btree`, `redis_uniform`,
  `redis_ycsb_a`, `faster_uniform`, `faster_ycsb_a`, `silo`, `liblinear`.
- PR/BC trials: `8`.

Run a dry-run matrix check:

```bash
DRY_RUN=1 motivation/3_realworld/VM/scripts/run_vm_sweep_host.sh
```

Run in tmux:

```bash
motivation/3_realworld/VM/scripts/run_vm_sweep_tmux.sh
```

Run the fault-bucket controller sweep requested for vm32:

```bash
DRY_RUN=1 CONFIGS=controller_0x2 LOCAL_SIZES_GIB="16 32 48" WORKLOADS=all \
  motivation/3_realworld/VM/scripts/run_vm_sweep_host.sh

motivation/3_realworld/VM/scripts/run_vm_controller_tmux.sh
```

The controller sweep runs `controller_0x2` for 11 workloads across local
memory sizes `16G`, `32G`, and `48G`. Each case stores the controller trace at
`controller/controller.csv` under the workload result directory.

Results are written under `results/<run-id>/`.

Canonical combined outputs:

- `summaries/vm32_realworld_combined_summary.csv`: prior local-size vm32
  sweep plus the 118G all-local/all-slow controls.
- `summaries/vm32_realworld_combined_summary.md`: compact row counts,
  included raw runs, and 118G control elapsed-time table.
- `summaries/vm32_realworld_elapsed_matrix.csv`: elapsed-time matrix for
  spreadsheet/plot use.
- `graphs/vm32_realworld_elapsed_seconds_log_with_controls.{pdf,png}`:
  local16/32/48 policies plus 118G all-local/all-slow controls.
- `graphs/vm32_realworld_controls_118_slowdown.{pdf,png}`: all-slow over
  all-local elapsed-time ratio for the 118G controls.

Raw runs currently included in the combined summary:

- `results/20260608T120942Z-guestlocal-progress2-vm32-local16-32-48`
- `results/20260609T_alllocal118_nosilo`
- `results/20260609T_allslow118_nosilo`

The all-local 118G silo OOM archive is preserved inside
`results/20260609T_alllocal118_nosilo/summaries/summary_all_with_silo_oom.csv`;
it is not included in the no-silo control comparison.
