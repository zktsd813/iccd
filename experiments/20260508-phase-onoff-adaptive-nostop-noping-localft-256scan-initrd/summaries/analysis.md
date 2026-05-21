# Phase On/Off/Adaptive Without Earlystop Or Pingpong Stat

Date: 2026-05-08

## Goal

Rerun the alternating friendly/unfriendly phase workload after disabling the
migration earlystop path and pingpong accounting. The runner defaults were also
changed so ordinary phase runs no longer enable these features implicitly.

## Setup

| item | value |
| --- | --- |
| kernel image | `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage` |
| initrd | `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260508T003500Z-nostop-noping.img` |
| guest kernel | `Linux kernel 6.18.0modified #122 SMP PREEMPT_DYNAMIC Thu May 7 23:30:15 UTC 2026 x86_64` |
| KVM | enabled (`-accel kvm`) |
| VM topology | `MEMORY=96G`, `CPUS=32`, `HOST_CPUS=0-31`, guest node0 CPUs `0-31` |
| VM memory binding | node0 `32G` on host node0, node1 `64G` on host node2 CXL, `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1` |
| cgroup cap | `CAPACITY_PAGES=4194304` (`16 GiB`) |
| placement | local-first-touch, `PREFAULT_PHASE_GATE=1`, `PREFAULT_SETTLE_RECLAIMD=0` |
| MGLRU | `/sys/kernel/mm/lru_gen/enabled = 0x0007` |
| scan tuning | `NUMA_SCAN_SIZE_MB=256`, effective `256`, `SCAN_PERIOD_SCALE=1`, `HOT_THRESHOLD_MS=0` |
| migration knobs | `GLOBAL_NUMA_ON=0`, `NODE_BALANCING_ON=2`, `KSWAPD_DEMOTION_ON=1`, `OFF_DEMOTION_ON=1` |
| disabled diagnostics | `NUMA_MIGRATION_STOP_ENABLED=0`, `NUMA_PINGPONG_STAT_ENABLED=0`, `NUMA_PROMOTE_SAMPLE_STAT_ENABLED=0` |
| workload | `phase_mulshift4g_block2m_sparse64_localft`, `PHASE_MS=60000`, `PHASE_REPEAT=3` |

Validation from `live.csv`:

- `cg_migration_stop_effective` stayed `0` for all policies.
- `cg_earlystop_running` stayed `1` in live samples; no earlystop transition
  occurred.
- `cg_promote_sampled` delta was `0`; promote sampling was disabled.
- `vmstat.pgdemote_promoted` and `vmstat.pgpromote_sampled` stayed `0`, as
  expected with pingpong/promote sampling disabled.

## Results

| policy | overall | friendly mean | sparse mean | promoted | demoted |
| --- | ---: | ---: | ---: | ---: | ---: |
| `off` | `600.66 Mops/s` | `949.14 Mops/s` | `256.08 Mops/s` | `0` pages (`0.00 GiB`) | `176,404` pages (`0.67 GiB`) |
| `on` | `1388.38 Mops/s` | `2633.09 Mops/s` | `159.00 Mops/s` | `5,229,907` pages (`19.95 GiB`) | `5,249,549` pages (`20.03 GiB`) |
| `oracle_cgroup_global0` | `1324.07 Mops/s` | `2408.90 Mops/s` | `251.81 Mops/s` | `692,335` pages (`2.64 GiB`) | `771,538` pages (`2.94 GiB`) |

Demotion is `pgdemote_direct + pgdemote_kswapd`; `pgdemote_kswapd` was `0` in
all three runs.

## Ratios

| scope | full-on vs off | adaptive vs off | adaptive vs full-on |
| --- | ---: | ---: | ---: |
| overall | `2.311x` | `2.204x` | `0.954x` |
| friendly phases | `2.774x` | `2.538x` | `0.915x` |
| sparse phases | `0.621x` | `0.983x` | `1.584x` |

## Adaptive Controller

The adaptive/oracle policy kept global NUMA balancing off and switched only the
cgroup knob:

```text
phase=1 kind=friendly cgroup_node_balancing=2
phase=2 kind=sparse   cgroup_node_balancing=0
phase=3 kind=friendly cgroup_node_balancing=2
phase=4 kind=sparse   cgroup_node_balancing=0
phase=5 kind=friendly cgroup_node_balancing=2
phase=6 kind=sparse   cgroup_node_balancing=0
```

## Interpretation

Disabling earlystop and pingpong stat does not change the main phase behavior:
full migration-on still improves friendly phases strongly, but it still hurts
the sparse block2M phases at about `0.621x` of migration-off. The adaptive
oracle recovers sparse performance to near off (`0.983x`) and cuts migration
volume from about `20 GiB` to about `3 GiB`.

In this no-diagnostic run, full-on overall is higher than adaptive overall
(`1388.38` vs `1324.07 Mops/s`) because the friendly phases dominate the full
six-phase mean and full-on keeps more of the friendly hotset promoted across
phase transitions. Adaptive is still the correct upper-bound behavior for
avoiding sparse-phase migration damage.

Artifacts:

- On/off run: `/Serverless/iccd/experiments/20260508-phase-onoff-adaptive-nostop-noping-localft-256scan-initrd/qemu-logs/phase_candidate_microbench/phase_onoff_nostop_noping_20260508T003500Z`
- Adaptive run: `/Serverless/iccd/experiments/20260508-phase-onoff-adaptive-nostop-noping-localft-256scan-initrd/qemu-logs/phase_candidate_microbench/phase_adaptive_nostop_noping_20260508T005500Z`
