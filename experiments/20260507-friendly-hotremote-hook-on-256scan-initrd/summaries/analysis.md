# Friendly Hotremote Hook Run

Date: 2026-05-07

## Run

- Run ID: `hook_friendly_on_20260507T144242Z`
- Artifact root: `/Serverless/iccd/experiments/20260507-friendly-hotremote-hook-on-256scan-initrd/qemu-logs/phase_candidate_microbench/hook_friendly_on_20260507T144242Z`
- Kernel image: `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`
- Initrd image: `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260507T144157Z-hook.img`
- Guest kernel: `Linux kernel 6.18.0modified #110 SMP PREEMPT_DYNAMIC Thu May 7 14:40:55 UTC 2026 x86_64`
- QEMU acceleration: `kvm`
- VM topology: `CPUS=32`, `HOST_CPUS=0-31`, guest node0 CPUs `0-31`
- Guest memory: node0 `32G` on host node0, node1 `64G` on host node2 CXL
- QEMU memory policy: `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1`
- Cgroup cap: `CAPACITY_PAGES=4194304` pages, `ARENA_SIZE=64G`
- NUMA/demotion knobs: `GLOBAL_NUMA_ON=0`, `NODE_BALANCING_ON=2`, `KSWAPD_DEMOTION_ON=1`, `OFF_DEMOTION_ON=1`
- Scan tuning: `NUMA_SCAN_SIZE_MB=256`, `SCAN_PERIOD_SCALE=1`, `HOT_THRESHOLD_MS=0`
- Placement: local-first-touch arena, hotset-only remote placement, no reclaimd settle (`PREFAULT_SETTLE_RECLAIMD=0`)

## Result

| candidate | policy | throughput | promoted | demoted | hint faults |
| --- | --- | ---: | ---: | ---: | ---: |
| `skew_lf_hotremote_4g_fixed_rss16g_mulshift_persistent` | on | 649.59 Mops/s | 0 pages / 0.00 GiB | 0 pages / 0.00 GiB | 14,620,875 |

Initial measured placement:

| metric | value |
| --- | ---: |
| anon node0 | 15.68 GiB |
| anon node1 | 48.32 GiB |
| node0 usage exact | 4,110,417 pages |
| node0 low watermark | 3,984,588 pages |
| node0 high watermark | 4,110,417 pages |

## Hook Counters

| counter | pages/events |
| --- | ---: |
| `numa_dbg_hint_tier` | 14,620,875 |
| `numa_dbg_should_enter` | 14,620,875 |
| `numa_dbg_target_none` | 1,048,578 |
| `numa_dbg_target_candidate` | 13,572,297 |
| `numa_dbg_wmark_bypass` | 0 |
| `numa_dbg_free_bypass` | 0 |
| `numa_dbg_wmark_fallback` | 14,620,875 |
| `numa_dbg_latency_fail` | 1,048,578 |
| `numa_dbg_latency_pass` | 13,572,297 |
| `numa_dbg_rate_limited` | 0 |
| `numa_dbg_rate_pass` | 13,572,297 |
| `numa_migrate_fail_promotion_over_high` | 13,572,297 |
| `numa_migrate_success_promotion` | 0 |
| `vmstat.pgpromote_candidate` | 13,571,172 |
| `vmstat.pgpromote_success` | 0 |
| `vmstat.pgmigrate_fail` | 0 |

Average latency from hook totals:

- Latency-fail events: about 29,275 ms/event.
- Latency-pass events: about 60 ms/event.

## Interpretation

This run disproves the "candidate never forms" explanation for the current
local-first-touch friendly run. The hotset becomes a promotion candidate:
`target_candidate`, `latency_pass`, `rate_pass`, and `pgpromote_candidate` all
increase by about 13.57M pages/events.

The failure is after candidacy. Every candidate that passed the hotness/rate
checks was rejected by the destination-node headroom/over-high gate:
`numa_migrate_fail_promotion_over_high=13,572,297` and promotion success stayed
zero.

With `CAPACITY_PAGES=4194304`, the current high reserve is `capacity >> 4`,
262,144 pages. That means promotion redirect headroom requires projected node0
usage at or below 3,932,160 pages, about 15.00 GiB. The run started and stayed
near 4,110,417 pages, about 15.68 GiB, until process teardown. Therefore the
normal promotion path selected candidates but could not allocate destination
folios on node0.

The next kernel fix should be aimed at this promotion headroom/over-high gate
or at making reclaimd/demotion create enough node0 headroom before promotion.
It is not a rate-limit problem, not a hot-threshold candidate problem, and not
an allocation failure in the ordinary `pgmigrate_fail` sense.

## Post-Run Cleanup

The temporary hook was removed after this run. The hook-free kernel was rebuilt
with all CPUs as `#111`, and a fresh no-hook initrd was created for subsequent
experiments:

- Kernel image: `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`
- Initrd image: `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260507T145532Z-nohook.img`
