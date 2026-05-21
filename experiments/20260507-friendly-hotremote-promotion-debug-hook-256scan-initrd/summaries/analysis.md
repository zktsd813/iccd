# Friendly Hotremote Promotion Debug

Date: 2026-05-07

## Setup

- Kernel tree: `/Serverless/Migration-friendly/linux`
- Kernel image: `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`
- Kernel in guest: `Linux kernel 6.18.0modified #121 SMP PREEMPT_DYNAMIC Thu May 7 16:47:15 UTC 2026`
- Fresh initrd: `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260507T164413Z-promotion-debug.img`
- VM: KVM, `MEMORY=96G`, `CPUS=32`, `HOST_CPUS=0-31`
- NUMA binding: guest node0 32G on host node0, guest node1 64G on host node2 CXL, `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1`
- Cgroup cap: `CAPACITY_PAGES=4194304` (16 GiB)
- Knobs: `GLOBAL_NUMA_ON=0`, `NODE_BALANCING_ON=2`, `KSWAPD_DEMOTION_ON=1`, `OFF_DEMOTION_ON=1`
- Scan: `NUMA_SCAN_SIZE_MB=256`, `SCAN_PERIOD_SCALE=1`, `HOT_THRESHOLD_MS=0`
- MGLRU runtime: `/sys/kernel/mm/lru_gen/enabled = 0x0007`
- Placement: local-first-touch baseline with hotset-only remote first-touch
- Workload: `skew_lf_hotremote_4g_fixed_rss16g_mulshift_persistent`, policy `on`, 60s, 32 threads

## Result

| metric | value |
| --- | ---: |
| throughput mean | `989.29 Mops/s` |
| throughput median | `603.85 Mops/s` |
| promoted | `1,048,570` pages, `4.00 GiB` |
| demoted | `1,074,048` pages, `4.10 GiB` |
| vmstat demoted | `1,053,312` pages |
| hint faults | `3,080,392` |
| promotion candidates | `1,621,530` |
| promotion over-high failures | `572,637` |
| pgmigrate_fail | `572,643` |

## Debug Interpretation

- Reclaimd is no longer stuck at the balanced check. It entered three measured shrink cycles, reached the MGLRU scan/evict path, and demoted about 4 GiB.
- Promotion is now real: the friendly 4 GiB remote hotset was promoted almost exactly once.
- Promotion candidate gating:
  - `debug_promote_enter = 2,975,533`
  - `debug_promote_latency_pass = 1,621,530`
  - `debug_promote_latency_fail = 1,353,995`
  - `debug_promote_rate_limited = 0`
  - `debug_promote_wmark_bypass = 8`
  - `debug_promote_wmark_no_bypass = 2,975,525`
- The remaining failures are after candidacy: `numa_migrate_fail_promotion_over_high = 572,637`. This is destination headroom timing, not rate limiting.

## Artifacts

- Main run: `/Serverless/iccd/experiments/20260507-friendly-hotremote-promotion-debug-hook-256scan-initrd/qemu-logs/phase_candidate_microbench/promotion_debug_friendly_on_20260507T165116Z`
- Summary JSON: `/Serverless/iccd/experiments/20260507-friendly-hotremote-promotion-debug-hook-256scan-initrd/qemu-logs/phase_candidate_microbench/promotion_debug_friendly_on_20260507T165116Z/guest-artifacts/promotion_debug_friendly_on_20260507T165116Z/skew_lf_hotremote_4g_fixed_rss16g_mulshift_persistent__on__rep1/summary.json`

