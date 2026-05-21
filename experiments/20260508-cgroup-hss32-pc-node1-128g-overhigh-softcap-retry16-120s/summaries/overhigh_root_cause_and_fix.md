# cgroup promotion over_high root cause and fix

Date: 2026-05-08

Final artifact:
`/Serverless/iccd/experiments/20260508-cgroup-hss32-pc-node1-128g-overhigh-softcap-retry16-120s/qemu-logs/phase_candidate_microbench/20260508T110328Z`

Run directory:
`guest-artifacts/20260508T110328Z/pc_lf_windowremote_32g_fixed_rss16g_chase1_persistent__on__rep1`

## Root cause

The remaining failure was not node1 target allocation failure. After guest node1 was increased to 128G, the demotion allocation proxy `pgmigrate_fail - promotion_over_high` was effectively gone, but `promotion_over_high` remained large.

The code-level cause was that `mem_cgroup_node_over_high()` used the soft redirect watermark as a hard promotion failure gate:

- `memcg_node_exceeds_redirect_limit()` returns true in watermark mode when projected node0 usage does not have the configured high reserve.
- With the current 16GiB local cap, low is 95% and high is 98%:
  - capacity: 4,194,304 pages / 16.00GiB
  - low: 3,984,588 pages / 15.20GiB
  - high: 4,110,417 pages / 15.68GiB
- Promotion candidates that arrived while node0 was between high and the point where reclaimd had finished demoting were returned as `-EAGAIN` and counted as `numa_migrate_fail_promotion_over_high`.
- Those pages were then remapped present and would only be reconsidered when NUMA scanning revisited them, so a transient reclaim-lag condition became lost promotion volume.

So the bug was semantic: high watermark should be a reclaim/wakeup threshold, not a terminal migration-failure condition. The hard failure boundary should be the configured node capacity after bounded reclaim has failed.

## Patch

Changed `/Serverless/Migration-friendly/linux/mm/memcontrol.c`:

- Added `memcg_node_redirect_within_capacity()` to distinguish soft high from hard capacity.
- Added a bounded synchronous reclaim path for the rare hard-cap boundary:
  - claim the memcg reclaimd node slot,
  - run `memcg_reclaimd_shrink_node()`,
  - recheck headroom,
  - retry up to 16 times.
- Updated `mem_cgroup_node_over_high()`:
  - if projected usage exceeds the soft redirect limit, wake reclaimd;
  - if projected usage is still within node capacity, allow promotion;
  - only if projected usage exceeds capacity, run bounded reclaim and fail after it still cannot make room.

Changed `/Serverless/Migration-friendly/linux/mm/migrate.c`:

- Removed the duplicate reclaimd wake from `alloc_misplaced_dst_folio()` because `mem_cgroup_node_over_high()` now owns the wake/reclaim decision.

## Validation setup

- Kernel image: `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`
- Kernel build: `make -C /Serverless/Migration-friendly/linux -j64 bzImage modules`
- Kernel build id used by final run: `6.18.0modified #148`
- Initrd: fresh `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260508-overhigh-softcap-retry16-node1-128g.img`
- QEMU: KVM, 32 vCPUs, 160G guest memory
- NUMA node0: 32G, CPUs 0-31, host node bind 0
- NUMA node1: 128G, host node bind 2
- cgroup cap: `CAPACITY_PAGES=4194304`
- MGLRU: `enabled=0x0007`
- NUMA scan: `NUMA_SCAN_SIZE_MB=4096`, `SCAN_PERIOD_SCALE=100`, `HOT_THRESHOLD_MS=0`
- Workload: `mbench --arena-size 64G --mode pc --window-size 32G --window-offset 0 --move-policy fixed --pc-chains 1 --pc-pattern random --hotset-prefault-node 1 --threads 32 --duration-ms 120000`
- Disabled diagnostic knobs:
  - `NUMA_MIGRATION_STOP_ENABLED=0`
  - `NUMA_PINGPONG_STAT_ENABLED=0`
  - `NUMA_PROMOTE_SAMPLE_STAT_ENABLED=0`
  - `NUMA_PROMOTE_SAMPLE_RATE=0`

## Result comparison

| run | promoted | demoted | over_high fail | pgmigrate_fail | candidate | wmark bypass | mean ops/s | median ops/s | reclaimd run/wake | max node0 usage | max node1 anon |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| before node1=128G | 8.90GiB | 13.65GiB | 2,919,788 pages / 11.14GiB | 2,920,174 | 5,252,918 | 5 | 95.43M | 159.25M | 5 / 5 | 15.68GiB | 81.58GiB |
| sync reclaim at high | 6.22GiB | 11.78GiB | 16 pages | 237 | 1,631,107 | 5 | 97.78M | 161.52M | 4 / 4 | 15.66GiB | 81.05GiB |
| softcap, retry 3 | 12.92GiB | 17.07GiB | 23 pages | 213 | 2,965,875 | 422,166 | 92.80M | 138.81M | 3 / 3 | 15.99GiB | 81.64GiB |
| final softcap, retry 16 | 14.25GiB | 15.39GiB | 0 pages / 0.00GiB | 269 | 2,636,417 | 1,097,913 | 90.82M | 113.51M | 3 / 3 | 15.91GiB | 81.03GiB |

The final run removes the cgroup `promotion_over_high` failure completely for this workload: `numa_migrate_fail_promotion_over_high=0`.

The remaining `vmstat.pgmigrate_fail=269` pages is not from the cgroup over-high gate. It is ordinary migration failure volume from the generic migration path.

## Interpretation

This confirms the cause and fix:

- The large previous over-high volume was caused by treating a soft cgroup high watermark as a hard migration rejection point.
- Waking reclaimd alone was insufficient because candidates were failed before reclaimd could create headroom, and those candidates were not retried immediately.
- Allowing soft-high promotion while reclaimd runs, and reserving hard rejection for actual capacity exhaustion after bounded reclaim, removes the over-high failure path while keeping node0 usage under the configured 16GiB capacity in the observed run.
