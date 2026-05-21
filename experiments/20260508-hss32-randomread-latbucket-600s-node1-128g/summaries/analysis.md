# HSS32 Random-Read Latency-Bucket Verification

This is the corrected run for the HSS random-read workload. The earlier
`20260508-latencybucket-phase-on-verify-initrd` run used the alternating
friendly+sparse phase workload and should not be used to explain this HSS case.

Run:
`/Serverless/iccd/experiments/20260508-hss32-randomread-latbucket-600s-node1-128g/qemu-logs/phase_candidate_microbench/hss32-rand-latbucket-20260508T141857Z`

## Setup

- Kernel: `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`
- Initrd: `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-latbucket-phase-on-20260508.img`
- Guest kernel: `Linux kernel 6.18.0modified #154 SMP PREEMPT_DYNAMIC Fri May 8 13:29:54 UTC 2026`
- KVM: enabled
- VM: `CPUS=32`, `MEMORY=160G`, node0 `32G`, node1 `128G`
- Host binding: guest node0 bound to host node0, guest node1 bound to host node2, `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1`
- Cgroup cap: `CAPACITY_PAGES=4194304` = 16GiB
- MGLRU: `lru_gen_enabled=0x0007`
- Migration knobs: `GLOBAL_NUMA_ON=0`, `NODE_BALANCING_ON=2`, `KSWAPD_DEMOTION_ON=1`, `OFF_DEMOTION_ON=1`
- Diagnostic knobs: `NUMA_MIGRATION_STOP_ENABLED=0`, `NUMA_PINGPONG_STAT_ENABLED=0`, `NUMA_PROMOTE_SAMPLE_STAT_ENABLED=0`
- Scan: `NUMA_SCAN_SIZE_MB=4096`, effective `4096`, `SCAN_PERIOD_SCALE=100`, `HOT_THRESHOLD_MS=0`
- Workload: `skew_lf_hotremote_32g_fixed_rss16g_mulshift_persistent`, policy `on`, 600s.
- Command: `mbench --mode skewed-hotset --window-size 32G --window-offset 0 --move-policy fixed --hotset-pages 8388608 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --hotset-index-mode mulshift --hotset-prefault-node 1 --threads 32 --duration-ms 600000`

Initial residency after prefault:

- `anon N0=16525778944` bytes = 15.39GiB
- `anon N1=52193947648` bytes = 48.61GiB

Initial reclaimd live state:

- node0 capacity: 16.00GiB
- node0 low watermark: 15.20GiB
- node0 high watermark: 15.68GiB
- node0 usage_lru: 15.43GiB

## Overall Result

- hint faults / promote-enter events: 74,478,424 pages = 284.11GiB event volume
- promoted: 10,480,700 pages = 39.98GiB
- demoted: 10,368,642 pages = 39.55GiB (`pgdemote_direct`; `pgdemote_kswapd=0`)
- `debug_promote_wmark_bypass`: 8 pages
- `debug_promote_wmark_no_bypass`: 74,478,416 pages
- `debug_promote_latency_pass`: 10,480,790 pages = 39.98GiB
- `debug_promote_latency_fail`: 63,997,626 pages = 244.13GiB
- `numa_migrate_fail_promotion_over_high`: 72 pages
- `numa_migrate_fail_promotion_alloc`: 0 pages
- `debug_promote_rate_limited`: 0 pages

Latency buckets:

| bucket | pages | GiB |
| --- | ---: | ---: |
| `<1s` | 8,445,404 | 32.22 |
| `1-2s` | 26,444,799 | 100.88 |
| `2-4s` | 36,106,772 | 137.74 |
| `4-8s` | 1,384,276 | 5.28 |
| `8-60s` | 2,097,155 | 8.00 |
| `>=60s` | 10 | 0.00 |

## 60s Windows

| window | hint events | promoted GiB | demoted GiB | bypass | latency pass | latency fail | pass ratio | over_high |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0-60s | 18,045,381 | 8.98 | 8.46 | 0 | 2,354,979 | 15,689,099 | 13.1% | 0 |
| 60-120s | 7,886,739 | 7.56 | 7.71 | 0 | 1,980,789 | 5,905,762 | 25.1% | 0 |
| 120-180s | 6,009,188 | 2.34 | 2.36 | 0 | 612,549 | 5,396,639 | 10.2% | 7 |
| 180-240s | 5,246,727 | 2.12 | 2.01 | 0 | 555,061 | 4,691,824 | 10.6% | 6 |
| 240-300s | 6,201,510 | 2.36 | 2.43 | 0 | 617,590 | 5,583,762 | 10.0% | 12 |
| 300-360s | 5,562,220 | 2.72 | 2.69 | 0 | 713,390 | 4,848,830 | 12.8% | 5 |
| 360-420s | 5,621,351 | 3.34 | 3.18 | 0 | 875,233 | 4,746,118 | 15.6% | 12 |
| 420-480s | 5,816,871 | 3.35 | 3.35 | 0 | 879,026 | 4,937,845 | 15.1% | 14 |
| 480-540s | 5,510,268 | 2.61 | 2.88 | 0 | 684,701 | 4,825,567 | 12.4% | 7 |
| 540-600s | 8,472,584 | 4.57 | 4.41 | 8 | 1,197,041 | 7,275,535 | 14.1% | 9 |

## Interpretation

For HSS32 random-read, the initial promotion was not caused by local-memory
headroom bypass. `wmark_bypass` was only 8 pages across the whole run, while
`wmark_no_bypass` covered essentially all candidates. Initial node0 usage was
already 15.43GiB, above the low watermark and close to high.

The real gate is the latency filter. The run produced a large candidate event
volume, about 284.11GiB, but only 39.98GiB passed latency and got promoted.
That is a 14.1% pass ratio. Over-high and allocation failures were negligible,
so they do not explain the missing promotions in this run.

The first 60 seconds did have the largest promotion volume, 8.98GiB, but it
also had massive latency failure: 15.69M failed pages against 2.35M passed
pages. So the early burst is better described as fast scan coverage from the
4096MiB scan window plus a small latency-passing subset, not a bypass path.

Adaptive threshold rising to 2000ms helps somewhat, but most candidates still
fall into the `2-4s` bucket, which remains above the threshold and fails.
