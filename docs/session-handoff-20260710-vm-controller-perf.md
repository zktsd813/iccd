# Session Handoff: VM Controller Tuning And Sampling Investigation

Updated: 2026-07-11 UTC

This document summarizes the current session around VM-only CXL/NUMA tiering
experiments, Silo/GUPS controller tuning, quantile policy changes, sampling
anomalies, and the final perf-based access check.

## Correction: Silo Main Phase Was Misclassified

The earlier analysis treated the end of data loading as the start of Silo's
transaction phase. That is incorrect. See
`docs/silo-sampling-root-cause-20260710.md` for the complete evidence.

- Silo prints `starting benchmark...` before constructing its workers.
- It then serially computes a Zipf zeta over 800 million keys for each of 32
  workers.
- The low-sample interval at about 186-470 seconds is worker initialization.
- Perf places the actual transaction phase at about 470.7-735.9 seconds.
- All 23 controller windows overlapping the actual main phase were sample-valid.
- Silo diagnostics no longer use `starting benchmark` as the phase marker. When
  explicitly enabled, the log gate uses the first throughput line instead.
- A fresh gated run detected main at 477.121s, kept migration enabled throughout
  setup, and collected 6,279,382 local / 110,106,197 remote samples across 13
  valid main windows.

The former main-phase low-sample and protected-set divergence conclusions below
are superseded by this correction.

## Hard Rules For Continuing

- Do not reboot unless explicitly requested by the user.
- Do not run real experiments on the host when the requested target is VM.
- Keep VM experiment scripts separate from host-native execution paths, but keep
  controller policy logic shared through `design/fault_bucket_controller/run_guest.sh`
  and `bucket_latency_controller.py`.
- For VM experiments in this line of work:
  - `DISABLE_SMT=1`
  - `RESTORE_SMT=0`
  - VM local memory is controlled by `LOCAL_SIZES_GIB`.
  - Remote memory is VM node1 backed by host node2, usually `MIGRATION_SLOW_MEM=192G`.
  - Use rootfs overlay `cache=none,aio=native`.
  - Drop host page cache before VM boot and before guest run when comparing results.
  - Drop guest caches and compact guest memory between runs.
- Silo must use the jemalloc build and tail hotset unless the user explicitly
  asks otherwise:
  - binary: `silo/out-perf.masstree/benchmarks/dbtest`
  - `--bench ycsb`
  - `--num-threads 32`
  - `--scale-factor 800000`
  - `--ops-per-worker=100000000`
  - `--bench-opts=--zipf-reverse`
- Do not change allocator, hotset direction, workload size, graph mode, or VM
  placement without explicit user approval.
- For GAPBS PR/BC, use generated graph mode only:
  - `-g 29`
  - graph build is included in measured time
  - do not use prebuilt `.sg` files.

## Current Baseline Reference

The baseline copy was created during this session.

- Baseline root: `baseline/`
- Baseline document: `baseline/EXPERIMENT_BASELINE.md`
- Baseline README: `baseline/README.md`
- Frozen baseline run:
  `baseline/20260710T-local32-48-onoff-controller-tail-jemalloc`
- Source run:
  `motivation/3_realworld/VM/results/20260710T-local32-48-onoff-controller-tail-jemalloc`
- Summary:
  `baseline/20260710T-local32-48-onoff-controller-tail-jemalloc/summaries/summary.csv`
- Fixed on/off reference:
  `baseline/fixed-onoff-reference.csv`

Fixed on/off values to reuse unless a new baseline is explicitly requested:

| Local GiB | Workload | off elapsed s | on elapsed s | Source |
| ---: | --- | ---: | ---: | --- |
| 16 | silo | 886 | 714 | `motivation/3_realworld/VM/results/20260709T-local16-onoff-tail-jemalloc-rerun/summaries/summary.csv` |
| 48 | gups | 288 | 872 | `baseline/20260710T-local32-48-onoff-controller-tail-jemalloc/summaries/summary.csv` |

Important: the 16 GiB Silo fixed reference is not in the frozen 32/48 GiB
baseline run, but it uses the required tail-hotset jemalloc Silo setup.

## Main Experiment Thread

### Initial Scope

The session started from a VM-only plan:

- SMT off.
- VM local memory initially 16 GiB.
- Workloads: Silo and Liblinear for quantile analysis.
- Also measure overhead from the new knob where histogram/quantile collection
  remains active even after migration is disabled.
- Page cache interference from VM images should be avoided.

During the session, Liblinear was later removed from the main analysis because
its RSS was only about 13 GiB, which made it a poor fit for the intended 16 GiB
local-memory pressure experiment. The focus moved to Silo first, then GUPS and
other less migration-friendly workloads.

### Execution Boundary Corrections

Several mistakes and corrections happened early:

- Some runs were accidentally host-side or host-like. The user explicitly
  corrected this. From that point onward, experiments in this thread should be
  considered VM-only unless the user explicitly requests host-native.
- The user requested that no reboot happen without explicit command. That remains
  a hard rule.
- Host-side memory/resource restrictions were cleaned up so the VM receives the
  intended resource limits from its own configuration.
- The VM scripts were kept separate from host scripts, but controller behavior is
  kept unified through the shared controller runner.

## Controller Policy Evolution

### Old Direction

Early controller tuning used point quantiles:

- local P75
- remote P25
- selected-gap stop logic
- restart based on selected gap

The intuitive rule discussed was:

- If `local P75 > remote P25`, there exist remote pages faster than local tail
  pages, so migration may be useful.
- If the gap stops improving after a baseline observation, stop migration.

The user pointed out that looking at remote tail quantiles was wrong for this
goal. The policy was standardized to local P75 vs remote P25.

### Main Phase Gating

There was a separate issue where stop decisions could happen before Silo main
phase. A temporary stdout-gated approach was tested:

- Detect Silo main phase from throughput output.
- Delay stop decisions by 10s, then 60s, then fixed policies such as 100s after
  main phase.

However, the user requested that the default controller not depend on workload
stdout, because the controller should apply to other workloads. The main-phase
log path was removed from the default policy path. Gating may still be useful
for one-off diagnostics, but should not be the default controller policy.

### Window Definition

The user requested that the controller window not be a simple timer. The intended
window should advance when a remote memory tiering scan has completed a cycle.

Implemented/current direction:

- `WINDOW_MODE=remote-cycle`
- `CYCLE_WINDOW_STAT=remote_scan_cycles`
- `ADVANCE_WINDOW=0`
- The controller advances by remote scan cycle count.
- Window duration is clamped:
  - minimum 5s
  - maximum 20s

The clamp was added because GUPS had windows that were too slow when strictly
waiting for a full remote cycle.

### Current Stop/Restart Policy

The active controller setting used in current experiments:

- stop policy: `selected-gap`
- restart policy: `selected-gap-immediate`
- local quantile: P75
- remote quantile: P25
- local fault sampling:
  - rate 5
  - scan period 1000 ms
  - scan size 64 MB
- normal NUMA scan:
  - scan size 256 MB
  - min period 1000 ms
- Score-policy compatibility settings are recorded as
  `BASELINE_SKIP_WINDOWS=0`, `CONSECUTIVE_EFFECTIVE=3`,
  `CONSECUTIVE_NO_IMPROVE=2`, `EFFECTIVE_SCORE_THRESHOLD=0.75`, and
  `SCORE_EPSILON=0.05`; they do not delay the immediate selected-gap stop.
- restart grace:
  - `CONSECUTIVE_RESTART=2`
  - `RESTART_GRACE_WINDOWS=1`
- migration off action:
  - `STOP_ACTION=observe`
  - `NUMA_BALANCING_ON=2`
  - `NUMA_BALANCING_OFF=0`
  - `STOP_FAULT_SAMPLING_ON_STOP=0`

### Capacity/CDF Policy

The user proposed that point quantiles alone ignore memory capacity. That led
to a new capacity-aware interpretation:

- Use local P75 latency as threshold A.
- Query remote CDF at latency A.
- Since local P75 means the local tail is 25 percent of local resident memory,
  local demotion candidates are approximately local resident pages times 25%.
- Remote promotion candidates are remote resident pages times
  `remote_cdf(A)`.
- Compare the two candidate capacities with a room/guard factor.

The current capacity guard uses:

- `RESTART_CAPACITY_GUARD_THRESHOLD=0.9`
- `RESTART_CAPACITY_GUARD_SOURCE=resident`
- CDF query through `/sys/kernel/mm/numa_balancing/fault_latency_cdf_query_ns`
- Controller records:
  - `cdf_query_ns`
  - `remote_cdf_le_query_ppm`
  - restart capacity guard state and ratio fields.

Important correction:

- `local_cdf(A)` is not necessary when A is exactly local P75. The local tail
  share is known: 25%.

## Kernel And Controller Instrumentation

### Remote Fault Sampler

The user requested removal of the separate remote sampler path because it caused
confusion. The current direction is:

- Do not use or discuss the old separate remote sampler for this controller.
- Windowing uses normal memory tiering remote scan progress, not a separate
  remote sampling loop.

### PTE Skip Counters

To explain why samples disappeared, kernel counters were added around NUMA
protection/skipping.

Relevant files:

- `linux/include/linux/memcontrol.h`
- `linux/mm/mprotect.c`
- `linux/mm/huge_memory.c`
- `linux/mm/numa_balancing.c`
- `design/fault_bucket_controller/bucket_latency_controller.py`

Counters added to `/sys/kernel/mm/numa_balancing/local_fault_stats` include:

- `remote_scan_skip_total`
- `remote_scan_skip_protnone`
- `remote_scan_skip_no_folio`
- `remote_scan_skip_zone_device_ksm`
- `remote_scan_skip_cow_shared`
- `remote_scan_skip_dirty_file`
- `remote_scan_skip_balancing_disabled`
- `remote_scan_skip_same_node`
- `remote_scan_skip_top_tier_disabled`
- `remote_scan_skip_unknown`
- `local_fault_pfn_scanned`
- `local_fault_skip_no_page_or_wrong_node`
- `local_fault_skip_not_lru`
- `local_fault_skip_large`
- `local_fault_skip_unmapped`
- `local_fault_skip_already_sampled`
- `local_fault_skip_seen_window`
- `local_fault_skip_not_selected`
- `local_fault_install_failed`

The controller now records these raw counters and deltas.

### Pid-Inactive VMA Skip Test

A hypothesis was tested that `vma_is_accessed()` / PID inactive skip was the
reason remote scans were missing the hot set. A diagnostic patch temporarily
bypassed the condition:

```c
if (!vma_pids_forced && !vma_is_accessed(mm, vma)) {
```

That bypass was later reverted. The condition is currently restored. The test
did not explain the observed low-sample behavior by itself.

### Perf Attach Support

For the final access check, optional perf attach support was added:

- `design/fault_bucket_controller/run_guest.sh`
- `motivation/3_realworld/VM/scripts/run_workload_case_guest.sh`
- `motivation/3_realworld/VM/scripts/run_vm_sweep_guest.sh`
- `motivation/3_realworld/VM/scripts/run_vm_sweep_host.sh`

New optional environment variables:

- `PERF_ATTACH_EVENTS`
- `PERF_ATTACH_INTERVAL_MS`
- `PERF_ATTACH_OUTPUT`
- `PERF_ATTACH_EXTRA_ARGS`
- `PERF_ATTACH_FILTER_UNSUPPORTED`
- `PERF_ATTACH_BIN`

Important implementation detail:

- The first attempt attached perf to the `/usr/bin/time` wrapper PID and was
  invalid.
- The script was fixed to wait for and attach to the leaf child process, which
  was the actual `dbtest` PID.
- This is diagnostic only. Runs with perf attach should not be used for normal
  performance comparison.

Script validation performed:

```bash
bash -n design/fault_bucket_controller/run_guest.sh
bash -n motivation/3_realworld/VM/scripts/run_workload_case_guest.sh
bash -n motivation/3_realworld/VM/scripts/run_vm_sweep_guest.sh
bash -n motivation/3_realworld/VM/scripts/run_vm_sweep_host.sh
```

## Key Results

### 16 GiB Silo On/Off Fixed Reference

Run:

`motivation/3_realworld/VM/results/20260709T-local16-onoff-tail-jemalloc-rerun`

Key rows:

| Local GiB | Workload | Config | elapsed s | N0 GiB | N1 GiB | promoted GiB | demoted GiB | hint faults |
| ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 16 | silo | off | 886 | 15.146702 | 100.542686 | 0.000000 | 0.000000 | 0 |
| 16 | silo | on | 714 | 15.554367 | 101.265865 | 55.007324 | 88.360107 | 109,934,595 |

This is the fixed 16 GiB Silo on/off reference. Migration-on is clearly faster
for this tail-hotset Silo setup.

### 16 GiB Silo Controller Reference

Run:

`motivation/3_realworld/VM/results/20260710T-local16-controller-tail-jemalloc-rerun`

Key Silo row:

| Local GiB | Workload | Config | elapsed s | promoted GiB | demoted GiB | hint faults | first stop | final state | restarts |
| ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | --- | ---: |
| 16 | silo | controller_0x2 | 698 | 58.343300 | 84.259727 | 119,471,149 | 663.423s W15 | off | 0 |

This run was close to, and slightly faster than, the fixed migration-on reference
of 714s. It does not show the pathological early stop that later diagnostics
targeted.

### PTE Skip Counter Diagnostic

Run:

`motivation/3_realworld/VM/results/20260710T-silo-local16-pte-skip-counters`

Summary:

- elapsed: 734s
- dataloading: 196.682s
- runtime: 240.335s
- first stop: W12 at 206.268s
- final state: off
- promoted: 0.115 GiB
- demoted: 32.658 GiB
- hint faults: 126,980,531
- migration disabled reject pages: 117,370,059

Representative windows from that investigation:

| Window | remote pte updates delta | protnone skip delta | hint faults delta | local refault delta | interpretation |
| ---: | ---: | ---: | ---: | ---: | --- |
| W18 | 10,908 | 10,426,308 | 24 | 1 | protected remote set mostly not hit |
| W19 | 24 | 17,054,342 | 1 | 0 | same |
| W20 | 0 | 10,998,131 | 27 | 1 | same |
| W23 | 0 | 15,595,277 | 26 | 2 | same |
| W27 | 0 | 14,310,431 | 22 | 2 | same |
| W28 | 5,201,765 | 7,113,112 | 32,448,099 | 3,242,626 | first window overlapping transaction start |

Corrected interpretation:

- W18-W27 are worker/Zipf initialization, not transaction main.
- W28 overlaps transaction start, after which fault samples remain high.
- This table is not evidence of a long-lived spatial divergence.

### Perf Access Check

Valid run:

`motivation/3_realworld/VM/results/20260710T-silo-local16-perf-access-check-v2`

Invalid earlier run:

`motivation/3_realworld/VM/results/20260710T-silo-local16-perf-access-check`

Why the earlier run is invalid:

- perf attached to the `/usr/bin/time` wrapper, not `dbtest`.
- Perf output contained `<not counted>`.

Valid run setup:

```bash
RUN_ID=20260710T-silo-local16-perf-access-check-v2
LOCAL_SIZES_GIB='16'
CONFIGS='controller_0x2'
WORKLOADS='silo'
DISABLE_SMT=1
RESTORE_SMT=0
ROOTFS_VIRTUAL_SIZE=120G
MIGRATION_SLOW_MEM=192G
FORBID_HOST_NODE1=1
NUMA_SCAN_SIZE_MB=256
NUMA_SCAN_PERIOD_MIN_MS=1000
DROP_HOST_CACHES_BEFORE_VM_BOOT=1
DROP_HOST_CACHES_BEFORE_GUEST_RUN=1
DROP_GUEST_CACHES=1
COMPACT_GUEST_MEMORY=1
CONTROLLER_STOP_POLICY=selected-gap
CONTROLLER_RESTART_POLICY=selected-gap-immediate
CONTROLLER_RESTART_CAPACITY_GUARD_THRESHOLD=0.9
CONTROLLER_RESTART_CAPACITY_GUARD_SOURCE=resident
CONTROLLER_CYCLE_WINDOW_MIN_SEC=5
CONTROLLER_CYCLE_WINDOW_MAX_SEC=20
SILO_ZIPF_REVERSE=1
PERF_BIN_HOST=/Serverless/iccd-git/linux-perf-min-build/perf
PERF_ATTACH_EVENTS='cycles,instructions,cache-references,cache-misses,branches,branch-misses,page-faults,minor-faults,major-faults,L1-dcache-loads,L1-dcache-load-misses,dTLB-loads,dTLB-load-misses,dTLB-load-misses.walk_completed,mem_inst_retired.all_loads,mem_inst_retired.all_stores'
PERF_ATTACH_INTERVAL_MS=1000
PERF_ATTACH_FILTER_UNSUPPORTED=1
```

Summary:

- elapsed: 753s
- this elapsed is not performance-comparable because perf attach adds overhead.
- Silo dataloading: 186.142s
- Silo benchmark runtime: 265.26s
- serial worker/Zipf initialization: about 186.1s to 470.7s
- actual transaction main: about 470.7s to 735.9s
- Silo aggregate throughput: `1.20224e+07 ops/sec`
- first stop: W12 at 205.567s
- final state: off
- restart events: 0
- promoted: 0.229855 GiB
- demoted: 23.178268 GiB
- hint faults: 140,488,989
- migration disabled reject pages: 129,574,934

Key perf conclusion:

Samples are present throughout the actual transaction main phase.

Windows previously misclassified as main phase:

| Window | elapsed s | hint faults delta | local refault delta | remote pte updates delta | protnone skip delta | perf loads/s | perf stores/s | throughput |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| W18 | 311.6 | 2 | 1 | 0 | 15,295,563 | 3.36G/s | 0.36G/s | N/A |
| W19 | 316.6 | 4 | 0 | 33 | 3,029,292 | 3.37G/s | 0.36G/s | N/A |
| W24 | 393.7 | 4 | 2 | 2 | 2,632,521 | 3.39G/s | 0.36G/s | N/A |

Those throughput values were previously matched using the Silo transaction
timer as if it were workload wall time. The transaction timer starts only after
worker construction, so that match was invalid.

For the actual main-phase W31-W53:

- valid windows: 23 of 23
- local samples: 6,913,640 total
- remote samples: 110,268,674 total
- NUMA hint faults: 136,890,360 total
- minimum local/remote samples per window: 70,679 / 1,616,495

The low-sample perf loads were primarily the serial Zipf `zeta()/pow()`
calculation, not accesses to the DB hot set. The protected DB PTEs correctly
remained PROT_NONE until the transaction workers started.

## 32 GiB And 48 GiB Baseline Snapshot

Run:

`baseline/20260710T-local32-48-onoff-controller-tail-jemalloc`

Elapsed time in seconds:

| Local GiB | Workload | off | on | controller_0x2 |
| ---: | --- | ---: | ---: | ---: |
| 32 | pr | 803 | 809 | 819 |
| 32 | bc | 1074 | 873 | 929 |
| 32 | gups | 307 | 815 | 659 |
| 32 | btree | 547 | 650 | 664 |
| 32 | graph500 | 378 | 383 | 381 |
| 32 | silo | 856 | 662 | 685 |
| 48 | pr | 796 | 732 | 780 |
| 48 | bc | 1046 | 670 | 605 |
| 48 | gups | 288 | 872 | 882 |
| 48 | btree | 486 | 651 | 597 |
| 48 | graph500 | 342 | 336 | 373 |
| 48 | silo | 806 | 678 | 676 |

Notable points:

- 32 GiB Silo: controller 685s, close to on 662s and much better than off 856s.
- 48 GiB Silo: controller 676s, essentially equal to on 678s and better than off
  806s.
- 48 GiB GUPS: off 288s, on 872s, controller 882s. This is a bad case where
  migration-on behavior is harmful and controller did not improve it in the
  frozen baseline.
- 48 GiB BC: controller 605s is better than on 670s and off 1046s.

## GUPS And Unfriendly Workloads

GUPS became the representative unfriendly workload.

Important runs:

- `motivation/3_realworld/VM/results/20260710T-capacity-policy-verify-silo16-gups48`
- `motivation/3_realworld/VM/results/20260710T-gups48-window-clamp-5-20`
- `motivation/3_realworld/VM/results/20260710T-gups48-window-clamp-5-20-th09`

Key rows:

| Run | Local GiB | Workload | elapsed s | first stop | final state | restarts | promoted GiB | demoted GiB |
| --- | ---: | --- | ---: | ---: | --- | ---: | ---: | ---: |
| capacity verify | 48 | gups | 576 | 119.028s W3 | off | 2 | 2.579 | 3.526 |
| clamp 5-20 th09 | 48 | gups | 311 | 40.540s W2 | off | 0 | 0.348 | 0.566 |
| frozen baseline | 48 | gups | 882 | 159.093s W3 | off | 2 | 2.659 | 2.702 |

The clamp and threshold tuning helped GUPS stop earlier. The fixed on/off
reference still says 48 GiB GUPS should prefer migration off:

- off: 288s
- on: 872s

## Silo Hotset Direction And Friendly/Unfriendly Interpretation

Silo was modified/configured to move the hotset toward the tail by using
`--zipf-reverse`.

This separated cases better:

- first-hotset and tail-hotset showed different migration behavior.
- tail-hotset with 16 GiB local memory made migration-on useful in the fixed
  reference.
- The controller can do well if it keeps migration on long enough or only stops
  after useful migration has happened.

Important intuition:

- Migration being helpful does not mean it must remain on forever.
- Once enough useful pages have moved, stopping migration can be beneficial.
- The hard part is knowing whether the protected/faulted sample set still
  represents the active hot stream.

## Sampling Anomaly: Final Interpretation

The anomaly was caused by phase misclassification:

1. `starting benchmark...` is printed before worker construction.
2. The main thread then constructs 32 workers serially.
3. Every worker recomputes Zipf zeta over 800 million keys.
4. W18/W19/W24 are in that compute-only setup interval, not in transaction main.
5. Perf concurrency rises from about 4G to 78-107G cycles/s when workers start.
6. Local and remote NUMA samples rise at the same point and remain valid through
   the actual 265-second transaction phase.

Large `remote_scan_skip_protnone` values are expected during setup because the
Zipf calculation does not access DB pages protected during loading.

## Current Code State To Be Aware Of

The worktree is dirty. There are many unrelated or earlier modifications. Do not
revert user changes.

Relevant files touched for this controller/sampling line:

- Kernel:
  - `linux/include/linux/memcontrol.h`
  - `linux/kernel/sched/fair.c`
  - `linux/mm/memory.c`
  - `linux/mm/mprotect.c`
  - `linux/mm/huge_memory.c`
  - `linux/mm/numa_balancing.c`
- Controller:
  - `design/fault_bucket_controller/bucket_latency_controller.py`
  - `design/fault_bucket_controller/run_guest.sh`
  - `design/fault_bucket_controller/test_bucket_latency_controller.py`
  - `design/fault_bucket_controller/plot_controller.py`
- VM scripts:
  - `motivation/3_realworld/VM/scripts/run_vm_sweep_host.sh`
  - `motivation/3_realworld/VM/scripts/run_vm_sweep_guest.sh`
  - `motivation/3_realworld/VM/scripts/run_workload_case_guest.sh`
  - `motivation/3_realworld/VM/scripts/summarize_vm_results.py`

Recent diagnostic support that should be treated carefully:

- perf attach is optional and disabled unless `PERF_ATTACH_EVENTS` is set.
- perf attach runs are not performance baselines.
- PTE skip counters are useful for diagnosis and currently integrated into
  controller CSV output.
- The temporary `pid_inactive` bypass was reverted. The original
  `vma_is_accessed()` skip condition is restored.

## Invalid Or Non-Comparable Runs

Do not use these as performance baselines:

- `20260710T-silo-local16-perf-access-check`
  - invalid perf target, attached to wrapper PID.
- `20260710T-silo-local16-perf-access-check-v2`
  - valid for access/sampling diagnosis, not valid for performance comparison
    because perf attach adds overhead.
- Earlier runs where allocator was changed away from jemalloc should not be used
  for Silo comparison. The user explicitly required jemalloc consistency.
- Runs with stdout main-phase gating are diagnostic only unless the user
  explicitly asks for workload-specific gating again.

## Current Open Questions

1. How should a workload-independent controller distinguish setup from main?
   - The first Silo throughput line is safe for a workload-specific diagnostic.
   - The default controller remains independent of workload stdout.

2. How should decisions based on loading samples be prevented?
   - The first stop at 205.567s was about 266s before actual transaction main.
   - Phase detection and the policy itself need separate evaluation.

4. GUPS remains the unfriendly control case.
   - 48 GiB GUPS off is fixed at 288s.
   - Migration on is 872s.
   - Current controller variants improved some diagnostic runs but must be
     compared against the frozen baseline before claiming improvement.

## Recommended Next Step

For the next continuation, do not immediately rerun the full sweep. First decide
which question is being answered:

- If the goal is policy tuning:
  - use fixed on/off from `baseline/fixed-onoff-reference.csv`;
  - run only controller variants;
  - keep Silo 16 GiB and GUPS 48 GiB as the friendly/unfriendly pair.

- If the goal is explaining missing samples:
  - do not use `starting benchmark` or data-load completion as main start;
  - use the first throughput line or an explicit post-worker-start marker;
  - use the corrected offline perf-concurrency detector for this existing run.

- If the goal is paper-quality reporting:
  - use frozen baseline for on/off;
  - separate diagnostic perf/PTE-skip runs from performance runs;
  - separate worker initialization from actual transaction main.

## Final State At Handoff

- No VM/QEMU experiment is currently expected to be running.
- Latest completed run:
  `motivation/3_realworld/VM/results/20260710T-silo-local16-perf-access-check-v2`
- Baseline is copied under `baseline/`.
- The key conclusion is that Silo local/remote NUMA sampling works during the
  actual transaction main. The apparent low-sample main was serial Zipf worker
  initialization mislabeled as transaction execution.
