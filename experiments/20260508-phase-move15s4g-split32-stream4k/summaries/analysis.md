# Phase Switch: Moving Friendly vs Split32 Streaming Unfriendly

Date: 2026-05-08 UTC

## Purpose

Run a phase-switch experiment using the two newly selected representative
patterns:

- Friendly: `skew_lf_hotremote_4g_move_15s_rss64g_mulshift_persistent`
- Unfriendly: `stream_read_32g_split16_4kstride`

The mbench phase preset added for this experiment is `move15s4g-split32`, with
runner label `phase_move15s4g_split32_stream4k_localft`.

## Workload

Guest command:

```text
mbench --arena-size 64G --phase-preset move15s4g-split32 --window-size 32G --placement window-split:0,1 --phase-ms 60000 --phase-repeat 3 --threads 32
```

Phase order:

| phase | pattern |
| --- | --- |
| 1, 3, 5 | `move15s-hotset-4g-rss64`: 4 GiB read-only mulshift hotset, 15s random movement among 4 GiB-aligned offsets in 64 GiB |
| 2, 4, 6 | `stream-read-32g-split16-4k`: 32 GiB streaming read, 4 KiB stride |

Initial placement is shared across the phase sequence rather than reset at each
phase boundary: intended `0..16G` local and `16..64G` remote. This preserves
phase-transition behavior without injecting synthetic page movement between
phases.

## VM And Kernel

- Kernel image:
  `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`
- Initrd:
  `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-hss32split-stream4k.img`
- Guest kernel:
  `Linux kernel 6.18.0modified #157 SMP PREEMPT_DYNAMIC Fri May 8 15:16:31 UTC 2026`
- KVM: enabled.
- VM: `CPUS=32`, `MEMORY=96G`.
- Host CPU affinity: `HOST_CPUS=0-31`.
- Guest node0: CPUs `0-31`, memory `32G`, host node `0`.
- Guest node1: memory `64G`, host node `2`.
- QEMU memory policy: `bind`, prealloc enabled.
- Cgroup local cap: `CAPACITY_PAGES=4194304` (16 GiB).
- MGLRU runtime: `lru_gen_enabled=0x0007`.
- Scan tuning: `NUMA_SCAN_SIZE_MB=4096`, `SCAN_PERIOD_SCALE=100`,
  `HOT_THRESHOLD_MS=0`.
- Diagnostic knobs: `NUMA_MIGRATION_STOP_ENABLED=0`,
  `NUMA_PINGPONG_STAT_ENABLED=0`, `NUMA_PROMOTE_SAMPLE_STAT_ENABLED=0`.

## Initial Placement

After prefault and before measurement:

| policy | node0 anon | node1 anon |
| --- | ---: | ---: |
| off | 14.603 GiB | 49.397 GiB |
| on | 14.603 GiB | 49.397 GiB |

The intended local head is 16 GiB, but the 16 GiB cgroup high watermark causes
about 1.397 GiB of direct demotion before measurement, consistent with the
standalone split32 run.

## Result

Overall mixed `ops/s` is a coarse signal because the two phases use different
kernels. Phase-specific rates are the primary result.

| metric | off | on | on/off |
| --- | ---: | ---: | ---: |
| overall mixed mean | 830.67 Mops/s | 692.58 Mops/s | 0.834x |
| overall mixed median | 564.64 Mops/s | 385.94 Mops/s | 0.684x |
| friendly phase mean | 1086.01 Mops/s | 1024.36 Mops/s | 0.943x |
| friendly phase median | 228.81 Mops/s | 533.36 Mops/s | 2.331x |
| unfriendly phase mean | 4516.25 MiB/s | 2900.90 MiB/s | 0.642x |
| unfriendly phase median | 4517.86 MiB/s | 2769.30 MiB/s | 0.613x |

Migration-on counters:

- `pgpromote_success`: `7,629,886` pages (`29.106 GiB`)
- `pgdemote_direct`: `7,420,861` pages (`28.308 GiB`)
- NUMA hint faults: `50,155,254`
- `pgmigrate_fail`: `30,024`

## Interpretation

The phase pair separates the desired directions:

- Moving-friendly phases improve on robust median throughput (`2.331x`).
- Split32 streaming-unfriendly phases slow down under migration on
  (`0.613x` median bandwidth).

The friendly mean is noisy because the moving 4 GiB hotset can land on memory
that is already local or already promoted. Median is the better summary for
that phase. The unfriendly phase is more stable and shows a clear slowdown.

## Artifacts

- Run root:
  `/Serverless/iccd/experiments/20260508-phase-move15s4g-split32-stream4k/qemu-logs/phase_candidate_microbench/20260508T1627Z-phase-move15s4g-split32`
- Guest summaries:
  `guest-artifacts/20260508T1627Z-phase-move15s4g-split32/summary.jsonl`
- QEMU launch log:
  `qemu-launch.log`
