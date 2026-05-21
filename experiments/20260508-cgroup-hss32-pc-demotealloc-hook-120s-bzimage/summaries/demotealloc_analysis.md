# Demotion Allocation Diagnosis

Experiment: `20260508-cgroup-hss32-pc-demotealloc-hook-120s-bzimage`

Artifact:
`/Serverless/iccd/experiments/20260508-cgroup-hss32-pc-demotealloc-hook-120s-bzimage/qemu-logs/phase_candidate_microbench/20260508T100557Z`

The first attempted run in `20260508-cgroup-hss32-pc-demotealloc-hook-120s`
was aborted because the wrapper selected `/boot/vmlinuz-6.18.0modified`.
This run explicitly booted:

- kernel: `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`
- initrd: `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260508-demotealloc-hook-bzimage.img`
- KVM: enabled
- VM: `MEMORY=96G`, `CPUS=32`, `HOST_CPUS=0-31`
- guest node0: `32G`, CPUs `0-31`, host node `0`
- guest node1: `64G`, host node `2`
- QEMU NUMA memory policy: `bind`, prealloc `1`
- cgroup cap: `CAPACITY_PAGES=4194304` (`16GiB`)
- MGLRU runtime: `0x0007`
- migration: `GLOBAL_NUMA_ON=0`, `NODE_BALANCING_ON=2`
- demotion: `KSWAPD_DEMOTION_ON=1`, `OFF_DEMOTION_ON=1`
- earlystop/pingpong/promote-sample: all disabled
- scan: `NUMA_SCAN_SIZE_MB=4096`, `SCAN_PERIOD_SCALE=100`, `HOT_THRESHOLD_MS=0`
- workload: `pc_lf_windowremote_32g_fixed_rss16g_chase1_persistent`
- placement: local-first-touch arena, 32GiB pointer-chase window on remote node1

## Result

Measured-window counters:

| counter | pages | GiB |
| --- | ---: | ---: |
| `RECLAIMD.debug_demote_selected` | 17,781,565 | 67.83 |
| `RECLAIMD.debug_demote_success` | 6,313,212 | 24.08 |
| `RECLAIMD.debug_demote_fail` | 11,468,353 | 43.75 |
| `RECLAIMD.debug_demote_alloc_success_thisnode` | 4,171,086 | 15.91 |
| `RECLAIMD.debug_demote_alloc_success_fallback` | 2,228,303 | 8.50 |
| `RECLAIMD.debug_demote_alloc_fail_thisnode` | 3,627,426 | 13.84 |
| `RECLAIMD.debug_demote_alloc_fail_fallback` | 1,399,123 | 5.34 |
| `MIGRATE.numa_migrate_fail_promotion_over_high` | 1,851,551 | 7.06 |
| `MIGRATE.numa_migrate_success_promotion` | 103,921 | 0.40 |

`vmstat.pgmigrate_fail` was 3,270,852 pages (12.48GiB). That global
counter includes promotion failures from the same run. Subtracting the
cgroup promotion over-high failures gives:

`3,270,852 - 1,851,551 = 1,419,301 pages` (5.41GiB)

This is within 20,178 pages (0.08GiB) of:

`RECLAIMD.debug_demote_alloc_fail_fallback = 1,399,123 pages` (5.34GiB)

So the actual attempted demotion migration failures are almost entirely
explained by target allocation failure in `alloc_demote_folio()`.

## Root Cause

The earlier large `debug_demote_fail` value should not be read as "all of
those pages were tried and failed to migrate." It is:

`selected_for_demotion - demoted_successfully`

In `mm/vmscan.c`, `demote_folio_list()` calls:

`migrate_pages(..., alloc_demote_folio, ..., MIGRATE_ASYNC, MR_DEMOTION, ...)`

`alloc_demote_folio()` uses:

`(GFP_HIGHUSER_MOVABLE & ~__GFP_RECLAIM) | __GFP_NOWARN | __GFP_NOMEMALLOC | GFP_NOWAIT`

It first tries the demotion target with `__GFP_THISNODE`, then retries with
the allowed target mask. If both allocations fail, `migrate_folio_unmap()`
returns `-ENOMEM`.

In `mm/migrate.c`, `migrate_pages_batch()` treats `-ENOMEM` specially:
it stops processing the remaining folios in that batch/list, moves any
already-unmapped folios, and then returns the error. Those remaining folios
come back to vmscan as undemoted, so the simple selected-minus-success counter
looks much larger than the actual allocation failure count.

Therefore the final cause is:

1. Reclaimd selects cold-enough node0 folios correctly. This is not a
   reference-bit/hot-page filtering failure.
2. Demotion then needs to allocate replacement folios on node1.
3. Node1 is already near capacity in the burst window, so `alloc_demote_folio()`
   sometimes cannot allocate even after fallback.
4. Because demotion runs under `MIGRATE_ASYNC` with non-reclaiming
   `GFP_NOWAIT`, that allocation failure becomes `-ENOMEM`.
5. `migrate_pages_batch()` aborts the rest of the demotion list after that
   allocation failure, leaving a large amount of selected-but-undemoted pages.

Live samples support this: during the failure burst, `anon_n1` was about
62GiB on a 64GiB node, while promotion over-high was also rising on node0.

## Live Timeline

| elapsed_s | anon_n0 GiB | anon_n1 GiB | promote GiB | demote GiB | over_high GiB | reclaimd runs/wakes | node0 over_high |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0.1 | 15.68 | 48.54 | 0.00 | 20.57 | 0.00 | 1/1 | 1 |
| 34.5 | 30.10 | 62.12 | 0.00 | 28.13 | 0.01 | 1/1 | 1 |
| 44.6 | 21.09 | 61.73 | 0.00 | 35.31 | 2.24 | 1/1 | 1 |
| 54.6 | 15.22 | 62.30 | 0.00 | 42.11 | 7.06 | 1/1 | 0 |
| 64.6 | 14.26 | 60.48 | 0.21 | 44.93 | 7.06 | 1/1 | 0 |
| 74.6 | 13.32 | 50.68 | 0.40 | 44.93 | 7.06 | 1/1 | 0 |
| 84.7 | 13.32 | 50.68 | 0.40 | 44.93 | 7.06 | 1/1 | 0 |
| 94.7 | 13.32 | 50.68 | 0.40 | 44.93 | 7.06 | 1/1 | 0 |
| 104.7 | 13.32 | 50.68 | 0.40 | 44.93 | 7.06 | 1/1 | 0 |
| 114.7 | 13.32 | 50.68 | 0.40 | 44.93 | 7.06 | 1/1 | 0 |
| 124.8 | 13.32 | 50.68 | 0.40 | 44.93 | 7.06 | 1/1 | 0 |
| 134.8 | 13.32 | 50.68 | 0.40 | 44.93 | 7.06 | 1/1 | 0 |

## Patch Direction

The dead-zone patch should wake cgroup reclaimd at the same point where the
promotion path decides the destination cgroup node is over high. The permanent
code change moves that wake into `mem_cgroup_node_over_high()` so every caller
of the over-high helper gets the same reclaimd wake behavior.
