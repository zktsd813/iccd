# Friendly HSS32 Scan100 On/Off

Date: 2026-05-08

## Goal

Rerun the 32 GiB hotset HSS friendly workload with the corrected default scan
period scale, `SCAN_PERIOD_SCALE=100`, and compare migration off versus on.

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
skew_lf_hotremote_32g_fixed_rss16g_mulshift_persistent
--mode skewed-hotset --window-size 32G --window-offset 0
--move-policy fixed --hotset-pages 8388608 --hot-prob-pct 100
--hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0
--hotset-index-mode mulshift --hotset-prefault-node 1
--threads 32 --duration-ms 60000
```

## Result

| policy | mean | median | first10 | last10 | promoted | demoted | hint faults | candidates | over-high failures | `pgmigrate_fail` | reclaimd run/wake |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| off | `222.09 Mops/s` | `221.97 Mops/s` | `222.10 Mops/s` | `222.05 Mops/s` | `0` (`0.00 GiB`) | `358,847` (`1.37 GiB`) | `0` | `0` | `0` | `0` | `0/0` |
| on | `550.93 Mops/s` | `564.33 Mops/s` | `469.95 Mops/s` | `565.12 Mops/s` | `555,481` (`2.12 GiB`) | `622,848` (`2.38 GiB`) | `2,152,714` | `576,787` | `21,319` | `21,319` | `2/2` |

Ratios:

| metric | on/off |
| --- | ---: |
| mean throughput | `2.481x` |
| median throughput | `2.542x` |
| first10 throughput | `2.116x` |
| last10 throughput | `2.545x` |

## Interpretation

The 32 GiB hotset HSS workload remains friendly under the corrected scan period
scale. Migration on improved mean throughput by `2.48x` and last-10s
throughput by `2.55x`.

This run promoted less total memory than the earlier scan100 on-only run, but
the classification is unchanged: promotion started early, over-high failures
were limited to `21,319`, and the final throughput stayed well above off.

Artifact:

- `/Serverless/iccd/experiments/20260508-friendly-hss32-scan100-onoff/qemu-logs/phase_candidate_microbench/friendly_hss32_scan100_onoff_20260508T034336Z`
