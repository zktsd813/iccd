# Migration-Friendly Experiment Context

Date: 2026-05-01

Update: the current canonical friendly/unfriendly workload labels changed on
2026-05-07. Before using the older `Current Phase Candidates` section below,
read `/Serverless/iccd/docs/current-migration-workloads-20260507.md`. In short:

- Current friendly phase: `mulshift-hotset-4g-fixed`, carried by runner
  candidate `phase_mulshift4g_sparse64`.
- Current strongest unfriendly standalone candidate:
  `sparse_stride_read_64g_block2m_remoteft`.
- Do not confuse that unfriendly candidate with the older
  `sparse_stride_read_64g_remoteft` or the built-in sparse phase of
  `phase_mulshift4g_sparse64`, both of which use the older 4 KiB block shape.

This file carries the active context from `/Serverless/Migration-friendly` into
`/Serverless/iccd` without overwriting existing ICCD project files.

## ICCD Workspace Mapping

- Kernel tree for ICCD adaptive work:
  `/Serverless/iccd/Adaptive-Migration`
- Existing QEMU and workload harness in the ICCD tree:
  `/Serverless/iccd/Adaptive-Migration/scripts/kernel`
- Paper source:
  `/Serverless/iccd/CXL-migration.paper`
- Baseline TPP kernel:
  `/Serverless/iccd/TPP-5.15`

`Adaptive-Migration/scripts/kernel/README.md` already documents that this harness
was copied from `/Serverless/Migration-friendly/scripts/kernel` and adapted for
the ICCD paper topology/workloads. Treat that harness as the local integration
point for future VM experiments in this workspace.

## Working Hypothesis

The current hypothesis is not that migration is always good. The target result
is to show that migration can help some workload phases but hurt other phases in
the same execution. A practical policy should identify or avoid the harmful
phases rather than enabling migration uniformly.

## Microbenchmark Setup From Migration-Friendly

Main VM topology used for the latest phase experiments:

- Host node0 CPUs are assigned to the VM.
- Guest node0 is backed by host node0 local DRAM.
- Guest node1 is backed by host node2 CXL-like remote memory and is CPU-less.
- VM: 32 vCPUs, 72 GiB memory.
- Guest node0 local capacity: 24 GiB physical, with memcg local cap set to
  `CAPACITY_PAGES=4194304` or 16 GiB.
- Guest node1 remote memory: 48 GiB.
- QEMU launch required `NUMA_PREALLOC=1`.
- The known-good initramfs path in the source workspace was:
  `/Serverless/Migration-friendly/scripts/kernel/qemu-logs/phase_candidate_microbench/initramfs-6.18.0modified-phasecand.img`

Runtime knobs for the main mode-1 runs:

- `KSWAPD_DEMOTION_ON=1`
- `NODE_BALANCING_ON=2`
- `SCAN_PERIOD_SCALE=1`
- `HOT_THRESHOLD_MS=1`
- `LIVE_SAMPLE_SEC=5`
- `ARENA_SIZE=48G`
- `PHASE_MS=60000`
- `PHASE_REPEAT=5`

Each benchmark run has 10 phases, 60 seconds each:

- Odd phases: migration-friendly candidate.
- Even phases: migration-unfriendly streaming/sparse candidate.
- Total measured time per run: 600 seconds.
- Throughput sampled every 5 seconds.

## Current Phase Candidates

Friendly candidate:

- Name: `tail-hotset-4g-move-30s`
- Pattern: skewed/random 4 GiB hotset in the remote/tail side of a 48 GiB arena.
- Hotset moves every 30 seconds.
- Rationale: hotset fits under local capacity, so promotion can improve access
  locality when the hotset is remote.

Unfriendly candidate:

- Name: `sparse-stride-read-24g`
- Pattern: sparse streaming read over a 24 GiB window.
- Effective stride: one 8-byte double per 4 KiB page.
- Rationale: working set exceeds the 16 GiB local cap, so promotion/demotion
  churn can hurt throughput.

Earlier 16 GiB sparse runs were less structurally unfriendly because the sparse
working set matched the 16 GiB cap and could lose its harmful property after
convergence.

## Latest 24 GiB Phase Results

Artifact roots in the source workspace:

- Off/on:
  `/Serverless/Migration-friendly/scripts/kernel/qemu-logs/phase_candidate_microbench/20260501T_phase_tail_sparse24_m1_off_on_r1/guest-artifacts/20260501T_phase_tail_sparse24_m1_off_on_r1/`
- Global-only adaptive:
  `/Serverless/Migration-friendly/scripts/kernel/qemu-logs/phase_candidate_microbench/20260501T_phase_tail_sparse24_m1_adaptive_global/guest-artifacts/20260501T_phase_tail_sparse24_m1_adaptive_global/`
- Cgroup attempt with global=2:
  `/Serverless/Migration-friendly/scripts/kernel/qemu-logs/phase_candidate_microbench/20260501T_phase_tail_sparse24_m1_adaptive_cgroup/guest-artifacts/20260501T_phase_tail_sparse24_m1_adaptive_cgroup/`
- Corrected cgroup oracle with global=0:
  `/Serverless/Migration-friendly/scripts/kernel/qemu-logs/phase_candidate_microbench/20260501T_phase_tail_sparse24_m1_oracle_cgroup_global0/guest-artifacts/20260501T_phase_tail_sparse24_m1_oracle_cgroup_global0/`

Aggregate results:

| Policy | Total Mops/s | Friendly avg Mops/s | Sparse avg Mops/s | Hint faults | Promoted | Demoted |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| off | 247.99 | 287.72 | 208.51 | 0 | 0 GiB | 0 GiB |
| on | 280.51 | 479.11 | 84.75 | 8.86M | 14.76 GiB | 34.75 GiB |
| global adaptive | 282.96 | 488.27 | 82.32 | 7.13M | 11.18 GiB | 28.97 GiB |
| cgroup attempt, global=2 | 251.58 | 396.72 | 110.56 | 11.50M | 20.19 GiB | 29.22 GiB |
| cgroup oracle, global=0 | 216.59 | 316.30 | 119.04 | 4.29M | 9.41 GiB | 24.00 GiB |

Phase-level comparison:

| Phase | Pattern | off | on | global adaptive | cgroup attempt | cgroup oracle |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | friendly | 287.53 | 474.39 | 531.45 | 505.38 | 378.07 |
| 2 | sparse24 | 216.47 | 93.31 | 99.17 | 105.57 | 110.46 |
| 3 | friendly | 288.02 | 557.77 | 567.05 | 369.81 | 309.88 |
| 4 | sparse24 | 185.76 | 89.68 | 74.83 | 119.65 | 109.09 |
| 5 | friendly | 285.96 | 554.85 | 476.38 | 373.05 | 302.20 |
| 6 | sparse24 | 213.06 | 84.78 | 77.84 | 140.12 | 119.00 |
| 7 | friendly | 291.26 | 456.22 | 425.80 | 369.52 | 293.67 |
| 8 | sparse24 | 215.61 | 79.44 | 81.26 | 86.48 | 122.62 |
| 9 | friendly | 285.85 | 352.34 | 440.69 | 365.87 | 297.69 |
| 10 | sparse24 | 211.67 | 76.56 | 78.48 | 100.98 | 134.04 |

## Kernel Knob Semantics Observed

In the Migration-friendly kernel, the cgroup NUMA balancing mode had this
effective behavior:

- cgroup `node_balancing=0` means inherit the global sysctl.
- cgroup `node_balancing=2` explicitly enables mode 2 for that cgroup.
- Therefore `global=2,cgroup=0` is still effectively enabled.
- To explicitly disable a cgroup with the existing semantics, the test used
  `global=0,cgroup=0` during the sparse phase.
- With `global=0,cgroup=2`, the friendly phase was effectively enabled.

Important validation:

- In the corrected cgroup oracle, sparse phases still showed some hint faults
  from already poisoned NUMA PTEs, but `pgpromote_success` stayed zero during
  those sparse phases.
- This means turning effective balancing off can stop promotion even if some
  residual hint faults still occur.

## Current Interpretation

The 24 GiB sparse phase is a strong migration-unfriendly candidate:

- Always-on migration improved friendly phases but heavily hurt sparse phases.
- Correct cgroup disabling improved sparse phases compared with always-on, but
  did not recover the off baseline.

The corrected cgroup oracle hurt friendly phases compared with always-on:

- This is probably due to scan timing, toggling overhead, scanner state, or
  local-cap/demotion interactions.
- It is not because `global=0` prevents cgroup mode 2. The observed effective
  mode during friendly phases was 2.

## Recommended Next Steps In ICCD Workspace

1. Reproduce the 24 GiB phase experiment using
   `/Serverless/iccd/Adaptive-Migration/scripts/kernel` where possible.
2. Align the ICCD launcher with the known topology:
   node0 CPU-bound VM, guest node0 local DRAM, guest node1 CPU-less remote
   memory backed by host node2.
3. If phase-adaptive cgroup control remains the target, add or validate a knob
   that distinguishes inherit from explicit-disable. The current `0 == inherit`
   semantic makes `global=2` plus per-cgroup off impossible.
4. Debug friendly underperformance under the corrected oracle:
   switch lead time, scanner warmup, exact phase transition timing, and whether
   demotion state lags across phase boundaries.
5. Keep reporting both 5-second window throughput and total throughput. The
   window view shows phase behavior, while total throughput shows whether the
   adaptive policy wins end to end.

## ICCD Continuation Progress

Date: 2026-05-01

Harness integration work completed in `/Serverless/iccd/Adaptive-Migration`:

- Imported the Migration-friendly `Microbenchmark` source into
  `Adaptive-Migration/Microbenchmark`.
- Imported the phase candidate host/guest runners:
  `scripts/kernel/run_qemu_phase_candidate_microbench.sh`
  and `scripts/kernel/run_phase_candidate_microbench_guest.sh`.
- Updated `scripts/kernel/launch_kernel_qemu.sh` so it can reproduce the known
  phase topology with `taskset`, host NUMA memory binding, and
  `prealloc=on`.
- Set the phase runner defaults to the latest 24 GiB sparse experiment:
  32 vCPUs, 72 GiB memory, guest node0 24 GiB, guest node1 48 GiB,
  host node0 CPUs, host node0 local memory, host node2 remote memory,
  16 GiB cgroup local cap, `ARENA_SIZE=48G`, `PHASE_MS=60000`,
  `PHASE_REPEAT=5`, and 5-second live sampling.
- Added guest-runner policy modes for the latest adaptive variants:
  `adaptive_global`, `adaptive_cgroup`, and `oracle_cgroup_global0`.

Validation completed:

- `make -C Microbenchmark` builds `mbench`.
- `bash -n` passes for the updated launcher and both phase runner scripts.
- A QEMU dry-run produces the intended command shape:
  `taskset -c 0-31`, `-smp 32`, `-m 72G`, node0 `24G` on host node0,
  node1 `48G` on host node2, and `prealloc=on`.

Current blocker:

- The ICCD `refaultnearly-multitenant` kernel does not yet contain the
  Migration-friendly memcg NUMA knobs required by the phase runner:
  `memory.node_capacity`, `memory.node_balancing`,
  `memory.kswapd_demotion_enabled`,
  `memory.numa_balancing_scan_period_scale`, and
  `memory.numa_balancing_hot_threshold_ms`.
- In the source kernel, these hooks span at least
  `include/linux/memcontrol.h`, `mm/memcontrol.c`,
  `kernel/sched/fair.c`, and `mm/vmscan.c`. They are not present in the ICCD
  kernel tree as of this continuation.
