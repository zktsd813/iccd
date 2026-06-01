# Current Migration Workloads

Date: 2026-05-09

Latest session handoff: `/Serverless/iccd-git/docs/session-handoff-20260601.md`.

This is an optional workload catalog. Read it when choosing or interpreting
the migration-friendly/unfriendly workload candidates; it is not a required
pre-read for every experiment. Older sparse/block2M unfriendly records were
removed from this current view because the latest selected unfriendly workload
is the split32 streaming 4 KiB-stride candidate found on 2026-05-08.

## Canonical Topology

Use these settings unless the user explicitly asks otherwise:

| item | value |
| --- | --- |
| project | `/Serverless/iccd-git` |
| kernel | `/Serverless/iccd-git/linux` |
| build | `/Serverless/iccd-git/linux-global-build` |
| kernel image | `/Serverless/iccd-git/linux-global-build/arch/x86/boot/bzImage` |
| outputs | `/Serverless/iccd-git/experiments/<name>/` |
| vCPUs | `CPUS=32`, `HOST_CPUS=0-31`, guest node0 CPUs `0-31` |
| fast local memory | guest node0 sized directly for the experiment, host node0, `NUMA_NODE0_HOST_NODES=0` |
| slow remote memory | guest node1 sized for the remaining workload memory, host node2 CXL, `NUMA_NODE1_HOST_NODES=2` |
| QEMU memory | `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1` |
| arena/RSS | normally `ARENA_SIZE=64G`; standalone split32 uses a 32G active window |
| threads | `THREADS=32` |
| migration on | global `/proc/sys/kernel/numa_balancing=2` |
| migration off | global `/proc/sys/kernel/numa_balancing=0` |
| demotion | use global `/sys/kernel/mm/numa/demotion_enabled` and `/sys/kernel/mm/numa/demotion_target` |
| MGLRU | guest `/sys/kernel/mm/lru_gen/enabled` must be `0x0007` |
| scan tuning | use the experiment's requested `NUMA_SCAN_SIZE_MB`, `NUMA_SCAN_PERIOD_MIN_MS`, and `NUMA_FAST_SCAN`; do not use the old scale-knob model for new fast-scan work |

Results without host node0/node2 memory binding are not valid for local-vs-CXL
interpretation.

Default workload placement is configured repo-wide in
`scripts/iccd_experiment_defaults.sh` as `ICCD_WORKLOAD_CPU_NODE=0`, which maps
to `numactl --cpunodebind=0`.

## Required Build And VM Checklist

Before each experiment:

- Confirm the run uses the canonical topology above.
- Build kernels with all available CPUs, for example
  `make -C /Serverless/iccd-git/linux O=/Serverless/iccd-git/linux-global-build -j$(nproc) bzImage`.
- For VM experiments after kernel changes, create and use a fresh initrd from
  the same kernel tree. Do not silently fall back to `/boot/vmlinuz-*` or an
  older `/boot/initrd.img-*`; pass `KERNEL_IMAGE` and `INITRD_IMAGE`
  explicitly.
- For phase-candidate QEMU runs, override host wrapper defaults with:
  `MEMORY=96G`, `CPUS=32`, `HOST_CPUS=0-31`,
  `NUMA_NODE0_CPUS=0-31`, `NUMA_NODE0_MEM=32G`,
  `NUMA_NODE1_MEM=64G`, `NUMA_NODE0_HOST_NODES=0`,
  `NUMA_NODE1_HOST_NODES=2`, `NUMA_MEM_POLICY=bind`,
  `NUMA_PREALLOC=1`.

Every experiment result summary must state:

- kernel image, initrd image, kernel `uname -a`, and whether KVM was used.
- MGLRU runtime state.
- VM CPU/memory layout and host node bindings.
- Global NUMA balancing state, global demotion knobs, scan size/period/fast-scan
  settings, and `HOT_THRESHOLD_MS` if explicitly changed.
- placement mode.
- workload candidate, policy, measured throughput, promoted pages/GiB,
  demoted pages/GiB, hint faults, and PTE-update counts when available.

## Current Candidate Pair

| role | label | runner / preset | access shape | current result |
| --- | --- | --- | --- | --- |
| friendly | `skew_lf_hotremote_4g_move_60s_remoteonly_mulshift_persistent` | standalone moving-hotset runner; phase equivalent uses moving 4G remote hotset | 4G read-only `mulshift` hot window, remote-window first-touch, random 60s moves across the 64G arena | confirmed friendly direction; latest fast-scan work uses this for promotion-follow timing |
| unfriendly | `stream_read_32g_split16_4kstride` | standalone runner candidate; phase preset uses `stream-read-32g-split16-4k` | 32G streaming read, 4KiB stride, intended 16G local + 16G remote first-touch split, VMA reset to default policy | confirmed strong unfriendly on 2026-05-08: on/off steady mean `0.358x`, median `0.353x` |

For phase-switch experiments, use the split32 streaming variant as the
unfriendly phase, not the older sparse/block2M candidate. The validated phase
preset is `phase_move15s4g_split32_stream4k_localft` for the 15s moving-hotset
pair; newer remote-only/move60 variants keep the same conceptual unfriendly
shape.

## Current Unfriendly

Standalone candidate:

```text
stream_read_32g_split16_4kstride
```

Guest command shape:

```text
mbench --mode bw --bw-kernel read \
  --arena-size 32G --window-size 32G \
  --move-policy fixed --placement window-split:0,1 \
  --bw-stride 512 --bw-block 4K --threads 32
```

Meaning:

- 32 GiB active streaming read window.
- `--bw-stride 512` means 512 double elements, or 4096 bytes, so each pass
  touches one 8-byte element per 4 KiB page.
- `window-split:0,1` first-touches the first half on node0 and second half on
  node1, then resets memory policy to default so normal NUMA balancing can scan
  and migrate the VMA.
- With 16 GiB guest node0 local memory, migration-on churn can be expensive:
  promotion and demotion repeatedly move pages for a streaming pattern that does
  not benefit from stable hotset locality.

Latest validated standalone result:

| policy | steady mean | steady median | CV | promoted | demoted | hint faults |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| off | 4312.96 MiB/s | 4314.00 MiB/s | 0.0028 | 0 pages | 0 pages | 0 |
| on | 1544.30 MiB/s | 1524.00 MiB/s | 0.2765 | 2,963,323 pages / 11.30 GiB | 2,807,093 pages / 10.71 GiB | 14,000,138 |

Result:

- on/off steady mean ratio: `0.358x`
- on/off steady median ratio: `0.353x`
- artifact: historical only; do not use it for current runs.

## Current Phase Pair

Phase candidate:

```text
phase_move15s4g_split32_stream4k_localft
```

Phase order:

| phase | pattern |
| --- | --- |
| 1, 3, 5 | moving 4 GiB `mulshift` hotset |
| 2, 4, 6 | `stream-read-32g-split16-4k` |

Latest validated phase result:

| metric | off | on | on/off |
| --- | ---: | ---: | ---: |
| overall mixed mean | 830.67 Mops/s | 692.58 Mops/s | 0.834x |
| overall mixed median | 564.64 Mops/s | 385.94 Mops/s | 0.684x |
| friendly phase mean | 1086.01 Mops/s | 1024.36 Mops/s | 0.943x |
| friendly phase median | 228.81 Mops/s | 533.36 Mops/s | 2.331x |
| unfriendly phase mean | 4516.25 MiB/s | 2900.90 MiB/s | 0.642x |
| unfriendly phase median | 4517.86 MiB/s | 2769.30 MiB/s | 0.613x |

Migration-on counters:

- `pgpromote_success`: `7,629,886` pages (`29.11 GiB`)
- `pgdemote_direct`: `7,420,861` pages (`28.31 GiB`)
- NUMA hint faults: `50,155,254`
- artifact: historical only; do not use it for current runs.

## Avoid These Mixups

- Do not use older sparse/block2M candidates as the current unfriendly unless
  explicitly running a historical comparison.
- Do not use old `SCAN_PERIOD_SCALE` reasoning for new fast-scan experiments.
  Use `NUMA_FAST_SCAN` plus `NUMA_SCAN_PERIOD_MIN_MS`.
- Do not leave a permanent VMA bind policy on `window-split`; the fixed
  candidate requires initial first-touch placement only, followed by default
  policy so NUMA balancing can scan the VMA.
