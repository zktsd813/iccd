# Session Handoff 2026-05-29

This document summarizes the current ICCD migration-friendly kernel state,
recent experiments, and the open analysis thread. Use it as the first file to
read when starting the next session.

## Current Workspace

- Project root: `/Serverless/iccd`
- Active kernel source: `/Serverless/iccd/linux`
- Active kernel build dir: `/Serverless/iccd/linux-build-mt`
- Active kernel image:
  `/Serverless/iccd/linux-build-mt/arch/x86/boot/bzImage`
- Kernel used in the latest PR/Silo experiments:
  `Linux kernel 6.18.0modified+ #12 SMP PREEMPT_DYNAMIC Fri May 29 02:53:23 UTC 2026`
- QEMU/rootfs tooling is still reused from:
  `/Serverless/Migration-friendly`
- GAPBS graph rule: use prebuilt `-f /root/gapbs_graphs/kron_g28.sg`, not
  `-g28` inside measured PR/BC runs.
- No QEMU or PR/Silo experiment process was left running at handoff time.

## Important VM Setup For Latest Runs

Latest PR/Silo latency experiments used physical VM fast-tier limiting:

- VM memory: node0 local 8G, node1 remote 160G
- vCPUs: 32
- CPU binding: host CPUs 0-31, guest node0 CPUs 0-31
- host memory binding:
  - guest node0 to host node0
  - guest node1 to host node2
- MGLRU: `0x0007`
- migration: cgroup `node_balancing=2`
- demotion: enabled with target `0 1`
- scan state recorded in guest:
  - `scan_size_mb=256`
  - `scan_period_min_ms=1000`
- controller was run with `DRY_RUN=1` for latency measurement, so "off"
  events in controller logs are decisions, not actual migration-off actions.

## Current Local-Fault Mechanism

The kernel has the current local fault sampling path:

- `numa_local_fault_on_tiering`: sample rate knob.
- `numa_local_fault_refault_hit_ms`: threshold for counting fast local
  refault hits.
- `numa_local_fault_scan_period_ms`: local scan period.
- `numa_local_fault_scan_size_mb`: local scan budget, supports `auto` through
  the runner.
- `numa_local_fault_window`: advances local-fault accounting windows.
- local fault stats in `memory.numa_migrate_state` include:
  - `numa_local_fault_pte_updates`
  - `numa_local_fault_refault`
  - `numa_local_fault_refault_hit`
  - `numa_local_fault_refault_total_ms`
  - `numa_local_fault_refault_avg_us`

The current measurement interpretation:

- `numa_local_fault_refault_total_ms` is not page fault handler service time.
- It is reuse time from local PTE_NONE installation to the subsequent local
  refault.
- `numa_local_fault_refault_hit` is the subset whose reuse time is within
  `numa_local_fault_refault_hit_ms`.

## Userspace Changes Made In This Session

Files changed:

- `/Serverless/iccd/scripts/local_util_adapt_controller.py`
- `/Serverless/iccd/VM/scripts/local_util_adapt_controller.py`
- `/Serverless/iccd/VM/guest/run_all_workloads_phys8g_ours_toggle_w5_guest.sh`

Controller updates:

- Added CSV output for local refault latency:
  - `local_refault_latency_total_ms_delta`
  - `local_refault_latency_avg_us`
- Existing remote hint latency CSV fields remain:
  - `remote_hint_fault_delta`
  - `remote_hint_latency_total_ms_delta`
  - `remote_hint_latency_avg_us`
- Fixed a controller bug in round mode:
  - Before the fix, `--no-window-buckets` was ignored inside round arm/observe
    loops.
  - That made local latency appear as zero, because kernel window buckets do
    not carry the latency total.
  - After the fix, round mode uses raw cgroup counter deltas when
    `--no-window-buckets` is passed.

Guest runner update:

- Added `USE_WINDOW_BUCKETS="${USE_WINDOW_BUCKETS:-1}"`.
- Logs `use_window_buckets`.
- Passes `--no-window-buckets` to the runner when `USE_WINDOW_BUCKETS=0`.

Validation:

- `python3 -m py_compile scripts/local_util_adapt_controller.py VM/scripts/local_util_adapt_controller.py`
  passed.

## Remote Hint Fault Latency Experiment

Experiment:

- `/Serverless/iccd/experiments/20260529-remote-hint-latency-pr-silo`

Runner:

- `/Serverless/iccd/experiments/20260529-remote-hint-latency-pr-silo/notes/run_pr_silo_remote_latency.sh`

Configuration:

- workloads: `pr silo`
- local fault sampling off: `LOCAL_FAULT_RATE=0`
- controller dry-run: `DRY_RUN=1`
- migration kept on

Result files:

- Summary:
  `/Serverless/iccd/experiments/20260529-remote-hint-latency-pr-silo/summaries/remote_hint_latency_summary.csv`
- PR 5s:
  `/Serverless/iccd/experiments/20260529-remote-hint-latency-pr-silo/summaries/pr_remote_hint_latency_5s.csv`
- Silo 5s:
  `/Serverless/iccd/experiments/20260529-remote-hint-latency-pr-silo/summaries/silo_remote_hint_latency_5s.csv`

Key results:

| workload | elapsed | remote hint faults | weighted avg latency | median 5s | p90 | p99 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| PR | 666s | 80,605,326 | 7.64ms | 5.78ms | 16.31ms | 35.45ms |
| Silo | 696s | 125,004,787 | 31.81ms | 1.54ms | 30.25ms | 141.13ms |

Interpretation:

- This is remote NUMA hint fault reuse latency, not handler service time.
- It measures from remote scan/PTE protection to later hint fault.

## Local Fault Latency Experiment

Experiment:

- `/Serverless/iccd/experiments/20260529-local-fault-latency-pr-silo`

Runner:

- `/Serverless/iccd/experiments/20260529-local-fault-latency-pr-silo/notes/run_pr_silo_local_latency.sh`

Configuration:

- workloads: `pr silo`
- `LOCAL_FAULT_RATE=10`
- `LOCAL_FAULT_HIT_MS=1000`
- `USE_WINDOW_BUCKETS=0`
- `DRY_RUN=1`
- `REMOTE_CONSECUTIVE=999`
- migration stayed on during the measurement

Result files:

- Summary:
  `/Serverless/iccd/experiments/20260529-local-fault-latency-pr-silo/summaries/local_fault_latency_summary.csv`
- PR 5s:
  `/Serverless/iccd/experiments/20260529-local-fault-latency-pr-silo/summaries/pr_local_fault_latency_5s.csv`
- Silo 5s:
  `/Serverless/iccd/experiments/20260529-local-fault-latency-pr-silo/summaries/silo_local_fault_latency_5s.csv`
- Notes:
  `/Serverless/iccd/experiments/20260529-local-fault-latency-pr-silo/notes/summary.md`

Key aggregate results:

| workload | range | local refaults | weighted avg reuse time | median window | p90 | fast hit % |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| PR | after60s | 4,673,480 | 8.72s | 7.86s | 15.69s | 9.57% |
| Silo | after60s | 3,645,354 | 11.43s | 211ms | 18.22s | 91.85% |

Interpretation:

- PR has many local refaults, but most are not within the 1s fast-hit
  threshold.
- Therefore PR does not satisfy a 1s fast-local-hit stop condition.
- Silo has many local refaults within 1s, so it reaches the local-access stop
  condition in the dry-run controller.
- Silo controller decision time in this run:
  `migration_off_ms=445168`, reason `local_access`.
  Because `DRY_RUN=1`, migration was not actually turned off.

## Local Access Ratio Analysis

The latest user question moved from latency-only to a window-level access
composition metric.

Definition used for the derived CSVs:

```text
estimated_local_accesses = local_refault / sampling_rate
                         = local_refault * 10     # sampling rate is 10%

local_access_ratio =
  estimated_local_accesses /
  (estimated_local_accesses + remote_hint_faults)
```

Fast variant:

```text
estimated_fast_local_accesses = local_refault_hit * 10

fast_local_access_ratio =
  estimated_fast_local_accesses /
  (estimated_fast_local_accesses + remote_hint_faults)
```

Important terminology:

- `local_access_ratio`: uses all local refaults, regardless of reuse time.
- `fast_local_access_ratio`: uses only local refaults within
  `LOCAL_FAULT_HIT_MS=1000`.
- The user asked what "fast ratio" means; answer: it is the access ratio after
  counting only pages refaulted within 1 second of local PTE_NONE installation.

Derived files:

- Summary:
  `/Serverless/iccd/experiments/20260529-local-fault-latency-pr-silo/summaries/local_access_ratio_summary.csv`
- PR 5s:
  `/Serverless/iccd/experiments/20260529-local-fault-latency-pr-silo/summaries/pr_local_access_ratio_5s.csv`
- Silo 5s:
  `/Serverless/iccd/experiments/20260529-local-fault-latency-pr-silo/summaries/silo_local_access_ratio_5s.csv`
- Notes:
  `/Serverless/iccd/experiments/20260529-local-fault-latency-pr-silo/notes/local_access_ratio_summary.md`

Aggregate values:

| workload | range | local access ratio | fast local access ratio |
| --- | --- | ---: | ---: |
| PR | after60s | 42.97% | 7.07% |
| Silo | after60s | 24.02% | 22.30% |

PR window-level examples from
`pr_local_access_ratio_5s.csv`:

| time | local ratio | fast local ratio | note |
| ---: | ---: | ---: | --- |
| 60s | 0.30% | 0.00% | mostly remote faults |
| 90s | 45.31% | 26.77% | mixed |
| 110s | 68.24% | 45.50% | local share rises |
| 130s | 98.61% | 96.89% | local and fast-local both high |
| 150s | 42.92% | 23.32% | mixed |
| 190s | 66.62% | 56.01% | mixed, fast component visible |
| 230s | 98.19% | 95.30% | local and fast-local both high |
| 270s | 63.56% | 33.72% | mixed |
| 390s | 85.73% | 59.13% | high local ratio |
| 470s | 71.74% | 21.44% | local high, fast lower |
| 550s | 71.29% | 48.23% | high local ratio |
| 590s | 36.57% | 20.95% | mixed |

Interpretation:

- PR's all-local access ratio can be high in many 5s windows.
- However the fast-local ratio is often much lower.
- This explains the apparent tension:
  - if the controller uses all local refaults, PR can look like a stop
    candidate;
  - if it uses the 1s fast-hit signal, PR generally does not stop.
- The next design choice is whether the stop criterion should be based on:
  - all local reuse,
  - fast local reuse,
  - both local/remote access composition and reuse latency,
  - or a stability condition across consecutive windows.

## Current Controller Stop Logic Context

The controller currently supports:

- local condition based on `local_access_signal`:
  - `fast`: `refault_hit / pte_updates`
  - `access`: `refault / pte_updates`
- remote condition based on estimated residual remote access ratio.
- toggle/re-enable mode with `reenable_consecutive`.
- round mode:
  - arm local sampled PTEs over several windows,
  - freeze local fault insertion,
  - observe refaults,
  - then decide.

The recent local access ratio analysis is not yet directly wired as the stop
condition. It is a derived metric computed from existing CSV data.

Potential next implementation direction:

- Add an optional stop condition based on:

```text
estimated_local = local_refault / sample_rate
total_estimated = estimated_local + remote_hint_faults
local_access_ratio = estimated_local / total_estimated
```

- Decide whether the numerator should use:
  - all `local_refault`, or
  - only `local_refault_hit`.
- If using all `local_refault`, PR may stop much more often.
- If using `local_refault_hit`, PR is more conservative and consistent with
  the previous 1s-latency interpretation.

## Known Caveats

- `numa_local_fault_refault_total_ms` and remote hint latency are reuse-time
  measurements, not page fault handler latency.
- Local fault sampling itself perturbs the workload; local latency runs include
  probing overhead.
- Derived 5s windows are reconstructed from controller CSV deltas. For round
  mode, counters are round-cumulative, so post-processing differences adjacent
  rows within a round.
- Some windows can show 100% local ratio simply because remote hint faults were
  zero in that 5s interval. Interpret with `remote_hint_fault_delta_5s`.
- Existing `/Serverless/iccd/linux` worktree is dirty with many kernel changes.
  Do not reset or checkout files unless explicitly requested.
- `/Serverless/iccd` itself does not appear to be a git repo; the kernel tree
  under `/Serverless/iccd/linux` is the git repo.

## Useful Commands

Check no stale VM:

```bash
pgrep -af 'qemu-system-x86_64|run_pr_silo|local-fault-latency|remote-hint-latency' || true
```

Inspect PR local access windows:

```bash
column -s, -t < /Serverless/iccd/experiments/20260529-local-fault-latency-pr-silo/summaries/pr_local_access_ratio_5s.csv | less -S
```

Inspect local latency summary:

```bash
cat /Serverless/iccd/experiments/20260529-local-fault-latency-pr-silo/summaries/local_fault_latency_summary.csv
```

Inspect access ratio summary:

```bash
cat /Serverless/iccd/experiments/20260529-local-fault-latency-pr-silo/summaries/local_access_ratio_summary.csv
```

Re-run PR/Silo local latency experiment:

```bash
/Serverless/iccd/experiments/20260529-local-fault-latency-pr-silo/notes/run_pr_silo_local_latency.sh
```

Re-run PR/Silo remote hint latency experiment:

```bash
/Serverless/iccd/experiments/20260529-remote-hint-latency-pr-silo/notes/run_pr_silo_remote_latency.sh
```

## Suggested Next Step

Clarify the controller objective before adding a new stop condition:

- If the goal is "turn off migration when local memory is actively and quickly
  reused", keep using the fast-hit style signal.
- If the goal is "turn off migration when the workload's current access mix is
  mostly local regardless of reuse time", use all local refaults in the new
  `local_access_ratio`.
- For PR specifically, these choices diverge sharply:
  - after60s all-local ratio: 42.97%
  - after60s fast-local ratio: 7.07%
