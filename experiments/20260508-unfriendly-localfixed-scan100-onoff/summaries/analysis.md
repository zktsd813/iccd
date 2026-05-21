# Unfriendly Local-First-Touch Scan100 On/Off

Date: 2026-05-08

## Goal

Rerun the current primary unfriendly candidate with the corrected default scan
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
| placement | local-first-touch, `remote_firsttouch=0`, `PREFAULT_PHASE_GATE=1`, `PREFAULT_SETTLE_RECLAIMD=0` |
| MGLRU | `/sys/kernel/mm/lru_gen/enabled=0x0007` |
| scan tuning | `NUMA_SCAN_SIZE_MB=256`, `SCAN_PERIOD_SCALE=100`, `HOT_THRESHOLD_MS=0` |
| diagnostic knobs | `NUMA_MIGRATION_STOP_ENABLED=0`, `NUMA_PINGPONG_STAT_ENABLED=0`, `NUMA_PROMOTE_SAMPLE_STAT_ENABLED=0` |

Workload:

```text
sparse_stride_read_64g_block2m_localft
--mode bw --bw-kernel read --window-size 64G --move-policy fixed
--bw-stride 512 --bw-block 2M --threads 32 --duration-ms 60000
```

## Result

| policy | mean | median | first10 | last10 | promoted | demoted | hint faults | candidates | over-high failures | `pgmigrate_fail` | reclaimd run/wake |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| off | `1972.91 MiB/s` | `1972.00 MiB/s` | `1977.60 MiB/s` | `1971.20 MiB/s` | `0` (`0.00 GiB`) | `233,106` (`0.89 GiB`) | `0` | `0` | `0` | `2` | `0/0` |
| on | `1132.07 MiB/s` | `1096.00 MiB/s` | `1337.07 MiB/s` | `1097.20 MiB/s` | `1,912,824` (`7.30 GiB`) | `1,939,048` (`7.40 GiB`) | `10,293,640` | `5,046,267` | `3,133,445` | `3,136,371` | `1/1` |

Ratios:

| metric | on/off |
| --- | ---: |
| mean throughput | `0.574x` |
| median throughput | `0.556x` |
| first10 throughput | `0.676x` |
| last10 throughput | `0.556x` |

## Interpretation

The primary unfriendly candidate remains strongly unfriendly under the corrected
scan period scale. The old 3-run scan1 validation reported on/off `0.567x`;
this scan100 single run reports `0.574x`, effectively the same classification.

The scan100 run still forms many candidates and performs about `7.30 GiB` of
promotion, but the migration-on path loses throughput due to a large volume of
promotion work and failures: `5.05M` candidates, `1.91M` successful promotions,
and `3.13M` over-high failures. The on run's last-10s throughput is only
`0.556x` of off.

Artifact:

- `/Serverless/iccd/experiments/20260508-unfriendly-localfixed-scan100-onoff/qemu-logs/phase_candidate_microbench/unfriendly_sparse64_block2m_localft_scan100_onoff_20260508T033548Z`
