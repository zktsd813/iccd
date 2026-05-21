# Friendly Hotremote Reclaimd/EAGAIN Check

Date: 2026-05-07 UTC

## Build And Boot

- Kernel tree: `/Serverless/Migration-friendly/linux`
- Kernel image: `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`
- Guest kernel: `Linux kernel 6.18.0modified #115 SMP PREEMPT_DYNAMIC Thu May  7 16:05:12 UTC 2026 x86_64`
- Fresh initrd: `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260507T160220Z-reclaimd-eagain.img`
- Kernel/initrd build used all CPUs: launcher `--build-initrd` reported `jobs=64`, and the host has `nproc=64`.
- MGLRU config: `CONFIG_LRU_GEN=y`, `CONFIG_LRU_GEN_ENABLED=y`, `CONFIG_LRU_GEN_STATS=y`, `CONFIG_LRU_GEN_WALKS_MMU=y`
- Guest runtime MGLRU: `lru_gen_enabled=0x0007`, `lru_gen_min_ttl_ms=0`

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
- placement: local-first-touch before measurement, with only the friendly hotset/window first-touched on remote node1
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
| node1 | `51883786240` | `48.321` |

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
| throughput, steady mean | `317.41 Mops/s` |
| throughput, steady median | `563.68 Mops/s` |
| steady CV | `0.937` |
| promoted pages | `0` |
| promoted GiB | `0.000` |
| demoted pages, direct + kswapd | `0` |
| demoted GiB | `0.000` |
| hint faults | `20,910,943` |
| promotion candidates | `10,969,306` |
| promotion over-high rejects | `10,969,272` |
| pgmigrate fail | `10,969,272` |
| pgscan direct / kswapd | `0 / 0` |
| pgsteal direct / kswapd | `0 / 0` |
| reclaimd wake / run | `1 / 1` |

## Interpretation

Promotion is still not working in this run. The hotset becomes a promotion
candidate, and the new `-EAGAIN` retry route is visible because failed promotion
attempts now also show up as `pgmigrate_fail`. However, no destination folio is
successfully allocated on node0 and `pgpromote_success` remains zero.

The blocking condition is still node0 headroom. Node0 starts at the high
watermark and remains there during the measured window. `memcg_reclaimd` wakes
and runs, but it does not scan, steal, or demote any pages:
`pgscan_direct=0`, `pgscan_kswapd=0`, `pgsteal_direct=0`, `pgsteal_kswapd=0`,
`pgdemote_direct=0`, and `pgdemote_kswapd=0`.

Compared with the prior MGLRU-on run, the patch changed failure accounting:
the over-high path now flows through migration retry/failure accounting rather
than silently bypassing `pgmigrate_fail`. It did not yet create the reclaim
headroom needed for successful promotion.

## Artifacts

- Run root: `/Serverless/iccd/experiments/20260507-friendly-hotremote-reclaimd-eagain-256scan-initrd/qemu-logs/phase_candidate_microbench/reclaimd_eagain_friendly_on_20260507T160220Z`
- Guest artifacts: `/Serverless/iccd/experiments/20260507-friendly-hotremote-reclaimd-eagain-256scan-initrd/qemu-logs/phase_candidate_microbench/reclaimd_eagain_friendly_on_20260507T160220Z/guest-artifacts/reclaimd_eagain_friendly_on_20260507T160220Z`
- Per-run summary: `skew_lf_hotremote_4g_fixed_rss16g_mulshift_persistent__on__rep1/summary.json`
