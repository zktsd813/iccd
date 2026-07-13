# Controller and Kernel Production Cleanup

Date: 2026-07-12

## Scope

This cleanup removes debugging and retrospective-analysis overhead from the
active controller experiment path. It does not change the START, STOP, guard
STOP, or joint local/remote restart policy.

The active policy remains:

```text
policy = capacity_rank_latency_local_remote_restart_v3

START_RAW:
  Q_remote(ceil(1.10 * 0.75 * local_resident / remote_resident))
      < Q_local(0.75)
  confirmed after two consecutive valid windows

STOP_RAW:
  remote_CDF_le(local_P75) * remote_resident
      / (0.25 * local_resident) > 0.9

guard STOP:
  START_RAW and STOP_RAW overlap, while local P75 improves by less than 10%,
  for three consecutive comparisons

restart from guard STOP:
  START_RAW
  and local P75 is at least 10% worse than the frozen local reference
  and remote latency at the frozen rank is at least 10% better
  for three consecutive valid windows
```

## Controller Cleanup

Removed from the timed controller path:

- per-window copies of the complete `fault_latency_quantiles` sysfs text;
- the `--sample-dir` interface and `fault_latency_windows` output directory;
- guest-side matplotlib execution;
- duplicate inner before/after vmstat, PSI, NUMA-topology, and quantile
  snapshots;
- per-row readback of `numa_balancing` and `migration_enabled`;
- CSV columns used only by the removed raw-snapshot and readback paths;
- the extrapolated remote-page count that was logged only for diagnosis;
- the benchmark-specific B-tree fallback; `WORKLOAD_COMMAND` is now required;
- compatibility parsing of obsolete controller CSV column names.

The CSV still records the current KLL inputs, resident local/remote capacity,
START and STOP results, guard references and counters, arbitration, and state
transitions. Static configuration remains in `config.meta`. Controller plots
are generated on the host after guest results have been copied.

## Experiment Runner Cleanup

The active VM case runner no longer launches the two periodic diagnostic
processes that sampled process NUMA maps, node memory, and promotion counters
every five seconds. Unused pre-run topology, zoneinfo, free-memory, quantile,
and full dmesg snapshots were also removed. The runner retains only the
measurements required to classify and summarize a run:

- `/usr/bin/time` elapsed time and maximum RSS;
- before/after standard vmstat deltas;
- OOM and timeout status;
- command, placement, kernel, NUMA, and policy configuration metadata.

Guest staging no longer copies the plotter, summarizer, an unused compatibility
case runner, or other host-only analysis code. The default workload set is now
`pr bc gups btree graph500 silo`; Liblinear remains excluded.

Replay and audit programs for the abandoned inverse-capacity, main-phase stop
gate, and refill-settle policies were removed from the active VM script
directory. Existing result data and written analyses were not deleted.

Baseline modes now force `local_fault_rate=0`. Only the controller enables a
rate in `[1, 100]`, and it restores zero when the workload exits. This makes
OFF, ON, and TPP independent of the controller measurement machinery.

## Kernel Source Cleanup

The following reporting-only vmstat events and all of their hot-path increments
were removed:

```text
NUMA_PROMOTE_ACCESS(_PAGES)
NUMA_PROMOTE_NRL(_PAGES)
NUMA_PROMOTE_LATENCY_REJECT(_PAGES)
NUMA_PROMOTE_HOT(_PAGES)
NUMA_PROMOTE_RATE_LIMIT_REJECT(_PAGES)
NUMA_PROMOTE_TRY(_PAGES)
NUMA_TPP_INACTIVE_REJECT(_PAGES)
NUMA_TPP_ACTIVE_CANDIDATE(_PAGES)
```

The migration decisions and functional `PGPROMOTE_CANDIDATE*` accounting are
unchanged. A sampler-only `WARN_ON_ONCE` and cpuset trace emission were also
removed.

The quantile snapshot no longer formats these descriptive fields on every
read:

```text
unit
rank_error_ppm
sketch_levels
sketch_level_capacity
```

It retains the schema and source identity, sample totals, local P75, remote
query rank/latency/validity, and strict/inclusive CDFs required by the policy.

Remote KLL updates and remote scan-cycle bookkeeping now return immediately
when `local_fault_rate=0`. The cycle path also clears a pending scan marker
while disabled. The policy inputs therefore remain available during a
controller run without adding KLL or cycle-accounting work to baseline runs.

The four normal NUMA scan controls were moved from scheduler debugfs to the
regular NUMA-balancing sysfs group:

```text
/sys/kernel/mm/numa_balancing/numa_scan_size_mb
/sys/kernel/mm/numa_balancing/numa_scan_period_min_ms
/sys/kernel/mm/numa_balancing/numa_scan_period_max_ms
/sys/kernel/mm/numa_balancing/numa_scan_delay_ms
```

## Production Kernel Configuration

The reproducible configuration command is:

```bash
scripts/configure_iccd_production_kernel.sh
```

It disables the non-policy debug facilities inherited from the original host
configuration, including DWARF and GDB scripts, KGDB/KDB, dynamic debug,
function/event tracing, scheduler statistics and preemption debugging, SLUB
debugging, page poisoning, MGLRU historical debug statistics, PSI, taskstats,
scheduler stack checks, scheduler-info accounting, hung-task and lockup
watchdogs, kprobes, kallsyms, the legacy tick profiler, idle-page tracking,
frame pointers, debug/test modules, and unused driver debug paths. Unused KVM
host modules are disabled in this guest kernel so they cannot force scheduler
accounting back on. The x86 ORC unwinder replaces frame-pointer unwinding;
hardware `perf` events remain available and dormant until requested.

`CONFIG_DEBUG_KERNEL=y` remains visible because `CONFIG_EXPERT` selects the
Kconfig menu symbol. Its runtime debugging children listed above are disabled.
The scan controls no longer depend on scheduler debugfs, so
`CONFIG_DEBUG_FS=n` in the production build.

## Retained Functional Cost

The local sampler's `page_ext` state, local and remote weighted-KLL sketches,
remote scan-cycle counter, frozen-rank quantile query, and migration gate are
policy inputs rather than debugging code and remain enabled.

In particular, the local sampler stores an eight-byte window sequence per PFN
in `page_ext`. Together with the base `page_ext` flags this consumes 16 bytes
per physical 4 KiB page. Removing it would allow the same local page to be
sampled repeatedly within one window and would change the measured
distribution. Reducing that memory requires a separate bitmap or epoch-storage
design and is not a cleanup-only change.

## Verification

The cleaned controller passed all 37 unit tests. The submission results
pipeline passed all five tests. Shell syntax, Python compilation, and
`git diff --check` passed for the changed active paths.

The full production kernel build completed successfully:

```text
release:       Linux 6.18.0modified #35
bzImage:       linux-global-build/arch/x86/boot/bzImage
size:          10,055,872 bytes
sha256:        cf90c623b945575ae40e74041b27282526e81686fd773c339cdae2ae56dd4685
vmlinux size:  52,343,216 bytes
```

For comparison, the pre-cleanup `vmlinux` was approximately 460 MiB and the
kernel image was approximately 13 MiB.

A two-node, 8 GiB QEMU boot smoke test verified all 12 NUMA-balancing sysfs
entries, all four normal scan controls, quantile snapshot fields, window
advance, migration/rank/rate knob writeback, and absence of debugfs, PSI,
kallsyms, and the removed vmstat counters. With `local_fault_rate=0`, the booted
kernel reported zero local samples, zero remote samples, and zero remote scan
cycles. No performance workload was run. The smoke VM and temporary overlay
were stopped and deleted afterward.

Because the production configuration and sampling gate change runtime
accounting, results from builds 32 through 34 must not be mixed directly with
build 35. OFF, ON, TPP, and controller baselines must be rerun on build 35 for
paper-quality comparisons.
