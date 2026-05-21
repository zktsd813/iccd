# Friendly HSS16 Scan4096 On/Off

Date: 2026-05-08

## Goal

Rerun the HSS16 hotset workload with `NUMA_SCAN_SIZE_MB=4096` to check whether
the low promoted fraction observed with the default 256 MiB scan size was
caused by slow NUMA scanner revisit/coverage.

## Setup

| item | value |
| --- | --- |
| kernel image | `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage` |
| initrd | `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260508T003500Z-nostop-noping.img` |
| guest kernel | `Linux kernel 6.18.0modified #122 SMP PREEMPT_DYNAMIC Thu May 7 23:30:15 UTC 2026 x86_64` |
| KVM | enabled (`-accel kvm`) |
| VM topology | `MEMORY=96G`, `CPUS=32`, node0 `32G`, node1 `64G` |
| host binding | node0 on host node0, node1 on host node2 CXL, `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1` |
| cgroup cap | `CAPACITY_PAGES=4194304` (`16 GiB`) |
| placement | local-first-touch arena, hotset-only remote first-touch, `PREFAULT_PHASE_GATE=1`, `PREFAULT_SETTLE_RECLAIMD=0` |
| MGLRU | `/sys/kernel/mm/lru_gen/enabled=0x0007` |
| scan tuning | `NUMA_SCAN_SIZE_MB=4096`, `SCAN_PERIOD_SCALE=100`, `HOT_THRESHOLD_MS=0` |
| diagnostic knobs | `NUMA_MIGRATION_STOP_ENABLED=0`, `NUMA_PINGPONG_STAT_ENABLED=0`, `NUMA_PROMOTE_SAMPLE_STAT_ENABLED=0` |

Workload:

```text
skew_lf_hotremote_16g_fixed_rss16g_mulshift_persistent
--mode skewed-hotset --window-size 16G --window-offset 0
--move-policy fixed --hotset-pages 4194304 --hot-prob-pct 100
--hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0
--hotset-index-mode mulshift --hotset-prefault-node 1
--threads 32 --duration-ms 60000
```

## Result

| policy | mean | median | first10 | last10 | promoted | demoted | hint faults | candidates | over-high failures | `pgmigrate_fail` | reclaimd run/wake |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| off | `356.06 Mops/s` | `355.73 Mops/s` | `354.83 Mops/s` | `356.06 Mops/s` | `0` (`0.00 GiB`) | `304,512` (`1.16 GiB`) | `0` | `0` | `0` | `0` | `0/0` |
| on | `1444.96 Mops/s` | `1531.35 Mops/s` | `872.17 Mops/s` | `2372.63 Mops/s` | `1,952,531` (`7.45 GiB`) | `1,983,040` (`7.56 GiB`) | `6,246,783` | `3,953,878` | `2,001,334` | `2,001,344` | `6/6` |

Ratios:

| metric | on/off |
| --- | ---: |
| mean throughput | `4.058x` |
| median throughput | `4.305x` |
| first10 throughput | `2.458x` |
| last10 throughput | `6.664x` |

## Scanner Timing

The 4096 MiB scan run formed candidates much earlier than the 256 MiB scan run.
Because `mbench` has a forced 20 second warmup, `measured_ms = live_elapsed_ms -
20000`.

| live elapsed | measured time | hint faults | candidates | promoted | over-high |
| ---: | ---: | ---: | ---: | ---: | ---: |
| `1.1s` | `-18.9s` | `2,097,152` | `0` | `0` | `0` |
| `18.6s` | `-1.4s` | `3,847,549` | `1,670,473` | `793,141` | `877,458` |
| `20.7s` | `0.7s` | `4,282,415` | `2,095,658` | `891,228` | `1,204,430` |
| `71.8s` | `51.8s` | `5,852,131` | `3,593,394` | `1,611,073` | `1,982,300` |
| `76.9s` | `56.9s` | `6,246,765` | `3,953,878` | `1,952,523` | `2,001,334` |

For HSS16, `hotset-pages=4,194,304`. With 4096 MiB scan size:

| fraction | value |
| --- | ---: |
| candidate/HSS | `94.27%` |
| promoted/HSS | `46.55%` |
| promoted/candidate | `49.38%` |
| over-high/HSS | `47.72%` |

## Comparison To 256 MiB Scan

| scan size | on mean | on/off mean | promoted | candidates | over-high failures |
| --- | ---: | ---: | ---: | ---: | ---: |
| `256 MiB` | `362.77 Mops/s` | `1.014x` | `257,961` (`0.98 GiB`) | `257,953` | `0` |
| `4096 MiB` | `1444.96 Mops/s` | `4.058x` | `1,952,531` (`7.45 GiB`) | `3,953,878` | `2,001,334` |

## Interpretation

Increasing scan size from 256 MiB to 4096 MiB strongly supports the scanner
coverage hypothesis. Candidate formation rose from about `6.15%` of HSS to
about `94.27%` of HSS, and promotion volume rose from `0.98 GiB` to `7.45 GiB`.

This does not mean the promotion path is fully healthy. Once scanner coverage is
no longer the main bottleneck, about half of the candidates fail at the
promotion over-high gate. The next bottleneck is therefore node0 headroom /
reclaimd feedback, not hotset access pattern or basic candidacy.

Artifact:

- `/Serverless/iccd/experiments/20260508-friendly-hss16-scan4096-onoff/qemu-logs/phase_candidate_microbench/friendly_hss16_scan4096_onoff_20260508T042425Z`
