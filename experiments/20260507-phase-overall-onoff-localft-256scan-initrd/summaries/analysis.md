# Phase Overall On/Off, Local-First-Touch

Date: 2026-05-07

## Verdict

The full-policy migration-on run improves the overall mixed phase workload, but
the phase split shows the intended contrast:

| scope | off | on | on/off |
| --- | ---: | ---: | ---: |
| overall 6-phase mean | `595.43 Mops/s` | `1255.80 Mops/s` | `2.109x` |
| friendly phases, `mulshift-hotset-4g-fixed` | `941.63 Mops/s` | `2365.81 Mops/s` | `2.512x` |
| unfriendly phases, `sparse-stride-read-64g-block2m` | `253.49 Mops/s` | `157.53 Mops/s` | `0.621x` |

This means the current full-on/full-off phase experiment confirms both sides:
full migration-on helps the friendly portions enough to dominate the aggregate,
while it hurts the sparse block2M unfriendly portions.

## Run Setup

Run:
`/Serverless/iccd/experiments/20260507-phase-overall-onoff-localft-256scan-initrd/qemu-logs/phase_candidate_microbench/phase_overall_onoff_localft_20260507T233548Z`

| item | value |
| --- | --- |
| candidate | `phase_mulshift4g_block2m_sparse64_localft` |
| preset | `mulshift4g-block2m-sparse64` |
| policies | `off,on` |
| reps | `1` |
| phase layout | 60s friendly, 60s unfriendly, repeated 3 times |
| placement | local-first-touch, `remote_firsttouch=0` |
| prefault | `PREFAULT_PHASE_GATE=1`, `PREFAULT_SETTLE_RECLAIMD=0` |
| kernel image | `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage` |
| initrd | `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260507T233548Z-phase-onoff.img` |
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
| migration on knobs | `GLOBAL_NUMA_ON=0`, `NODE_BALANCING_ON=2` |
| demotion knobs | `KSWAPD_DEMOTION_ON=1`, `OFF_DEMOTION_ON=1` |

Initial measured anon placement after local-first-touch prefault:

| policy | node0 anon | node1 anon |
| --- | ---: | ---: |
| off | `15.38 GiB` | `48.62 GiB` |
| on | `15.58 GiB` | `48.42 GiB` |

## Overall Counters

| policy | throughput | promoted | demoted | hint faults |
| --- | ---: | ---: | ---: | ---: |
| off | `595.43 Mops/s` | `0` pages (`0.00 GiB`) | `288,874` pages (`1.10 GiB`) | `0` |
| on | `1255.80 Mops/s` | `5,377,548` pages (`20.51 GiB`) | `5,462,850` pages (`20.84 GiB`) | `109,231,292` |

Demotion is reported as `pgdemote_direct + pgdemote_kswapd`.

## Phase Breakdown

| phase | name | off | on | on/off |
| ---: | --- | ---: | ---: | ---: |
| 1 | `mulshift-hotset-4g-fixed` | `934.27 Mops/s` | `994.09 Mops/s` | `1.064x` |
| 2 | `sparse-stride-read-64g-block2m` | `253.59 Mops/s` | `186.59 Mops/s` | `0.736x` |
| 3 | `mulshift-hotset-4g-fixed` | `945.02 Mops/s` | `3050.98 Mops/s` | `3.228x` |
| 4 | `sparse-stride-read-64g-block2m` | `253.91 Mops/s` | `136.52 Mops/s` | `0.538x` |
| 5 | `mulshift-hotset-4g-fixed` | `945.61 Mops/s` | `3052.36 Mops/s` | `3.227x` |
| 6 | `sparse-stride-read-64g-block2m` | `252.96 Mops/s` | `149.49 Mops/s` | `0.591x` |

Interpretation:

- Friendly phase 1 is only mildly improved because promotion ramps during the
  first friendly interval.
- Friendly phases 3 and 5 show the steady-state benefit once the hotset has
  been promoted.
- All sparse block2M unfriendly phases are slower with migration-on, matching
  the standalone local-first-touch validation.

## Notes

- This run used a new local-first-touch runner label,
  `phase_mulshift4g_block2m_sparse64_localft`, because the older
  `phase_mulshift4g_block2m_sparse64` label still sets
  `CANDIDATE_REMOTE_FIRSTTOUCH=1`.
- The guest runner explicitly set and verified MGLRU as `0x0007` before
  emitting run metadata.
- The next phase experiment can compare adaptive/oracle policies against this
  full-off/full-on baseline.
