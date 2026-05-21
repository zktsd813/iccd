# Friendly Hotremote PF_KSWAPD Reclaimd Run

Date: 2026-05-07

## Change Under Test

`memcg_reclaimd()` was changed to set `PF_KSWAPD` in addition to `PF_MEMALLOC`
while it runs. MGLRU is not enabled in this kernel config:

```text
# CONFIG_LRU_GEN is not set
```

This reopens vmscan paths guarded by `current_is_kswapd()`, including
force-LRU fail-streak handling and `pgdemote_kswapd` accounting.

## Run

- Run ID: `pfkswapd_friendly_on_20260507T151539Z`
- Artifact root: `/Serverless/iccd/experiments/20260507-friendly-hotremote-pfkswapd-on-256scan-initrd/qemu-logs/phase_candidate_microbench/pfkswapd_friendly_on_20260507T151539Z`
- Kernel image: `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`
- Initrd image: `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260507T151455Z-memcgpfkswapd.img`
- Guest kernel: `Linux kernel 6.18.0modified #112 SMP PREEMPT_DYNAMIC Thu May 7 15:14:12 UTC 2026 x86_64`
- QEMU acceleration: `kvm`
- VM topology: `CPUS=32`, `HOST_CPUS=0-31`, guest node0 CPUs `0-31`
- Guest memory: node0 `32G` on host node0, node1 `64G` on host node2 CXL
- QEMU memory policy: `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1`
- Cgroup cap: `CAPACITY_PAGES=4194304` pages, `ARENA_SIZE=64G`
- NUMA/demotion knobs: `GLOBAL_NUMA_ON=0`, `NODE_BALANCING_ON=2`, `KSWAPD_DEMOTION_ON=1`, `OFF_DEMOTION_ON=1`
- Scan tuning: `NUMA_SCAN_SIZE_MB=256`, `SCAN_PERIOD_SCALE=1`, `HOT_THRESHOLD_MS=0`
- Placement: local-first-touch arena, hotset-only remote placement, no reclaimd settle (`PREFAULT_SETTLE_RECLAIMD=0`)

## Result

| candidate | policy | throughput | promoted | measured demoted |
| --- | --- | ---: | ---: | ---: |
| `skew_lf_hotremote_4g_fixed_rss16g_mulshift_persistent` | on | 611.49 Mops/s | 13 pages / 0.00005 GiB | 68,016 pages / 0.259 GiB |

Prefault effect before the measured window:

| metric | value |
| --- | ---: |
| `RECLAIMD.wake_count` | `0 -> 1` |
| `RECLAIMD.run_count` | `0 -> 1` |
| `MEMSTAT.pgdemote_kswapd` | `0 -> 7,462,075` pages, about 28.47 GiB |
| `vmstat.pgdemote_kswapd` | `0 -> 7,488,267` pages, about 28.57 GiB |
| `RECLAIMD.node0_usage_exact` at measurement start | 4,052,575 pages |
| node0 low/high | 3,984,588 / 4,110,417 pages |

Measured-window counters:

| counter | delta |
| --- | ---: |
| `MEMSTAT.pgdemote_kswapd` | 68,016 pages |
| `vmstat.pgdemote_kswapd` | 41,824 pages |
| `MIGRATE.numa_migrate_fail_promotion_over_high` | 0 |
| `MIGRATE.numa_migrate_success_promotion` | 13 |
| `vmstat.pgpromote_success` | 13 |
| `vmstat.pgpromote_candidate_nrl` | 13 |
| `vmstat.pgpromote_candidate` | 0 |
| `vmstat.pgmigrate_fail` | 0 |

## Interpretation

Demotion is restored by treating `memcg_reclaimd` as kswapd-equivalent. The
previous failure mode, where reclaimd woke and ran many times without demoting
anything, is gone in this run. A single reclaimd run during prefault demoted
about 28.5 GiB and lowered node0 below the high watermark before measurement.

Promotion is still not materially restored. The over-high gate no longer blocks
promotion (`numa_migrate_fail_promotion_over_high=0`), but only 13 pages were
promoted. The remaining failure has moved back to candidate formation/hotness:
`pgpromote_candidate` stayed at 0 and only the NRL/sample path produced 13
promotion candidates.

Next work should keep the demotion fix active and focus on why the friendly
hotset is not reclassified as a normal promotion candidate after prefault-time
demotion.
