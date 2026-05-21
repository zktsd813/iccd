# Friendly HSS16 Scan100 On/Off

Date: 2026-05-08

## Goal

Run the HSS16 variant of the HSS32 hotset workload to check whether a smaller
hotset increases the promoted fraction or changes friendliness under
`SCAN_PERIOD_SCALE=100`.

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
| scan tuning | `NUMA_SCAN_SIZE_MB=256`, `SCAN_PERIOD_SCALE=100`, `HOT_THRESHOLD_MS=0` |
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
| off | `357.79 Mops/s` | `356.38 Mops/s` | `356.51 Mops/s` | `358.44 Mops/s` | `0` (`0.00 GiB`) | `323,968` (`1.24 GiB`) | `0` | `0` | `0` | `0` | `0/0` |
| on | `362.77 Mops/s` | `356.45 Mops/s` | `357.40 Mops/s` | `394.07 Mops/s` | `257,961` (`0.98 GiB`) | `267,392` (`1.02 GiB`) | `2,380,916` | `257,953` | `0` | `0` | `0/0` |

Ratios:

| metric | on/off |
| --- | ---: |
| mean throughput | `1.014x` |
| median throughput | `1.000x` |
| first10 throughput | `1.003x` |
| last10 throughput | `1.099x` |

## HSS16 vs HSS32

| workload | on mean | on/off mean | promoted | promoted/HSS | candidates/HSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| HSS16 | `362.77 Mops/s` | `1.014x` | `257,961` (`0.98 GiB`) | `6.15%` | `6.15%` |
| HSS32 | `550.93 Mops/s` | `2.481x` | `555,481` (`2.12 GiB`) | `6.62%` | `6.88%` |

## Interpretation

HSS16 did not become more strongly friendly. The promoted fraction is almost
the same as HSS32, but the absolute promoted amount is about half because the
hotset is half the size. The off baseline is also much higher for HSS16
(`357.79 Mops/s` versus HSS32's `222.09 Mops/s`), so the smaller promotion
volume only gives a marginal mean improvement.

This supports the idea that current promotion volume is limited mostly by
candidate formation under the scan/hot-threshold path, not by post-candidate
failure. HSS16 had no over-high failures and promoted essentially every
candidate, but only about `6.15%` of the hotset became candidates.

Artifact:

- `/Serverless/iccd/experiments/20260508-friendly-hss16-scan100-onoff/qemu-logs/phase_candidate_microbench/friendly_hss16_scan100_onoff_20260508T040333Z`
