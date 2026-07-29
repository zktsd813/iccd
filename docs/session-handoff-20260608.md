# Session Handoff - 2026-06-08

This handoff records the 2-NUMA DRAM/CXL motivation experiment completion,
plotting updates, and script fixes made after the 2026-06-07 handoff. Start a
future session by reading:

- `docs/session-handoff-20260601.md`
- `docs/session-handoff-20260605.md`
- `docs/session-handoff-20260607.md`
- this file

## Current Stop State

The active 2-NUMA run is complete.

- Run ID: `numa-local8-16-32-20260607T061436Z`
- Run root:
  `motivation/numa/results/numa-local8-16-32-20260607T061436Z`
- Progress file:
  `motivation/numa/results/numa-local8-16-32-20260607T061436Z/state/progress.txt`
- Final progress:
  - `progress=96/96`
  - `state=complete`
  - final case: `local32/tpp/dlrm_synth`
  - final detail: `rc=0`
  - updated: `2026-06-07T23:14:56Z`

No real `run_numa_sweep.sh` or `run_numa_case.sh` runner process remained when
checked. A tmux server is still alive with session name `0`; it only holds the
old progress pane. The tmux server command line still contains the old sweep
command, so broad `pgrep run_numa_sweep` can produce a false positive. Use a
stricter process check before concluding that an experiment is running.

## Experiment Matrix Used For Plots

The user asked to exclude the failed/problematic `4+4` local8 cases. The
current plots use only the completed `16G` and `32G` local-size plan:

- Workloads: `pr`, `bc`, `gups`, `graph500`, `btree`, `redis_uniform`,
  `redis_ycsb_a`, `rocksdb_ycsb_uniform`, `memcached_ycsb_uniform`,
  `faster_uniform`, `faster_ycsb_a`, `dlrm_synth`
- Policies:
  - controls: `all_dram`, `all_cxl`
  - local16: `migration_off`, `migration_on`, `tpp`
  - local32: `migration_off`, `migration_on`, `tpp`
- Plotted rows: `96`
- Local8 rows are intentionally excluded from plot input.

There were old local8 successes and one failed local8 row in the raw summary,
but they should not be used for the current figure set.

## Result Artifacts

Primary generated graph directory:

- `motivation/numa/graphs/numa-local8-16-32-20260607T061436Z`

Important files:

- `graph_summary.md`
- `plot_input.csv`
- `execution_time_16g_seconds.png`
- `execution_time_32g_seconds.png`
- `off_relative_performance_delta.csv`
- `promotion_plus_demotion_gib_heatmap.png`
- `max_tree_rss_gib_heatmap.png`
- `dram_free_before_case_gib_heatmap.png`
- `cxl_residency_fraction_heatmap.png`
- `rocksdb_memory_note.md`

Copies placed under `experiments/figure/`:

- `numa_2node_execution_time_16g_seconds.png`
- `numa_2node_execution_time_32g_seconds.png`
- `numa_2node_promotion_plus_demotion_gib_heatmap.png`

Current graph conventions:

- Execution-time graphs use raw `elapsed_s`; lower is better.
- They are not normalized.
- `on` and `tpp` bars are annotated with performance delta vs `off`, computed
  as `off_elapsed / policy_elapsed - 1`.
- `+` means faster than `migration_off`; `-` means slower.
- Promotion/demotion heatmap annotation text is forced to black.

Mean off-relative deltas from `off_relative_performance_delta.csv`:

- `16G`: `migration_on` average `-3.5%`, `tpp` average `-5.6%`
- `32G`: `migration_on` average `-10.8%`, `tpp` average `-13.4%`

These are arithmetic averages of per-workload percentage labels, not geomeans.

## Target-Window Caveats

The current plot input has target-window misses. This matters for
interpretation:

- `local16 migration_off`: `7/12` within target window
- `local16 migration_on`: `11/12`
- `local16 tpp`: `9/12`
- `local32 migration_off`: `12/12`
- `local32 migration_on`: `10/12`
- `local32 tpp`: `7/12`

The most visible anomaly is `btree` under `migration_on`:

- `16G/on`: expected roughly `8G+8G`, actual before-workload DRAM free was
  `20.54G + 10.93G = 31.47G`, `target_window_ok=0`
- `32G/on`: expected roughly `16G+16G`, actual before-workload DRAM free was
  `28.50G + 16.94G = 45.43G`, `target_window_ok=0`

Analysis: this is not a btree workload property. The previous `graph500` case
left large anonymous memory behind; memory target setup started before that
memory was fully reclaimed. During node1 hotplug targeting, node0 free rose
after node0 had already passed the target check. The old target code did not
revalidate all DRAM nodes after sequential node targeting.

Relevant logs:

- `motivation/numa/results/numa-local8-16-32-20260607T061436Z/numa-logs/memory-target.log`
  around lines `3550-3595`
- `state/target-after-local16__migration_on__btree.txt`
- `state/target-after-local32__migration_on__btree.txt`

## RocksDB RSS Caveat

`rocksdb_ycsb_uniform` Max RSS is low by design/measurement definition.

- `max_tree_rss`: about `1.84-1.94 GiB`
- node-used delta proxy: about `73.9-76.8 GiB`

Reason: RocksDB writes its DB into `/dev/shm/rocksdb-data-rss60`. The large DB
footprint is tmpfs/page-cache/shmem memory, not process RSS. Existing runs did
not sample cgroup `memory.current`, so the best footprint proxy for this run is
node-used delta. See:

- `motivation/numa/graphs/numa-local8-16-32-20260607T061436Z/rocksdb_memory_note.md`

## Script Changes

New NUMA experiment files are under `motivation/numa/`; the directory is still
untracked in git at handoff time.

Important script files:

- `motivation/numa/scripts/run_numa_sweep.sh`
- `motivation/numa/scripts/run_numa_sweep_tmux.sh`
- `motivation/numa/scripts/run_numa_case.sh`
- `motivation/numa/scripts/numa_memory_target.sh`
- `motivation/numa/scripts/numa_resource_guard.sh`
- `motivation/numa/scripts/summarize_numa_results.py`
- `motivation/numa/scripts/plot_numa_results.py`

Memory-settle fix:

- `numa_memory_target.sh` now has `host_memory_wait_for_reclaim_settle`.
- `run_numa_sweep.sh` calls it before each case setup when
  `HOST_MEMORY_SETTLE_BEFORE_SETUP=1`.
- Default settle scope is `HOST_MEMORY_SETTLE_NODES="${DRAM_NODES} ${CXL_NODES}"`.
- The wait checks total `AnonPages`, `MemFree` stability, and records
  `state/reclaim-settle-<case>.csv`.
- If settle times out and `HOST_MEMORY_SETTLE_REQUIRED=1`, the case fails
  through the same reboot/retry path.
- `numa_memory_target.sh` also now revalidates the full DRAM target after
  sequential node targeting and repeats up to
  `HOST_MEMORY_TARGET_VERIFY_PASSES`.
- `run_numa_sweep_tmux.sh` persists these new variables into tmux/reboot
  resume environments.

Future RSS/cgroup fix:

- `run_numa_case.sh` now samples `cgroup_memory_current_kb` in
  `memory_samples.csv`.
- `summarize_numa_results.py` now emits `max_cgroup_memory_kb`.
- `run_numa_case.sh` also fixes the `memory_samples.csv` formatting bug where
  node memory triplets were emitted as comma-containing arguments, creating
  extra trailing unnamed columns.

Plotting changes:

- `plot_numa_results.py` generates execution-time graphs for 16G and 32G.
- It writes `off_relative_performance_delta.csv`.
- It regenerates `promotion_plus_demotion_gib_heatmap.png` with black numeric
  annotations.
- It no longer relies on geomean performance as the primary figure.

Verification used after script edits:

```bash
bash -n motivation/numa/scripts/numa_memory_target.sh
bash -n motivation/numa/scripts/run_numa_sweep.sh
bash -n motivation/numa/scripts/run_numa_sweep_tmux.sh
bash -n motivation/numa/scripts/run_numa_case.sh
python3 -m py_compile motivation/numa/scripts/plot_numa_results.py
python3 -m py_compile motivation/numa/scripts/summarize_numa_results.py
DRY_RUN=1 RUN_ID=codex-dryrun-settle RUN_ROOT=/tmp/codex-dryrun-settle \
  LOCAL_SIZES='16 32' CONFIGS='migration_on' WORKLOADS='graph500 btree' \
  motivation/numa/scripts/run_numa_sweep.sh
```

The dry-run printed a 4-case graph500/btree migration_on plan and showed the
new settle configuration.

## Worktree Notes

The worktree is intentionally dirty and contains unrelated changes from older
kernel/host work. Do not reset or delete generated outputs unless the user
explicitly asks.

At handoff time, relevant untracked paths included:

- `motivation/numa/`
- `experiments/figure/numa_2node_execution_time_16g_seconds.png`
- `experiments/figure/numa_2node_execution_time_32g_seconds.png`
- `experiments/figure/numa_2node_promotion_plus_demotion_gib_heatmap.png`

Existing unrelated dirty paths included:

- `docs/iccd-experiment-protocol-20260601.md`
- `scripts/run_ours_experiment.sh`
- `scripts/run_workload_case_guest.sh`
- `scripts/run_workload_suite_guest.sh`
- `scripts/stage_workloads_to_vm.sh`

## Recommended Next Steps

If the next session wants clean final NUMA results, rerun only the affected
target-window-miss cases after the settle/revalidate fixes. The strongest
candidate reruns are:

- `btree` under `migration_on` for `16G` and `32G`
- any rows with `target_window_ok=0` in `plot_input.csv`
- `rocksdb_ycsb_uniform` if cgroup memory footprint should be reported instead
  of node-used proxy

Use a fresh `RUN_ID` or archive/rerun ID. Preserve completed successful cases
unless the user explicitly asks for a full rerun.
