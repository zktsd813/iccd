# Phase Earlystop Axis

Date: 2026-05-08

## Goal

Add an `earlystop` axis to the phase experiment: run migration-on with both
earlystop and pingpong accounting enabled, and record when migration is stopped
and restarted.

In this run, `cg_earlystop_running=1` means migration is running/allowed.
`cg_earlystop_running=0` means earlystop has stopped migration.

## Setup

| item | value |
| --- | --- |
| policy label | `earlystop` |
| kernel image | `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage` |
| initrd | `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260508T011000Z-earlystop-axis.img` |
| guest kernel | `Linux kernel 6.18.0modified #122 SMP PREEMPT_DYNAMIC Thu May 7 23:30:15 UTC 2026 x86_64` |
| build | fresh initrd, `make -j64 bzImage modules`, `make -j64 modules_install` |
| KVM | enabled (`-accel kvm`) |
| VM topology | `MEMORY=96G`, `CPUS=32`, `HOST_CPUS=0-31`, guest node0 CPUs `0-31` |
| VM memory binding | node0 `32G` on host node0, node1 `64G` on host node2 CXL, `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1` |
| cgroup cap | `CAPACITY_PAGES=4194304` (`16 GiB`) |
| placement | local-first-touch, `remote_firsttouch=0`, `PREFAULT_PHASE_GATE=1`, `PREFAULT_SETTLE_RECLAIMD=0` |
| MGLRU | `/sys/kernel/mm/lru_gen/enabled = 0x0007` |
| scan tuning | `NUMA_SCAN_SIZE_MB=256`, effective `256`, `SCAN_PERIOD_SCALE=1`, `HOT_THRESHOLD_MS=0` |
| migration knobs | `GLOBAL_NUMA_ON=0`, `NODE_BALANCING_ON=2`, `KSWAPD_DEMOTION_ON=1`, `OFF_DEMOTION_ON=1` |
| earlystop knobs | `NUMA_MIGRATION_STOP_ENABLED=1`, `NUMA_PINGPONG_STAT_ENABLED=1`, `NUMA_PROMOTE_SAMPLE_STAT_ENABLED=0` |
| workload | `phase_mulshift4g_block2m_sparse64_localft`, `PHASE_MS=60000`, `PHASE_REPEAT=3` |

`run_meta.txt` and `meta.env` show earlystop/pingpong enabled. The final
`summary.json` cgroup knob fields are not used for that validation because the
runner resets the cgroup after the case; `live.csv` kept
`cg_migration_stop_effective=1` throughout the measured run.

## Result

| policy | overall | friendly mean | sparse mean | promoted | demoted |
| --- | ---: | ---: | ---: | ---: | ---: |
| `earlystop` | `1262.67 Mops/s` | `2385.60 Mops/s` | `152.70 Mops/s` | `4,831,614` pages (`18.43 GiB`) | `5,143,293` pages (`19.62 GiB`) |

Demotion is `pgdemote_direct + pgdemote_kswapd`; `pgdemote_kswapd=0`.

For comparison with the latest no-earlystop/no-pingpong run:

| scope | earlystop vs off | earlystop vs no-earlystop full-on |
| --- | ---: | ---: |
| overall | `2.102x` | `0.909x` |
| friendly phases | `2.513x` | `0.906x` |
| sparse phases | `0.596x` | `0.960x` |

## Stop/Restart Timeline

| elapsed | phase | phase kind | transition | notes |
| ---: | ---: | --- | --- | --- |
| `0.048s` | 1 | friendly | initial `running=1` | migration starts enabled |
| `144.228s` | 3 | friendly | `1 -> 0` | earlystop stops migration |
| `186.142s` | 4 | sparse | `0 -> 1` | restart enables migration again |
| `266.986s` | 5 | friendly | `1 -> 0` | earlystop stops migration again |
| `306.870s` | 6 | sparse | `0 -> 1` | restart enables migration again |

The observed direction is important: this earlystop heuristic did not stop
migration when the workload entered sparse/unfriendly phases. It stopped during
later friendly phases and restarted during sparse phases.

## Phase-Level Migration State

| phase | name | running start -> end | demote-promoted delta | promote-candidate-demoted delta | promoted delta |
| ---: | --- | --- | ---: | ---: | ---: |
| 1 | `mulshift-hotset-4g-fixed` | `1 -> 1` | `0` | `170,547` | `324,205` |
| 2 | `sparse-stride-read-64g-block2m` | `1 -> 1` | `751,365` | `6,365,887` | `2,590,268` |
| 3 | `mulshift-hotset-4g-fixed` | `1 -> 0` | `153,857` | `0` | `0` |
| 4 | `sparse-stride-read-64g-block2m` | `0 -> 1` | `474` | `394,364` | `459,946` |
| 5 | `mulshift-hotset-4g-fixed` | `1 -> 0` | `594,479` | `0` | `0` |
| 6 | `sparse-stride-read-64g-block2m` | `0 -> 1` | `340` | `741,443` | `1,193,879` |

Pingpong-related totals:

- `pgdemote_promoted=2,056,006` pages.
- `pgdemote_promoted_referenced=205,270` pages.
- `pgpromote_candidate_demoted=7,858,717` pages.
- `debug_promote_stopped=4,386,708`.

## Interpretation

This earlystop axis does not solve the unfriendly sparse phase. Sparse
throughput is `152.70 Mops/s`, slightly worse than the no-earlystop full-on
baseline (`159.00 Mops/s`) and still below migration-off (`256.08 Mops/s`).
The main behavioral issue is that the stop/restart timing is inverted relative
to the desired phase policy: it stops in friendly phases and restarts in sparse
phases.

Artifact:

- `/Serverless/iccd/experiments/20260508-phase-earlystop-axis-localft-256scan-initrd/qemu-logs/phase_candidate_microbench/phase_earlystop_20260508T011000Z`
