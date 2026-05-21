# Demotion Debug Summary

Date: 2026-05-07 UTC

Kernel used for debug runs:

- `/Serverless/Migration-friendly/linux`
- debug bzImage built as `Linux kernel 6.18.0modified #105`
- temporary hooks were added to `memcg_reclaimd_ctx` and removed after validation
- clean bzImage rebuilt after hook removal as `#106`

## Question

`pgdemote_kswapd` was zero during migration-on experiments, which made it look
like demotion was not happening. The debug hook checked whether memcg reclaimd
actually called vmscan and whether demotion was accounted as kswapd or direct.

## Result

Demotion is happening from `memcg_reclaimd`, but the existing kernel accounting
classifies it as `PGDEMOTE_DIRECT`, not `PGDEMOTE_KSWAPD`.

Reason:

- `memcg_reclaimd()` sets `PF_MEMALLOC`, but it does not set `PF_KSWAPD`.
- `current_is_kswapd()` returns `current->flags & PF_KSWAPD`.
- `vmscan.c::reclaimer_offset()` returns `DIRECT` unless `current_is_kswapd()`
  is true.
- Therefore demotions caused by `memcg_reclaimd_shrink_node()` are counted in
  `pgdemote_direct`.

## Evidence

### pc_64g_stride_remoteft, on, 20s measured

- promote: `4,615,919 pages` = `17.61 GiB`
- reclaimd: `wake_count=1`, `run_count=1`
- debug shrink calls: `262`
- debug scanned: `36,181,197 pages`
- debug reclaimed: `905,070 pages`
- debug demote direct: `905,060 pages`
- debug demote kswapd: `0 pages`
- debug PF_KSWAPD calls: `0`
- `memory.numa_stat` showed `pgdemote_kswapd=0`

### sparse_stride_read_64g_block2m_remoteft, on, 20s measured

- promote: `3,946,307 pages` = `15.05 GiB`
- reclaimd: `wake_count=1`, `run_count=1`
- debug shrink calls: `212`
- debug scanned: `29,015,739 pages`
- debug reclaimed: `262,860 pages`
- debug demote direct: `224,578 pages`
- debug demote kswapd: `0 pages`
- debug PF_KSWAPD calls: `0`
- `memory.numa_stat` diff showed `pgdemote_direct=262,858`,
  `pgdemote_kswapd=0`

## Interpretation

For current cgroup node-capacity reclaim, `pgdemote_kswapd` alone is not a valid
demotion indicator. Use one of these instead:

- `memory.numa_stat: pgdemote_direct` for current implementation
- a future dedicated reclaimd demotion stat if we want cleaner semantics
- a kernel fix that treats memcg reclaimd as kswapd-like only for selected
  accounting/force-LRU decisions

Do not blindly set `PF_KSWAPD` on memcg reclaimd without review. That flag is
used in many vmscan/MGLRU paths beyond stat accounting.
