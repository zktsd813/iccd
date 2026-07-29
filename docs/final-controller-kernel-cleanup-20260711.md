# Final Controller and Kernel Cleanup

Date: 2026-07-11

## Scope

This cleanup leaves one active quantile controller policy and one shared
controller runner for VM and host-native use. It removes obsolete policy code,
diagnostic kernel interfaces, and serialized GAPBS graph paths from the current
experiment stack.

The canonical controller files are:

```text
design/fault_bucket_controller/bucket_latency_controller.py
design/fault_bucket_controller/run_guest.sh
design/fault_bucket_controller/plot_controller.py
design/fault_bucket_controller/DESIGN.md
```

VM and host-native orchestration both invoke the same `run_guest.sh`. Workload
identity is not an input to the policy.

## Final Policy

Each accepted window reads a weighted-KLL kernel snapshot and recomputes the
workload process tree's resident capacity from `/proc/<pid>/numa_maps`:

```text
local resident capacity  = current pages resident on the local node
remote resident capacity = current pages resident on the remote node
local P75 latency        = current local Q75 probe-to-refault interval
```

The quantile source must identify itself as:

```text
algorithm    kll_weighted_ms_v1
value_source sketch_latency_ms_to_ns
```

STOP uses the inclusive remote CDF at local P75:

```text
local_tail_capacity         = 0.25 * local resident capacity
remote_capacity_at_or_below = remote_inclusive_cdf(local P75 latency)
                              * remote resident capacity
stop_ratio                  = remote_capacity_at_or_below / local_tail_capacity
STOP_RAW                    = stop_ratio > 0.9
```

STOP is immediate. Equality at `0.9` does not stop migration.

START is a latency-versus-latency decision. Capacity selects the remote
quantile rank used by that comparison:

```text
local_head_capacity         = 0.75 * local resident capacity
START-required capacity     = 1.10 * local_head_capacity
capacity-selected rank      = START-required capacity / remote resident capacity
selected remote latency     = Q_remote(capacity-selected rank)
local reference latency     = Q_local(0.75)

START_RAW iff selected remote latency < local reference latency
```

The kernel snapshot does not export the numeric selected remote latency. It
exports the strict remote CDF at local P75, so the controller implements the
equivalent Boolean test:

```text
remote_strict_cdf(local reference latency) * remote resident capacity
    >= START-required capacity
```

The 10% relative capacity margin selects a higher remote quantile and makes
START less permissive than the zero-margin comparison. Capacity chooses the
rank; latency determines START. START must be true in two consecutive valid
windows. A false or invalid window resets the START count.

Arbitration is fixed:

```text
confirmed START > raw STOP > HOLD
```

Consequently, a confirmed START wins if both conditions are true in one
window. The controller keeps `kernel.numa_balancing=2` and changes only
`migration_enabled`; sampling continues while migration is off.

## Retained Kernel ABI

Only the interfaces required by the final system are retained under
`/sys/kernel/mm/numa_balancing`:

```text
local_fault_rate                 read/write
local_fault_scan_period_ms       read/write, default 1000
local_fault_scan_size_mb         read/write, default 64
local_fault_window               read/write window advance
remote_scan_cycles               read-only cycle alignment
fault_latency_quantiles          read-only quantile_snapshot_v3
migration_enabled                read/write migration gate
```

`quantile_snapshot_v3` contains weighted sample totals, local P75, and strict
and inclusive remote CDF values at local P75. Normal NUMA scanning remains
configured separately at `256 MB`.

Removed ICCD diagnostic interfaces and code include the latency histogram,
arbitrary CDF query, per-node/PFN/round-robin sampler diagnostics,
`local_fault_stats`, automatic window/scan diagnostics, migration-disabled
debug counters, promotion-threshold debugfs output, and the default-off
`reuse_time` scheduler implementation.

## Canonical Configurations

Only these configuration names are accepted by the current runners:

| Config | `numa_balancing` | `migration_enabled` at entry | Demotion |
| --- | ---: | ---: | --- |
| `off` | 0 | 0 | `false` |
| `on` | 2 | 1 | `true` |
| `tpp` | 4 | 1 | `true` |
| `ours` | 2 | 1, then controller-managed | `true` |

PR and BC always generate scale-29 graphs with `-g 29`. The active stack does
not stage or consume `.sg` or `.wsg` graph files.

## TPP Availability

No external TPP package is required. The repository kernel already defines
`NUMA_BALANCING_TPP=0x4` and implements the active-LRU decision in
`should_numa_migrate_memory()`. With MGLRU enabled, it uses the folio generation
state; otherwise it falls back to the folio active bit.

The `tpp` runner configuration programs and verifies:

```text
/proc/sys/kernel/numa_balancing                  4
/sys/kernel/mm/numa_balancing/migration_enabled  1
/sys/kernel/mm/numa/demotion_enabled              true
```

The rebuilt kernel image is:

```text
path:   linux-global-build/arch/x86/boot/bzImage
build:  Linux 6.18.0modified #31
size:   12996800 bytes
mtime:  2026-07-11 13:36:29 UTC
sha256: 6f1814bfb084c139f9aaba537ae58fc49989f739a32da4e35be692509e55c810
```

The in-tree mode, runner mapping, state readback, quantile ABI, and TPP vmstat
counters have been checked for existence. This establishes that TPP can be
included as a future baseline on the same cleaned kernel; it is not a
performance claim.

## Verification Boundary

The controller's 28 unit tests pass, including START/STOP boundaries,
consecutive START confirmation, invalid-window reset, overlap arbitration,
current-residency recomputation, and the minimal ABI contract. The cleaned
kernel completed the focused object builds and a full `bzImage` build.

No full workload or performance experiment was launched for this cleanup. Two
short isolated ABI/controller checks had already completed before the explicit
no-experiment instruction; their temporary result directories were removed.
No QEMU or benchmark process is currently running.

The physical host is still running an older kernel that lacks
`remote_scan_cycles`. Host-native preflight therefore fails closed until a
deliberate later boot into build 31. No reboot or kernel installation is part
of this cleanup.

## Known Constraints

`remote_scan_cycles` is a global counter, so each measured VM must remain
isolated to one workload. Resident `L` and `R` are recomputed from the workload
PID tree every window and are not physical local-memory limits. A local
protection probe installed immediately before a manual window advance can
refault in the following window; raw quantile snapshots are retained so this
boundary behavior remains auditable.
