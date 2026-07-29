# TPP Baseline Feasibility

Date: 2026-07-11

## Verdict

TPP does not need to be imported or installed as a separate project. The
cleaned Linux 6.18 tree in this repository already contains the TPP-style
memory-tiering policy, selected by writing `4` to
`/proc/sys/kernel/numa_balancing`.

The canonical experiment configurations are now exactly `off`, `on`, `tpp`,
and `ours`:

| Config | NUMA balancing | Migration gate at entry | Demotion | ICCD local sampler |
| --- | ---: | ---: | --- | --- |
| `off` | `0` | `0` | `false` | disabled |
| `on` | `2` | `1` | `true` | disabled |
| `tpp` | `4` | `1` | `true` | disabled |
| `ours` | `2` | `1` | `true` | rate `5`, `64 MB` every `1000 ms` |

All four configurations use the same kernel, topology, workload binaries,
normal NUMA scan size (`256 MB`), and generated GAPBS graph (`-g 29`). The
`ours` controller may subsequently toggle only the migration gate as its
policy decisions change.

## In-Tree Implementation

The mode definition and tiering mask are in
`linux/include/linux/sched/sysctl.h`:

```c
#define NUMA_BALANCING_MEMORY_TIERING  0x2
#define NUMA_BALANCING_TPP             0x4

#define NUMA_BALANCING_TIERING_MASK \
        (NUMA_BALANCING_MEMORY_TIERING | NUMA_BALANCING_TPP)
```

The TPP decision is implemented in `should_numa_migrate_memory()` in
`linux/kernel/sched/fair.c`:

1. The normal NUMA scanner samples a folio in the non-top tier and generates a
   NUMA hint fault.
2. The common migration gate can reject migration before a policy decision is
   acted upon.
3. In TPP mode, an inactive folio is marked accessed and rejected for that
   fault.
4. A folio that is active on a later fault becomes a promotion candidate.
5. This branch runs before the normal mode-2 reuse-latency and promotion-rate
   decisions. Allocation, watermark, isolation, and migration failures can
   still prevent a successful promotion.

With MGLRU enabled, the active test uses `folio_lru_gen()` and
`lru_gen_is_active()`. Without MGLRU, it falls back to
`folio_test_active()`. This provides the intended active-LRU hysteresis: one
observation can activate a page and a later observation can promote it.

The supporting integration is also in-tree:

- `linux/mm/memory-tiers.c` treats modes `2` and `4` as tiering modes.
- `linux/mm/vmscan.c` uses the promotion watermark for both tiering modes.
- `linux/mm/mprotect.c` and `linux/mm/huge_memory.c` permit slow-tier sampling
  while avoiding inappropriate top-tier scanning.
- `linux/kernel/sched/core.c` accepts mode `4` and initializes tiering state.
- `/proc/vmstat` exports the standard promotion/demotion counters and the four
  TPP-specific counters listed below.

The implementation originated in repository commit `4ed1ca043b` and is
documented in `linux/Documentation/admin-guide/sysctl/kernel.rst`.

## Cleanup Outcome

### VM path

The VM orchestration path is now internally consistent:

- `motivation/3_realworld/VM/scripts/run_vm_sweep_host.sh` and
  `run_vm_sweep_guest.sh` default to and accept only the four canonical config
  names.
- `run_workload_case_guest.sh` maps `tpp` to mode `4`, migration `1`, and
  demotion `true`; it maps `off` to `0`, `0`, and `false`.
- Required-state verification reads back NUMA balancing, the migration gate,
  and demotion state before accepting a case.
- Normal scan size defaults to `256 MB`; the controller-only local scan defaults
  to `64 MB` every `1000 ms`.
- PR and BC use generated `-g 29`. The orchestration does not stage or mount a
  serialized GAPBS graph.
- The default matrix is 16/32/48 GiB by four configs by seven workloads, for 84
  cases.

### Host-native path

The shared-controller host-native path is also fixed:

- `submission/eval_1_realworld/host_native/run_host_native_migration_sweep.sh`
  accepts only `off`, `on`, `tpp`, and `ours`.
- It enforces GAPBS scale 29 and constructs PR/BC with `-g 29`; there is no
  serialized-graph mode or graph path.
- It sets and reads back all three policy states. In particular, `tpp` must read
  back `4/1/true`, while `off` must read back `0/0/false`.
- It requires the cleaned ABI sources `fault_latency_quantiles` and
  `remote_scan_cycles`.
- Its snapshots no longer depend on removed statistics, histogram, CDF-query,
  or automatic-scan interfaces.
- `start_quantile_after_reboot.sh` forwards the same canonical modes and final
  controller parameters after a deliberate future reboot.

The shared defaults used by these paths are now `256 MB` for normal NUMA
scanning and `64 MB` for local controller sampling. Legacy scan-size values are
no longer runner defaults.

## Final Controller Contract

The controller-facing environment is intentionally small:

```text
WINDOW_SEC=1
CYCLE_WINDOW_MIN_SEC=5
CYCLE_WINDOW_MAX_SEC=20
LOCAL_RATE=5
LOCAL_FAULT_SCAN_PERIOD_MS=1000
LOCAL_FAULT_SCAN_SIZE_MB=64
MIN_LOCAL_PAGES=1024
MIN_REMOTE_PAGES=1024
START_CONSECUTIVE=2
START_CAPACITY_MARGIN_PCT=10
STOP_CAPACITY_RATIO_THRESHOLD=0.9
LOCAL_NODE=0
REMOTE_NODE=1
MIGRATION_ENABLED_PATH=/sys/kernel/mm/numa_balancing/migration_enabled
```

The host-native orchestrator stores the policy values with an `OURS_` prefix
where needed for reboot persistence, then maps them to these generic names when
invoking `design/fault_bucket_controller/run_guest.sh`. Score, restart,
multi-phase, and historical controller variables are no longer forwarded.

## Completed New-Kernel Existence Check

An already-completed boot/ABI smoke used the rebuilt kernel image and reported
`Linux 6.18.0modified #31`. This was an existence check, not a workload
performance result.

The booted image successfully set and read back the TPP state:

```text
/proc/sys/kernel/numa_balancing                 = 4
/sys/kernel/mm/numa_balancing/migration_enabled = 1
/sys/kernel/mm/numa/demotion_enabled             = true
```

The cleaned quantile ABI was present and emitted:

```text
schema quantile_snapshot_v3
```

`remote_scan_cycles` was present, and `/proc/vmstat` contained all four TPP
diagnostic counters:

```text
numa_tpp_inactive_reject
numa_tpp_inactive_reject_pages
numa_tpp_active_candidate
numa_tpp_active_candidate_pages
```

This confirms that build 31 boots, accepts mode 4, exposes the final quantile
schema, and contains the TPP accounting hooks. It does not establish TPP
performance or require launching a workload now.

The physical host observed during this cleanup is still on build 20 and lacks
`remote_scan_cycles`. The host-native preflight therefore refuses to start a
measurement until that host is deliberately rebooted into the final kernel.
No experiment was launched as part of this documentation update.

## Fair Future Comparison

When a measured comparison is intentionally scheduled, hold these conditions
fixed:

| Setting | Required value |
| --- | --- |
| Guest CPUs | 32, all on guest node 0 |
| Fast/slow guest nodes | node 0 / CPU-less node 1 |
| Host backing nodes | node 0 / node 2 |
| Local capacities | 16, 32, and 48 GiB |
| Normal NUMA scan | `256 MB`, minimum period `1000 ms` |
| Controller local scan | `64 MB` every `1000 ms`, only for `ours` |
| MGLRU | `0x0007` for every policy |
| THP | one explicit common value |
| Swap | disabled |
| GAPBS PR/BC | generated `-g 29`; never a serialized graph |

Use a fresh VM for each measured case. Reusing a VM across modes can retain
LRU, reclaim, allocator, and tiering state. VM and host-native absolute runtimes
must also remain separate because VM local capacity is a physical guest-node
size, whereas the host-native path constrains node-0 free memory by offlining
memory blocks.

The VM matrix can be inspected without launching a workload:

```bash
DRY_RUN=1 \
LOCAL_SIZES_GIB='16 32 48' \
CONFIGS='off on tpp ours' \
WORKLOADS='pr bc gups btree graph500 silo liblinear' \
GAPBS_GRAPH_SCALE=29 \
NUMA_SCAN_SIZE_MB=256 \
LOCAL_FAULT_SCAN_PERIOD_MS=1000 \
LOCAL_FAULT_SCAN_SIZE_MB=64 \
WINDOW_SEC=1 \
CYCLE_WINDOW_MIN_SEC=5 \
CYCLE_WINDOW_MAX_SEC=20 \
LOCAL_RATE=5 \
MIN_LOCAL_PAGES=1024 \
MIN_REMOTE_PAGES=1024 \
START_CONSECUTIVE=2 \
START_CAPACITY_MARGIN_PCT=10 \
STOP_CAPACITY_RATIO_THRESHOLD=0.9 \
LOCAL_NODE=0 \
REMOTE_NODE=1 \
MIGRATION_ENABLED_PATH=/sys/kernel/mm/numa_balancing/migration_enabled \
motivation/3_realworld/VM/scripts/run_vm_sweep_host.sh
```

The expected plan has 12 VM configurations and 84 workload cases, reports
generated g29, and shows `tpp` as `numa=4 migration=1 demotion=true`.

## Invalid or Stale Alternatives

Do not use these as the TPP row in the comparison:

1. `/Serverless/iccd/TPP-5.15` is referenced by an old context document but no
   longer exists on this machine.
2. `/Serverless/Migration-friendly/linux-6.9-smdk-tpp` has an old built image,
   but it is a different 6.9 kernel with extensive migration-friendly changes
   and MGLRU disabled. Comparing it with the cleaned 6.18 policies would
   confound both kernel version and implementation.
3. `/Serverless/Migration-friendly/colloid/tpp/linux-6.3` is the separate
   TPP+Colloid artifact. In that tree, bit `0x2` selects TPP memory tiering, bit
   `0x4` selects Colloid, and `0x6` combines them. It also expects a tier
   initializer and architecture-specific hardware-counter modules. It is not
   the current in-tree mode-4 baseline.
4. The paper PDF and old 5.15 diff files remain useful provenance, but they are
   not a maintained build target for this experiment.

Colloid could be evaluated separately on the physical Emerald Rapids host if
that becomes a distinct research question. It must not be silently included
under the TPP label, and its CHA hardware-counter backend is not a valid VM
baseline without explicit PMU pass-through validation.
