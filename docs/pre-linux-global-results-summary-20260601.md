# Pre-linux-global Experiment Summary

Generated: 2026-06-01

This file preserves the main results from experiment directories created before
the linux-global cleanup point. The raw directories listed in
`docs/removed-pre-linux-global-experiments-20260601.txt` were treated as
removable after this summary was written.

## Scope

- Removed experiment directories: 181
- Date range: 2026-05-07 through 2026-05-29
- Baseline cutoff kept in `experiments/`: `20260530-linux-global-*` and later
- Main topic: NUMA balancing / migration friendliness under limited local DRAM
  with CXL-backed remote memory

## Kernel And Policy Evolution

- Early cgroup memory-tiering experiments showed that promotion could stall
  when the cgroup-local tier had no effective headroom. The kernel work added
  local-fault sampling and cgroup migration state counters so a userspace
  controller could decide when migration should be stopped.
- The local-fault mechanism sampled local PTE invalidations and counted
  refaults, fast refault hits, lost samples, and reuse latency. The important
  interpretation is that `numa_local_fault_refault_total_ms` measures time from
  local PTE_NONE installation to later local refault, not page fault service
  time.
- The early implementation used cgroup-facing knobs. Later linux-global work
  moved the active direction toward global sysfs knobs and away from the
  temporary cgroup knob surface.

## Ours Controller

- The reusable policy core was `local_util_adapt_controller.py` plus the common
  cgroup runner. It monitored local refault/access evidence and toggled
  `memory.node_balancing`.
- For GAPBS PR/BC and other workloads, valid runs should use prebuilt GAPBS
  graphs with `-f /root/gapbs_graphs/kron_g28.sg` rather than rebuilding with
  `-g` inside every measured run.
- Important controller modes tested:
  - fast local-refault hit ratio
  - local-access ratio estimated from sampled local refaults
  - composition ratio combining fast and slow local refaults against remote
    hint faults

## Representative Workload Results

### PR g28, 8 GiB cgroup local cap, off vs ours

Source summary:
`experiments/20260510-pr-g28-local8-off-ours/summaries/pr_g28_i20n3_local8_off_ours_summary.md`

| policy | trial_avg_s | elapsed_s | note |
| --- | ---: | ---: | --- |
| off | 19.128 | 273 | migration disabled from start |
| ours | 19.248 | 315 | controller stopped migration at 170.701s |

The measured PageRank trials were effectively equal: ours/off trial time was
1.006x. The larger E2E gap came from graph generation/build time while migration
and sampling were still active.

### BC g28, 8 GiB cgroup local cap, off/on/ours

Source summary:
`experiments/20260510-bc-g28-local8-off-on-ours-fixedsrc/summaries/bc_g28_i1n10_r11861354_local8_off_on_ours_summary.md`

| policy | trial_avg_s | elapsed_s | note |
| --- | ---: | ---: | --- |
| off | 13.955 | 364 | baseline |
| on | 36.333 | 735 | migration stays active and slows later trials |
| ours | 14.062 | 389 | migration stopped before trial phase |

Ours matched off for the measured BC trials while on was 2.60x slower than off.

### Physical 8 GiB local node, all-workload ours-toggle w5

Source summary:
`experiments/20260528-phys8g-allworkloads-ours-toggle-w5/summaries/final-summary.md`

| workload | elapsed_s | final controller state | hint_faults | promoted | demoted |
| --- | ---: | --- | ---: | ---: | ---: |
| pr | 234 | off | 7,980,616 | 245,557 | 1,587,843 |
| bc | 428 | off | 13,651,318 | 1,287,263 | 2,150,203 |
| silo | 1029 | off | 33,667,736 | 2,502,786 | 6,805,925 |
| liblinear | 1832 | on | 269,057,482 | 0 | 0 |
| FT | 612 | off | 11,239,629 | 1,426,069 | 1,478,119 |
| LU | 1033 | off | 18,334,384 | 1,360,320 | 1,477,761 |
| SP | 1125 | off | 12,813,269 | 959,772 | 1,095,932 |
| gups | 629 | off | 17,590,954 | 520,534 | 1,601,736 |
| graph500 | 382 | on | 19,845,169 | 3,035,071 | 4,778,779 |
| btree | 786 | off | 16,750,468 | 2,017,374 | 6,640,865 |
| xsbench | 782 | off | 12,165,458 | 808,953 | 2,021,574 |

This run validated the reusable toggle controller over the original workload
set with physical local memory limiting.

### Physical 8/16 GiB local node, on/off baselines after cgroup fix

Source summary:
`experiments/20260527-physlimit-cgfix-8g16g-global02-onoff/summaries/physlimit_cgfix_8g16g_global02_onoff_summary.md`

At 8 GiB local memory, migration helped Silo, FT, SP, btree, and xsbench, but
hurt PR, GUPS, graph500, liblinear, and LU. PR was strongly migration-unfriendly
at 8 GiB: off 30.69s vs on 69.38s. GUPS was also strongly unfriendly: off
656.20s vs on 1223.32s.

At 16 GiB local memory, PR was still worse with migration on, but the gap
shrunk: off 33.66s vs on 41.72s. Silo was mildly better with migration on:
off 794.72s vs on 755.94s.

## PR/Silo Local-Fault And Composition Findings

Source summaries:

- `experiments/20260529-local-fault-latency-pr-silo`
- `experiments/20260529-remote-hint-latency-pr-silo`
- `experiments/20260529-pr-silo-composition-policy-matrix/summaries/result-summary.md`

Remote hint latency aggregate:

| workload | remote hint faults | weighted avg remote hint latency |
| --- | ---: | ---: |
| PR | 80,605,326 | 7.64 ms |
| Silo | 125,004,787 | 31.81 ms |

Local refault latency after 60s:

| workload | local refaults | weighted avg local reuse | fast-hit pct |
| --- | ---: | ---: | ---: |
| PR | 4,673,480 | 8.72 s | 9.57% |
| Silo | 3,645,354 | 11.43 s | 91.85% |

The composition knob was tuned to stop PR but not Silo:

| workload | policy | elapsed_s | avg_trial_s | migration_off_ms | stop_reason |
| --- | --- | ---: | ---: | ---: | --- |
| pr | off | 267 | 29.370 |  |  |
| pr | on | 605 | 72.158 |  |  |
| pr | ours_comp | 562 | 66.848 | 185105 | local_access |
| silo | off | 1091 | 1091 |  |  |
| silo | on | 700 | 700 |  |  |
| silo | ours_comp | 726 | 726 |  |  |

The policy action was differentiated as desired: PR reached the consecutive
local-composition condition and migration was disabled; Silo did not reach the
condition and stayed effectively migration-on.

## PR Slowdown Root Cause Hypothesis

Source summary:
`experiments/20260529-pr-silo-composition-policy-matrix/summaries/pr-root-cause-notes.md`

PR slowed under migration-on because the graph working set was broader than the
8 GiB local tier. Migration generated high hint-fault traffic and page-copy
churn while many promoted pages were not reused quickly enough to pay for the
promotion/demotion cost. Turning migration off late, at 185s, did not reproduce
the baseline-off state because substantial placement and PTE-protection work had
already occurred.

Key counter evidence:

| policy | hint_faults | promote_success | demote_kswapd |
| --- | ---: | ---: | ---: |
| off | 0 | 0 | 0 |
| on | 76,491,924 | 1,581,694 | 2,534,255 |
| ours_comp | 29,168,078 | 1,151,924 | 1,686,164 |

## Preserved Context

- The full list of removed directories is in
  `docs/removed-pre-linux-global-experiments-20260601.txt`.
- Current post-cleanup experiments start from `20260530-linux-global-*`.
- Current reusable code should live in the consolidated `scripts/` directory and
  in the cloned VM harness under `/Serverless/iccd/VM`.
