# Migration On Fault Diagnosis

Date: 2026-06-01 UTC

Scope: `guest-results/pr-g29-local16/migration_on`

## Finding

The low promotion count was not caused by `demotion_enabled` being off.

Evidence from `before.meta` and `after.meta`:

```text
numa_balancing=2
lru_gen_enabled=0x0007
demotion_enabled=true
demotion_target:
0 1
1 -1
```

`pgdemote_kswapd` increased by `1,945,029` pages during the run, so demotion
was active. `pgdemote_direct` stayed `0`; demotion was kswapd-driven.

The actual weak point was the NUMA fault path:

```text
numa_pte_updates_delta=470
numa_hint_faults_delta=309
numa_pages_migrated_delta=95
pgpromote_success_delta=95
pgpromote_candidate_delta=296
pgpromote_candidate_demoted_delta=261
```

Only 470 PTEs were marked for NUMA hinting, only 309 hint faults occurred, and
only 95 pages were promoted. That is far too little for a workload with roughly
138 GiB sampled residency.

The global local-fault sampler did not participate in this run:

```text
local_fault_rate=0
local_fault_pte_updates=0
local_fault_refault=0
local_fault_refault_hit=0
```

This is expected with the current runner because it does not set
`/sys/kernel/mm/numa_balancing/local_fault_rate`.

## Interpretation

For `numa_balancing=0x2`, the kernel is in memory-tiering mode. In this mode,
top-tier pages are skipped by the PTE marking path when normal NUMA balancing
is not enabled. The run should still sample slow-tier pages for promotion, but
the observed PTE marking is almost absent.

Demotion happened, but most slow placement in this 16G-local setup came from
allocation/fallback to guest node1 after node0 filled, not from a large stream
of demotions. Promotion then depended on the hint-fault scanner finding and
marking those slow pages. It mostly did not.

## VM Tier Diagnosis

A follow-up diagnostic VM using the same kernel and QEMU NUMA shape showed that
the guest classifies node0 and node1 in the same default DRAM memory tier:

```text
/sys/devices/virtual/memory_tiering/memory_tier4/nodelist
0-1
```

Before manual configuration, there was no demotion target:

```text
demotion_enabled=false
demotion_target:
0 -1
1 -1
```

After writing the requested knobs:

```text
demotion_enabled=true
demotion_target:
0 1
1 -1
```

The memory tier nodelist remained `0-1`. This is expected for the current
`vmctl.sh` QEMU command because both guest NUMA nodes are backed with
`memory-backend-ram`; the VM does not expose HMAT/CDAT/CXL-style performance
coordinates that would let the guest classify node1 as a lower memory tier.

So the top-tier scan skip is enabled because `numa_balancing=0x2` is
memory-tiering-only mode, not because a separate skip knob was set. The VM
classification makes this fragile: node1 is not a true lower tier in guest
sysfs, and only the manual demotion path `0 -> 1` tells the kernel that node1
can be a promotion source.

## Next Checks

1. Re-run a short diagnostic with `numa_balancing=3` to see whether enabling
   normal NUMA balancing together with memory tiering produces large
   `numa_pte_updates` and `numa_hint_faults`.
2. Re-run a migration-on diagnostic with `local_fault_rate` set above zero to
   validate whether the local-fault sampler can observe the PR working set.
3. Add live capture of `/proc/<pr-pid>/numa_maps` and selected VMA metadata
   while the process is running, because the current samples only preserve
   aggregate node residency.
