# Moving Friendly 4G Hotset Across 64G RSS

Date: 2026-05-08 UTC

## Purpose

Validate a friendly variant where the 4 GiB read-only mulshift hotset changes
location every 15 seconds across the full 64 GiB arena.

## Workload

Candidate:
`skew_lf_hotremote_4g_move_15s_rss64g_mulshift_persistent`

Guest command:

```text
mbench --mode skewed-hotset --arena-size 64G --window-size 4G --window-offset 0 --move-policy random --move-step 4G --move-min-offset 0 --move-max-offset 60G --move-interval-ms 15000 --hotset-pages 1048576 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --hotset-index-mode mulshift --hotset-prefault-node 1 --threads 32
```

The possible active windows are 4 GiB-aligned offsets `0G..60G`. The measured
200s window visited these offsets with the fixed seed: `12G`, `16G`, `28G`,
`32G`, `36G`, `44G`, `48G`, `52G`, and `56G`.

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

Before measurement, cgroup anon residency was:

| policy | node0 anon | node1 anon |
| --- | ---: | ---: |
| off | 1.627 GiB | 62.373 GiB |
| on | 1.627 GiB | 62.373 GiB |

Because the moving windows tile the 64 GiB arena, this variant effectively
prefaults almost the whole arena on the remote node as potential hotset memory.

## Result

| policy | steady mean | steady median | CV | promoted | demoted | hint faults |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| off | 228.39 Mops/s | 228.46 Mops/s | 0.0016 | 0 pages | 0 pages | 0 |
| on | 722.18 Mops/s | 421.00 Mops/s | 0.8916 | 6,138,199 pages | 2,604,329 pages | 16,869,139 |

- On/off steady mean ratio: `3.162x`.
- On/off steady median ratio: `1.843x`.
- Last-10s on/off ratio from per-second samples: about `4.82x`
  (`1101.40 / 228.45 Mops/s`).
- Successful promotions with migration on: `6,138,199` pages (`23.415 GiB`).
- Direct demotion during migration on: `2,604,329` pages (`9.935 GiB`).
- VM-level promotion candidates with migration on: `2,842,345` candidate pages
  plus `3,295,854` NRL candidates.

## Interpretation

The moving 4 GiB hotset remains friendly on average: migration-on throughput is
about `3.16x` migration-off throughput. It is less stable than the fixed 4 GiB
friendly case because performance depends on whether the currently selected
4 GiB window has already been promoted. This is visible in the high `on` CV and
the wide per-offset spread.

This is a useful moving-friendly candidate, but it should be reported as a
dynamic full-RSS remote-hotset case, not as the same shape as the fixed 4 GiB
hotset. The full-RSS remote prefault is intentional for this variant because
any 4 GiB-aligned window in the 64 GiB arena can become the active hotset.

## Artifacts

- Run root:
  `/Serverless/iccd/experiments/20260508-friendly-move15s-rss64g-onoff-localft/qemu-logs/phase_candidate_microbench/20260508T1610Z-friendly-move15s-rss64g`
- Guest summaries:
  `guest-artifacts/20260508T1610Z-friendly-move15s-rss64g/summary.jsonl`
- QEMU launch log:
  `qemu-launch.log`
