# HSS32 Split16 Streaming 4K-Stride Candidate

Date: 2026-05-08 UTC

Superseded note: this first run used the original `window-split`
implementation, which installed a permanent `MPOL_BIND` VMA policy and kept the
benchmark window out of normal NUMA balancing scans. The corrected rerun is
documented at
`/Serverless/iccd/experiments/20260508-hss32-split16-stream4k-prefaultsplit-rerun/summaries/analysis.md`.

## Purpose

Test a proposed unfriendly workload with a 32 GiB active working set where the
front half is local and the back half is remote, using a streaming 4 KiB-stride
read pattern.

## Code Setup

- Added mbench placement mode: `window-split:N,N`.
- Added guest-runner candidate:
  `stream_read_32g_split16_4kstride`.
- Candidate command inside the guest:
  `mbench --mode bw --bw-kernel read --arena-size 32G --window-size 32G --move-policy fixed --placement window-split:0,1 --bw-stride 512 --bw-block 4K --threads 32`.

`--bw-stride 512` uses 512 double elements, i.e. 4096 bytes, so this touches
one 8-byte element per 4 KiB page in a regular streaming order.

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

The intended split was 16 GiB / 16 GiB. The measured start shifted about
1.398 GiB from node0 to node1 via direct demotion during prefault/cgroup
settling, so the measured workload was slightly more remote-heavy than the
nominal split.

## Result

| policy | steady mean | steady median | promoted | demoted |
| --- | ---: | ---: | ---: | ---: |
| off | 4336.41 MiB/s | 4338.00 MiB/s | 0 pages | 0 pages |
| on | 4329.11 MiB/s | 4330.00 MiB/s | 11 pages | 0 pages |

- On/off steady mean ratio: `0.998x`.
- Hint faults with migration on: `35`.
- Promotion candidates with migration on: `5`, plus `6` NRL candidates.
- Successful promotions with migration on: `11` pages (`0.000042 GiB`).
- Demotion during measured on window: `0` pages.

## Interpretation

This candidate is not a useful unfriendly workload in the current setup. The
on/off throughput difference is only about `-0.17%`, and migration activity is
effectively absent during the measured interval. The streaming 4 KiB-stride
pattern over a stable half-local/half-remote 32 GiB window does not create
enough NUMA hinting/promotion traffic to hurt throughput.

For a stronger unfriendly candidate, the next variant should force more policy
work or more movement, for example a larger footprint than local cap, a moving
window, or a pattern that causes recurring remote candidates instead of a
stable split.

## Artifacts

- Run root:
  `/Serverless/iccd/experiments/20260508-hss32-split16-stream4k-unfriendly/qemu-logs/phase_candidate_microbench/20260508T1520Z-hss32split-stream4k`
- Guest summaries:
  `guest-artifacts/20260508T1520Z-hss32split-stream4k/summary.jsonl`
- QEMU launch log:
  `qemu-launch.log`
