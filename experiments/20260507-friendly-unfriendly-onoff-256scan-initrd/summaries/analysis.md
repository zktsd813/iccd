# Friendly/Unfriendly On-Off VM Validation

Date: 2026-05-07

## Run

- Run ID: `friendly_unfriendly_onoff_20260507T132502Z`
- Artifacts: `/Serverless/iccd/experiments/20260507-friendly-unfriendly-onoff-256scan-initrd/qemu-logs/phase_candidate_microbench/friendly_unfriendly_onoff_20260507T132502Z`
- Guest summary: `guest-artifacts/friendly_unfriendly_onoff_20260507T132502Z/summary.jsonl`
- Checklist read before run: `/Serverless/iccd/docs/current-migration-workloads-20260507.md`

## Build And VM Settings

- Kernel build: `sudo -n make -C /Serverless/Migration-friendly/linux -j$(nproc) bzImage modules`, with `nproc=64`.
- Modules install: `sudo -n make -C /Serverless/Migration-friendly/linux -j$(nproc) modules_install ...`.
- Kernel image: `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`
- Initrd image: `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260507T131826Z-256scan.img`
- Guest kernel: `Linux kernel 6.18.0modified #109 SMP PREEMPT_DYNAMIC Thu May 7 13:21:07 UTC 2026 x86_64`
- QEMU/KVM: KVM used.
- VM CPU/memory: `CPUS=32`, `MEMORY=96G`, `HOST_CPUS=0-31`.
- VM NUMA binding: guest node0 CPUs `0-31`, node0 `32G` on host node0; guest node1 `64G` on host node2; `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1`.
- Guest NUMA view: node0 has CPUs `0-31` and about 32G; node1 has no CPUs and about 64G; node distance `0->1 = 20`.
- Cgroup cap: `CAPACITY_PAGES=4194304` (16GiB).
- Knobs: `GLOBAL_NUMA_ON=0`, `NODE_BALANCING_ON=2`, `KSWAPD_DEMOTION_ON=1`, `OFF_DEMOTION_ON=1`.
- Scan tuning: `NUMA_SCAN_SIZE_MB=256`, effective scan size `256`, `SCAN_PERIOD_SCALE=1`, `HOT_THRESHOLD_MS=0`.
- Workload: `THREADS=32`, `ARENA_SIZE=64G`, `PAUSE_NS=0`, `OPS_PER_PASS=65536`, `MBENCH_FORCE_DURATION_MS=60000`, remote-firsttouch enabled for both candidates.
- Demotion accounting below is `pgdemote_direct + pgdemote_kswapd`.

## Results

| candidate | expected | policy | throughput | promoted pages | promoted GiB | demoted pages | demoted GiB | hint faults |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `skew_rf_read_4g_fixed_rss16g_mulshift_persistent` | friendly | off | 2096.16 Mops/s | 0 | 0.00 | 0 | 0.00 | 0 |
| `skew_rf_read_4g_fixed_rss16g_mulshift_persistent` | friendly | on | 4588.37 Mops/s | 680,641 | 2.60 | 0 | 0.00 | 748,710 |
| `sparse_stride_read_64g_block2m_remoteft` | unfriendly | off | 395.79 MiB/s | 0 | 0.00 | 0 | 0.00 | 0 |
| `sparse_stride_read_64g_block2m_remoteft` | unfriendly | on | 1376.70 MiB/s | 3,882,738 | 14.81 | 137,375 | 0.52 | 5,987,231 |

## Verdict

- Friendly candidate validated: `on/off = 2.189x` (`+118.9%`), with 680,641 promoted pages and no demotion.
- Unfriendly candidate did not validate in this 256MB-scan run: `on/off = 3.478x` (`+247.8%`). It behaved friendly here, despite 3,882,738 promotions and 137,375 direct demotions.

This conflicts with the earlier deep result recorded for the same unfriendly label. The changed scan size (`256MB` instead of the earlier larger setting) and single-repetition run are the main differences to control before treating this candidate as reliably unfriendly.
