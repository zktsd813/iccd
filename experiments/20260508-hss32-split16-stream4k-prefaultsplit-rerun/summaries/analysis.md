# HSS32 Split16 Streaming 4K-Stride Candidate Rerun

Date: 2026-05-08 UTC

## Purpose

Rerun the 32 GiB streaming 4 KiB-stride candidate after fixing `window-split`
placement. The previous run installed a permanent `MPOL_BIND` VMA policy, which
kept the active window out of normal NUMA balancing scans and produced only 11
successful promotions.

## Code Fix

- `window-split:N,N` now does initial placement by first-touch only.
- The first half of the active window is touched under node `N0`, the second
  half under node `N1`.
- Thread memory policy is then reset to `MPOL_DEFAULT`.
- `mbench_apply_placement()` no longer calls `mbind()` for `window-split`, so
  the benchmark VMA remains eligible for NUMA scanner hinting and migration.

Candidate command inside the guest:

```text
mbench --mode bw --bw-kernel read --arena-size 32G --window-size 32G --move-policy fixed --placement window-split:0,1 --bw-stride 512 --bw-block 4K --threads 32
```

`--bw-stride 512` uses 512 double elements, i.e. 4096 bytes, so the read kernel
touches one 8-byte element per 4 KiB page in streaming order.

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
- MGLRU runtime: `lru_gen_enabled=0x0007`.
- Cgroup local cap: `CAPACITY_PAGES=4194304` (16 GiB).
- Scan tuning: `NUMA_SCAN_SIZE_MB=4096`, `SCAN_PERIOD_SCALE=100`,
  `HOT_THRESHOLD_MS=0`.
- Diagnostic knobs: `NUMA_MIGRATION_STOP_ENABLED=0`,
  `NUMA_PINGPONG_STAT_ENABLED=0`, `NUMA_PROMOTE_SAMPLE_STAT_ENABLED=0`.

## Initial Placement

After prefault and before measurement, cgroup anon residency was:

| policy | node0 anon | node1 anon |
| --- | ---: | ---: |
| off | 14.603 GiB | 17.398 GiB |
| on | 14.603 GiB | 17.398 GiB |

The intended first-touch split is 16 GiB / 16 GiB. With
`CAPACITY_PAGES=4194304`, reclaimd high watermark is below the full 16 GiB
local half, so direct demotion during prefault/cgroup setup moved about
1.397 GiB from node0 to node1 before measurement.

## Result

| policy | steady mean | steady median | CV | promoted | demoted | hint faults |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| off | 4312.96 MiB/s | 4314.00 MiB/s | 0.0028 | 0 pages | 0 pages | 0 |
| on | 1544.30 MiB/s | 1524.00 MiB/s | 0.2765 | 2,963,323 pages | 2,807,093 pages | 14,000,138 |

- On/off steady mean ratio: `0.358x`.
- On/off steady median ratio: `0.353x`.
- Successful promotions with migration on: `2,963,323` pages
  (`11.304 GiB`).
- Direct demotion during measured on window: `2,807,093` pages
  (`10.708 GiB`).
- VM-level promotion candidates with migration on: `2,963,331`.
- VM-level promotion failures: `37,414`.

## Interpretation

The 11-page promotion result was a benchmark placement bug, not a kernel or VM
configuration limit. Once `window-split` leaves the VMA under default policy,
NUMA balancing scans the active window and promotion rises to about 11.3 GiB.

This rerun is a strong unfriendly candidate for migration-on overhead: the
streaming 32 GiB hotset induces substantial promotion/demotion churn and drops
steady mean bandwidth to about 35.8% of migration-off throughput.

The initial residency is still slightly more remote-heavy than the nominal
16 GiB / 16 GiB split because the cgroup fast-tier high watermark is below
16 GiB. If exact measured pre-run residency matters, increase the fast-tier
capacity/high watermark for this specific experiment or reduce the requested
local half.

## Artifacts

- Run root:
  `/Serverless/iccd/experiments/20260508-hss32-split16-stream4k-prefaultsplit-rerun/qemu-logs/phase_candidate_microbench/20260508T1539Z-hss32split-prefaultsplit`
- Guest summaries:
  `guest-artifacts/20260508T1539Z-hss32split-prefaultsplit/summary.jsonl`
- QEMU launch log:
  `qemu-launch.log`
