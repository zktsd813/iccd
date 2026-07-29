# Session Handoff - 2026-06-05

This is the current handoff after the memory-tiering, TPP, local-size sweep,
no-MGLRU diagnostic, and reclaim-state analysis work. Start a new session by
reading `docs/session-handoff-20260601.md` for repo/submodule basics, then this
file for the current state.

## Workspace State

- Repo root: `/Serverless/iccd-git`
- Branch: `main`
- Current HEAD: `9c867100147e619310d3f92594a620221c6c37ab`
- VM submodule: `VM` at `aaf4904b5376507f1316666167a2639e01cec2f9`
- Active kernel source: `/Serverless/iccd-git/linux`
- Active kernel build: `/Serverless/iccd-git/linux-global-build`
- Experiment kernel image: `/Serverless/iccd-git/linux-global-build/arch/x86/boot/bzImage`

The worktree is intentionally dirty. Do not reset it. Important modified files
include:

- `.codex/skills/migration-friendly-kernel/SKILL.md`
- `docs/iccd-experiment-protocol-20260601.md`
- `linux/include/linux/sched/sysctl.h`
- `linux/kernel/sched/core.c`
- `linux/kernel/sched/debug.c`
- `linux/kernel/sched/fair.c`
- `linux/mm/memory-tiers.c`
- `linux/mm/vmscan.c`
- `linux/mm/vmstat.c`
- `linux/include/linux/vm_event_item.h`
- `scripts/run_ours_experiment.sh`
- `scripts/run_workload_suite_guest.sh`
- `scripts/stage_workloads_to_vm.sh`
- `motivation/`

There are also unrelated/generated kernel artifacts under `linux/arch/sh/...`
and many untracked experiment outputs. Do not delete or revert anything unless
the user explicitly asks.

## Protocol Updates

Current experiment protocol points:

- Use only `/Serverless/iccd-git`; do not use `/Serverless/iccd`.
- Use `SLOW_MEMORY_MODE=host-cxl`.
- Bind guest node0 fast memory to host node0 and guest node1 slow memory to
  host node2 for migration experiments.
- Run workloads with `numactl --cpunodebind=0`.
- Do not use cgroup or memcg NUMA controls for current baselines.
- Do not write NUMA scan knobs unless an experiment explicitly asks for it.
- Do not tune `/sys/kernel/debug/sched/numa_balancing/hot_threshold_ms`.
  Record it before/after instead.
- The reference hot threshold is the kernel default, currently `1000 ms`.
  Memory tiering can still adapt the effective per-node threshold through
  `pgdat->nbp_threshold`; do not disable or override that adaptive behavior.
- For PR/BC, use prebuilt GAPBS graph input. The current scale is `29`:
  - host: `/Serverless/benchmark/gapbs/benchmark/graphs/kron_g29.sg`
  - guest: `/root/gapbs_graphs/kron_g29.sg`
  - measured PR/BC runs use `-f`, not `-g29`

These rules are also reflected in:

- `docs/iccd-experiment-protocol-20260601.md`
- `.codex/skills/migration-friendly-kernel/SKILL.md`

## Kernel Implementation State

The kernel has an in-progress TPP-style memory-tiering mode at
`numa_balancing=4`.

Main implementation points:

- `NUMA_BALANCING_TPP` is defined as `0x4` in
  `linux/include/linux/sched/sysctl.h`.
- `NUMA_BALANCING_TIERING_MASK` treats both `0x2` and `0x4` as tiering modes.
- `memory_tiering_enabled()` returns true for either `0x2` or `0x4`.
- `vmscan.c` uses the promo watermark for either `0x2` or `0x4`.
- `should_numa_migrate_memory()` has a TPP branch before the normal `0x2`
  latency-threshold path.

Important code references in the current tree:

- `linux/include/linux/sched/sysctl.h:22`: mode bits and helper predicates.
- `linux/kernel/sched/fair.c:1956`: `numa_tpp_folio_active()`.
- `linux/kernel/sched/fair.c:1970`: `should_numa_migrate_memory()`.
- `linux/kernel/sched/fair.c:1998`: TPP branch.
- `linux/kernel/sched/fair.c:2000`: inactive TPP folio is marked accessed and
  rejected instead of being treated as an active candidate.
- `linux/kernel/sched/fair.c:2006`: active TPP folio increments
  `PGPROMOTE_CANDIDATE`.
- `linux/kernel/sched/fair.c:2043`: normal `0x2` latency reject path.
- `linux/kernel/sched/fair.c:2052`: normal `0x2` rate-limit reject path.
- `linux/kernel/sched/debug.c:492`: debugfs
  `sched/numa_balancing/promotion_thresholds`.
- `linux/mm/vmscan.c:4897` and `linux/mm/vmscan.c:6899`: promo watermark
  handling for either tiering mode.

New vmstat counters were added around the promotion decision pipeline:

- `numa_promote_access`
- `numa_promote_access_pages`
- `numa_promote_nrl`
- `numa_promote_nrl_pages`
- `numa_promote_latency_reject`
- `numa_promote_latency_reject_pages`
- `numa_promote_hot`
- `numa_promote_hot_pages`
- `numa_promote_rate_limit_reject`
- `numa_promote_rate_limit_reject_pages`
- `numa_promote_try`
- `numa_promote_try_pages`
- `numa_tpp_inactive_reject`
- `numa_tpp_inactive_reject_pages`
- `numa_tpp_active_candidate`
- `numa_tpp_active_candidate_pages`

The important TPP fix from this session is the MGLRU-aware active check. The
old active test could leave MGLRU folios stuck in the wrong state for TPP
candidate selection. The current code checks `folio_lru_gen()` and
`lru_gen_is_active()` when MGLRU is enabled, otherwise it falls back to
`folio_test_active()`.

## Experiment Directories

### `motivation/3_real_world/memory_tiering`

This directory replaced the earlier `20260601-local16-4configs` name. It holds
the 13-workload 4-config baseline scripts and the recent graph-producing
outputs. Older confusing outputs were removed as requested.

Configs:

- `migration_off`: `16G` fast, `176G` slow, `numa_balancing=0`
- `migration_on`: `16G` fast, `176G` slow, `numa_balancing=2`
- `all_local`: `152G` fast, `4G` slow, `membind=0`
- `all_slow`: `4G` fast, `152G` slow, `membind=1`

Recent output roots:

- `motivation/3_real_world/memory_tiering/results/20260602T095550Z-pr-gups-btree-onoff-thread-sweep-combined`
- `motivation/3_real_world/memory_tiering/results/20260603T043808Z-local16-onoff-thp-always-6wl-combined-with-prev16`
- `motivation/3_real_world/memory_tiering/results/20260603T075421Z-local16-thp-always-4configs-combined-with-prev16`

Recent figures were also copied under `experiments/figure/`.

### `motivation/pr_graph_test`

This is the current local-memory sweep for PR/Graph500 and later BC/BTree/XSBench
extension.

Matrix:

- Workloads in combined plots: `pr`, `bc`, `graph500`, `btree`, `xsbench`
- Local sizes: `8G`, `16G`, `32G`
- Configs: `all_fast`, `all_slow`, `migration_off`, `migration_on` (`0x2`),
  `tpp` (`0x4`)
- MGLRU: `0x0007`
- THP: `never`
- PR/BC graph: prebuilt `kron_g29.sg`

Important outputs:

- `motivation/pr_graph_test/results/20260604T065049Z-pr-graph-local-sweep/summaries/summary.csv`
- `motivation/pr_graph_test/results/20260604T094932Z-bc-btree-xsbench-local-sweep/summaries/summary.csv`
- `motivation/pr_graph_test/results/20260605T014234Z-combined-pr-bc-btree-xsbench-plots/summary.md`
- `motivation/pr_graph_test/figure/summary.md`
- `motivation/pr_graph_test/figure/dual_axis_local8_runtime_promotion_success.png`
- `motivation/pr_graph_test/figure/dual_axis_local16_runtime_promotion_success.png`
- `motivation/pr_graph_test/figure/dual_axis_local32_runtime_promotion_success.png`

The dual-axis local-size figures show runtime as bars and promotion success
count as a line. Percent labels are speedup over `migration_off`.

Representative combined runtime table:

| Workload | Local GiB | All fast | All slow | Off | On 0x2 | TPP 0x4 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| pr | 8 | 84 | 265 | 134 | 115 | 139 |
| pr | 16 | 84 | 265 | 148 | 102 | 105 |
| pr | 32 | 84 | 265 | 100 | 106 | 101 |
| bc | 8 | 67 | 174 | 165 | 168 | 160 |
| bc | 16 | 67 | 174 | 165 | 153 | 150 |
| bc | 32 | 67 | 174 | 156 | 146 | 143 |
| graph500 | 8 | 229 | 387 | 387 | 408 | 428 |
| graph500 | 16 | 229 | 387 | 383 | 394 | 407 |
| graph500 | 32 | 229 | 387 | 367 | 368 | 386 |
| btree | 8 | 538 | 1109 | 933 | 677 | 669 |
| btree | 16 | 538 | 1109 | 841 | 673 | 671 |
| btree | 32 | 538 | 1109 | 546 | 650 | 681 |
| xsbench | 8 | 424 | 2931 | 2374 | 786 | 1373 |
| xsbench | 16 | 424 | 2931 | 467 | 773 | 789 |
| xsbench | 32 | 424 | 2931 | 2543 | 495 | 512 |

Interpretation caveats:

- XSBench has suspicious rows where tiering appears faster than all-fast or
  where off varies heavily. Treat XSBench as needing rerun/validation before
  drawing a conclusion.
- Graph500 TPP is generally slower than off/on in the MGLRU-on sweep, despite
  high promotion traffic.
- BTree promotes heavily but has low success/candidate ratio in both `0x2` and
  TPP.

### `motivation/3_real_world/no_mglru`

This is a diagnostic run with guest MGLRU disabled. It is not the current
default validation state, but it was useful for isolating classic LRU behavior.

Main run:

- `motivation/3_real_world/no_mglru/results/20260605T0215-no-mglru-pr-bc-graph500-local-sweep`
- Workloads: `pr`, `bc`, `graph500`
- Local sizes: `8G`, `16G`, `32G`
- Configs: `migration_on` (`0x2`), `tpp` (`0x4`)
- MGLRU: `0x0000`
- THP: `never`
- Runs: 18/18 succeeded

Aggregate candidate-to-success ratios from that run:

| Config | Candidate | Success | Success/Candidate | Failure Ratio |
| --- | ---: | ---: | ---: | ---: |
| migration_on | 82713382 | 22556184 | 0.272703 | 0.727297 |
| tpp | 66244749 | 30568483 | 0.461448 | 0.538552 |

The anomalous row was:

- Full sweep row: `local32 graph500 migration_on`
- Candidate: `26594315`
- Success: `9563`
- Promote GiB: `0.036480`
- Demote GiB: `0.084995`
- Elapsed: `377s`

Clean repeat:

- `motivation/3_real_world/no_mglru/results/20260605T0445-no-mglru-graph500-local32-migration-on-repeat`
- Candidate: `12165866`
- Success: `8788402`
- Promote GiB: `33.525093`
- Demote GiB: `47.287868`
- Elapsed: `366s`

This strongly suggests the original full-sweep row was not a stable Graph500
property. It likely reflected same-VM carry-over state from the previous PR and
BC runs, but the exact kernel mechanism is not proven yet.

### `motivation/4_ours/20260603-local16-basepage-ours`

This directory contains the plan and scripts for an `ours` run at 16G local
memory using base pages and the existing 13 workloads.

Planned matrix:

- Run only `ours`.
- Merge existing `off` and `on` results from the memory-tiering baseline.
- Local memory: `16G`
- Slow memory: `176G`
- MGLRU: `0x0007`
- THP: `never`
- Workloads: the same 13-workload set as `memory_tiering`

As of this handoff, no `results/` directory was present under
`motivation/4_ours/20260603-local16-basepage-ours`. Treat it as planned/scripts
available, not completed.

## Analysis State

### Candidate versus success

The original issue was that candidates were too low in TPP under MGLRU. The
MGLRU-aware active check and inactive-mark-accessed path were added to address
that candidate-formation problem.

After that fix, the more visible issue became candidate-to-success conversion:
many candidates reach the promotion decision path, but not all become successful
promotions. The likely next places to instrument are after
`should_numa_migrate_memory()`:

- `migrate_misplaced_folio_prepare()` target-node watermark rejection
- isolation failures
- actual `migrate_pages()` failures
- demotion availability on the fast node
- kswapd demotion progress

The current counters can show access, active candidate, latency reject, rate
limit reject, and try. They do not fully distinguish prepare-time rejection from
later migration failure.

### Graph500 carry-over analysis

Old workload anonymous pages should not remain on the LRU after process exit.
They are unmapped/freed through the normal `exit_mmap()` and page-release path,
and new anonymous faults allocate new folios and put them on fresh LRU entries.

What can remain is global or per-node bookkeeping and asynchronous reclaim
state, for example:

- `pgdat->nbp_threshold`
- `pgdat->nbp_th_nr_cand`
- `pgdat->nbp_rl_nr_cand`
- `lruvec->anon_cost`
- `lruvec->file_cost`
- workingset/refault snapshots
- kswapd wake/order/highest_zoneidx state
- zone watermark/boost/reclaim-active state
- page allocator fragmentation, PCP, and free-area state

The full-sweep Graph500 anomaly happened when Graph500 was the third workload
in the same VM. The clean repeat did not reproduce it. That makes carry-over
plausible, but not yet proven.

### `anon_cost` and `file_cost`

`lruvec->anon_cost/file_cost` is not NUMA balancing. It is classic LRU reclaim
scan balance between anon and file LRUs.

Relevant code:

- `linux/mm/vmscan.c:2375`: `prepare_scan_control()` reads
  `lruvec->anon_cost/file_cost`.
- `linux/mm/vmscan.c:2462`: `calculate_pressure_balance()` computes anon/file
  scan pressure fractions.
- `linux/mm/vmscan.c:2569`: `get_scan_count()` converts that into scan budgets
  for the anon/file active/inactive LRU lists.
- `linux/mm/vmscan.c:5839`: shrink path consumes those budgets.
- `linux/mm/swap.c:240`: `lru_note_cost_unlock_irq()` updates and decays the
  costs.

Higher cost for one LRU reduces future scan pressure for that LRU in
`SCAN_FRACT`. With memory tiering, anon reclaim can be useful even without swap
because anon pages can be demoted. Therefore stale anon/file cost state can
plausibly affect how much kswapd scans anon pages and creates fast-node space
for promotion.

Important caveat: when MGLRU is enabled, classic `prepare_scan_control()` returns
early and the classic anon/file cost balance is bypassed for this path. The
`anon_cost/file_cost` carry-over hypothesis is mainly relevant to the no-MGLRU
diagnostic run.

## Recommended Next Steps

For Graph500 anomaly/debugging:

1. Add temporary trace/counters for `migrate_misplaced_folio_prepare()` return
   reasons, especially target fast-node watermark failure.
2. Add temporary trace/counters in `get_scan_count()` for `scan_balance`,
   `fraction[anon]`, `fraction[file]`, and `nr[4]`.
3. Expose or log root lruvec `anon_cost/file_cost` before each workload when
   MGLRU is off.
4. Run Graph500 in clean VMs and in chained PR -> BC -> Graph500 VMs to compare
   reclaim state.
5. Prefer one workload per clean VM for final performance numbers unless the
   experiment explicitly studies carry-over.

For TPP performance:

1. Rebuild the kernel after any further edits:
   `make -C /Serverless/iccd-git/linux O=/Serverless/iccd-git/linux-global-build -j$(nproc) bzImage`
2. Keep MGLRU at `0x0007` for current validation.
3. Keep THP `never` unless explicitly comparing THP.
4. Keep `hot_threshold_ms` at the kernel default and only record it.
5. Re-run a small MGLRU-on smoke first, for example PR/BC/Graph500 at local16
   under `migration_on` and `tpp`.

Useful commands:

```bash
DRY_RUN=1 motivation/3_real_world/memory_tiering/scripts/run_4configs_host.sh

DRY_RUN=1 motivation/pr_graph_test/scripts/run_pr_graph_host.sh

DRY_RUN=1 motivation/3_real_world/no_mglru/scripts/run_no_mglru_host.sh

WORKLOADS=graph500 LOCAL_SIZES=32 CONFIGS=migration_on \
RUN_ID=manual-graph500-local32-repeat \
motivation/3_real_world/no_mglru/scripts/run_no_mglru_host.sh
```

## Final Cautions

- Do not compare no-MGLRU diagnostics directly against MGLRU-on performance
  baselines without labeling the difference.
- Do not treat the original no-MGLRU Graph500 local32 `migration_on` row as a
  stable result.
- Do not tune hot threshold to force promotions.
- Do not use PR/BC `-g29` in measured runs. Use the prebuilt graph via `-f`.
- Do not reset the dirty tree. Some changes are user-requested kernel work and
  experiment scripts.
