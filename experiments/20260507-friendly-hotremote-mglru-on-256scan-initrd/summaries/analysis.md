# Friendly Hotremote MGLRU-On Check

Date: 2026-05-07 UTC

## Correction

This run corrects the previous PF_KSWAPD diagnostic detour. The temporary
`memcg_reclaimd()` PF_KSWAPD change was reverted before this build. This run
tests the VM kernel with Multi-gen LRU enabled.

## Build

- Kernel tree: `/Serverless/Migration-friendly/linux`
- Kernel image: `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`
- Kernel: `Linux kernel 6.18.0modified #113 SMP PREEMPT_DYNAMIC Thu May  7 15:28:20 UTC 2026`
- Initrd: `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260507T152933Z-mglru.img`
- Kernel build used all CPUs: `make -C /Serverless/Migration-friendly/linux -j$(nproc) bzImage modules`, with `nproc=64`.
- Initrd module stage used all CPUs for `modules_install`: `make -C /Serverless/Migration-friendly/linux -j$(nproc) modules_install ...`.
- MGLRU config:
  - `CONFIG_LRU_GEN=y`
  - `CONFIG_LRU_GEN_ENABLED=y`
  - `CONFIG_LRU_GEN_STATS=y`
  - `CONFIG_LRU_GEN_WALKS_MMU=y`
- Runtime MGLRU state in the guest: `lru_gen_enabled=0x0007`, `lru_gen_min_ttl_ms=0`.

## VM

- KVM: yes, QEMU `accel=kvm`
- VM CPUs: `CPUS=32`, `HOST_CPUS=0-31`, guest node0 CPUs `0-31`
- VM memory: `MEMORY=96G`
- guest node0: `32G`, host node0, `NUMA_NODE0_HOST_NODES=0`
- guest node1: `64G`, host node2 CXL, `NUMA_NODE1_HOST_NODES=2`
- QEMU memory policy: `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1`
- Guest NUMA: node0 CPUs `0-31`, node1 memory-only

## Knobs

- cgroup cap: `CAPACITY_PAGES=4194304` (`16 GiB`)
- migration policy: `GLOBAL_NUMA_ON=0`, `NODE_BALANCING_ON=2`
- demotion: `KSWAPD_DEMOTION_ON=1`, `OFF_DEMOTION_ON=1`
- scan tuning: `NUMA_SCAN_SIZE_MB=256`, effective `256`, `SCAN_PERIOD_SCALE=1`, `HOT_THRESHOLD_MS=0`
- placement: local-first-touch before measurement, with the friendly hotset/window first-touched on remote node1
- prefault settle: `PREFAULT_SETTLE_RECLAIMD=0`

## Workload

- Candidate: `skew_lf_hotremote_4g_fixed_rss16g_mulshift_persistent`
- Policy: `on`
- Command included:
  - `--arena-size 64G`
  - `--mode skewed-hotset`
  - `--window-size 4G`
  - `--hotset-pages 1048576`
  - `--hot-prob-pct 100`
  - `--hotset-read-pct 100`
  - `--hotset-index-mode mulshift`
  - `--hotset-prefault-node 1`
  - `--threads 32`
  - `--duration-ms 60000`

Initial measured residency after prefault:

| node | anon bytes | GiB |
| --- | ---: | ---: |
| node0 | `16836227072` | `15.680` |
| node1 | `51883499520` | `48.320` |

Node0 watermark state before measurement:

| field | pages | GiB |
| --- | ---: | ---: |
| capacity | `4194304` | `16.000` |
| low watermark | `3984588` | `15.200` |
| high watermark | `4110417` | `15.680` |
| usage exact | `4110417` | `15.680` |
| over high | `1` | |

## Result

| metric | value |
| --- | ---: |
| throughput, steady mean | `620.16 Mops/s` |
| throughput, steady median | `609.03 Mops/s` |
| promoted pages | `0` |
| promoted GiB | `0.000` |
| demoted pages, direct + kswapd | `0` |
| demoted GiB | `0.000` |
| hint faults | `9,457,385` |
| promotion candidates | `8,408,803` |
| promotion over-high rejects | `8,408,803` |
| pgscan direct / kswapd | `0 / 0` |
| pgsteal direct / kswapd | `0 / 0` |
| reclaimd wake / run | `1 / 1` |

## Interpretation

MGLRU was definitely enabled in the guest, but it did not restore demotion in
this configuration. `memcg_reclaimd` woke and ran once, but the reclaim counters
show no scan or steal work: `pgscan_direct=0`, `pgscan_kswapd=0`,
`pgsteal_direct=0`, `pgsteal_kswapd=0`, and both demotion counters stayed zero.

Promotion candidates still formed, so this is not candidate absence. The block
remains the destination node0 over-high gate: node0 started exactly at the high
watermark, stayed there through the measured window, and all `8.4M` promotion
candidates were rejected by `numa_migrate_fail_promotion_over_high`.

Compared with the accidental PF_KSWAPD diagnostic run, enabling MGLRU alone is
not equivalent to making `memcg_reclaimd` a kswapd path. The current evidence is
that MGLRU-on + PF_KSWAPD-off still leaves reclaimd unable to create node0
headroom for this workload.

## Artifacts

- Run root: `/Serverless/iccd/experiments/20260507-friendly-hotremote-mglru-on-256scan-initrd/qemu-logs/phase_candidate_microbench/mglru_friendly_on_20260507T153026Z`
- Guest artifacts: `/Serverless/iccd/experiments/20260507-friendly-hotremote-mglru-on-256scan-initrd/qemu-logs/phase_candidate_microbench/mglru_friendly_on_20260507T153026Z/guest-artifacts/mglru_friendly_on_20260507T153026Z`
- Run metadata: `run_meta.txt`
- Per-run summary: `skew_lf_hotremote_4g_fixed_rss16g_mulshift_persistent__on__rep1/summary.json`
