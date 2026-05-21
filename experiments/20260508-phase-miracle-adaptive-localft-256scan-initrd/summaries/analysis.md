# Phase Miracle/Adaptive, Local-First-Touch

Date: 2026-05-08

## Verdict

`oracle_cgroup_global0` works as the miracle/adaptive baseline: it keeps the
friendly benefit while avoiding almost all sparse-phase damage.

| scope | off baseline | full-on baseline | miracle/adaptive | miracle vs off | miracle vs full-on |
| --- | ---: | ---: | ---: | ---: | ---: |
| overall 6-phase mean | `595.43 Mops/s` | `1255.80 Mops/s` | `1329.82 Mops/s` | `2.233x` | `1.059x` |
| friendly phases, `mulshift-hotset-4g-fixed` | `941.63 Mops/s` | `2365.81 Mops/s` | `2412.79 Mops/s` | `2.562x` | `1.020x` |
| unfriendly phases, `sparse-stride-read-64g-block2m` | `253.49 Mops/s` | `157.53 Mops/s` | `251.46 Mops/s` | `0.992x` | `1.596x` |

Interpretation: full-on already wins overall because friendly phases dominate,
but it hurts unfriendly phases. The miracle/adaptive policy preserves the
friendly steady-state promotion benefit and returns the sparse block2M phases
almost to the migration-off baseline.

## Run Setup

Run:
`/Serverless/iccd/experiments/20260508-phase-miracle-adaptive-localft-256scan-initrd/qemu-logs/phase_candidate_microbench/phase_miracle_adaptive_localft_20260508T000457Z`

| item | value |
| --- | --- |
| candidate | `phase_mulshift4g_block2m_sparse64_localft` |
| policy | `oracle_cgroup_global0` |
| policy meaning | global NUMA balancing off; cgroup migration on for friendly phases and off for sparse phases |
| phase layout | 60s friendly, 60s unfriendly, repeated 3 times |
| placement | local-first-touch, `remote_firsttouch=0` |
| prefault | `PREFAULT_PHASE_GATE=1`, `PREFAULT_SETTLE_RECLAIMD=0` |
| kernel image | `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage` |
| initrd | `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260508T000457Z-phase-miracle.img` |
| guest kernel | `Linux kernel 6.18.0modified #122 SMP PREEMPT_DYNAMIC Thu May 7 23:30:15 UTC 2026 x86_64` |
| initrd build | enabled, `BUILD_JOBS=64` |
| KVM | enabled, QEMU used `-accel kvm` |
| VM | `CPUS=32`, `MEMORY=96G`, `HOST_CPUS=0-31` |
| guest NUMA | node0 CPUs `0-31`, node0 `32G`, node1 `64G` |
| host memory binding | node0 on host node0, node1 on host node2 CXL |
| QEMU memory policy | `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1` |
| cgroup cap | `CAPACITY_PAGES=4194304` (`16 GiB`) |
| scan tuning | `NUMA_SCAN_SIZE_MB=256`, `SCAN_PERIOD_SCALE=1`, `HOT_THRESHOLD_MS=0` |
| MGLRU | `lru_gen_enabled=0x0007` |
| demotion knobs | `KSWAPD_DEMOTION_ON=1`, `OFF_DEMOTION_ON=1` |

Initial measured anon placement after local-first-touch prefault:

| node0 anon | node1 anon |
| ---: | ---: |
| `15.45 GiB` | `48.55 GiB` |

## Overall Counters

| policy | throughput | promoted | demoted | hint faults |
| --- | ---: | ---: | ---: | ---: |
| off baseline | `595.43 Mops/s` | `0` pages (`0.00 GiB`) | `288,874` pages (`1.10 GiB`) | `0` |
| full-on baseline | `1255.80 Mops/s` | `5,377,548` pages (`20.51 GiB`) | `5,462,850` pages (`20.84 GiB`) | `109,231,292` |
| miracle/adaptive | `1329.82 Mops/s` | `709,078` pages (`2.70 GiB`) | `799,617` pages (`3.05 GiB`) | `3,119,897` |

Demotion is reported as `pgdemote_direct + pgdemote_kswapd`.

## Phase Breakdown

| phase | name | off baseline | full-on baseline | miracle/adaptive |
| ---: | --- | ---: | ---: | ---: |
| 1 | `mulshift-hotset-4g-fixed` | `934.27 Mops/s` | `994.09 Mops/s` | `1054.19 Mops/s` |
| 2 | `sparse-stride-read-64g-block2m` | `253.59 Mops/s` | `186.59 Mops/s` | `252.12 Mops/s` |
| 3 | `mulshift-hotset-4g-fixed` | `945.02 Mops/s` | `3050.98 Mops/s` | `3080.96 Mops/s` |
| 4 | `sparse-stride-read-64g-block2m` | `253.91 Mops/s` | `136.52 Mops/s` | `258.05 Mops/s` |
| 5 | `mulshift-hotset-4g-fixed` | `945.61 Mops/s` | `3052.36 Mops/s` | `3103.21 Mops/s` |
| 6 | `sparse-stride-read-64g-block2m` | `252.96 Mops/s` | `149.49 Mops/s` | `244.21 Mops/s` |

The policy controller log confirms the intended phase-aware switching:

| phase | kind | global NUMA | cgroup `node_balancing` |
| ---: | --- | ---: | ---: |
| 1 | friendly | `0` | `2` |
| 2 | sparse | `0` | `0` |
| 3 | friendly | `0` | `2` |
| 4 | sparse | `0` | `0` |
| 5 | friendly | `0` | `2` |
| 6 | sparse | `0` | `0` |

## Notes

- Compared with full-on, miracle/adaptive cuts promotion from `20.51 GiB` to
  `2.70 GiB` and demotion from `20.84 GiB` to `3.05 GiB`.
- Sparse phases are near the off baseline (`0.992x`) while friendly phases are
  slightly above full-on (`1.020x`), likely because sparse-phase churn is
  suppressed.
- This is a one-run miracle baseline, not yet a real detector. A real adaptive
  run should be compared against this upper-bound behavior.
