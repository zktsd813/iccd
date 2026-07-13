# ICCD Experiment Scripts

## Canonical Controller

There is one active controller implementation:

```text
design/fault_bucket_controller/bucket_latency_controller.py
```

All `ours` runs use its shared runner:

```text
design/fault_bucket_controller/run_guest.sh
```

The VM workload path is:

```text
motivation/3_realworld/VM/scripts/run_vm_sweep_guest.sh
  -> motivation/3_realworld/VM/scripts/run_workload_case_guest.sh
  -> design/fault_bucket_controller/run_guest.sh  (ours only)
```

The `scripts/` directory does not contain a second controller policy.
`run_workload_suite_guest.sh` is only a compatibility entrypoint that validates
the current protocol and forwards to the canonical VM sweep.

## Final Policy

For each valid window, the controller rereads the workload process tree and
computes current local and remote resident capacities:

```text
L = local resident pages
R = remote resident pages
q = local P75 latency
```

STOP uses the inclusive remote CDF at `q`:

```text
local_tail       = 0.25 * L
remote_candidate = F_le(q) * R
STOP_RAW         = remote_candidate / local_tail > 0.9
```

START uses the strict remote CDF below `q`:

```text
START_RAW = F_lt(q) * R >= 1.10 * 0.75 * L
```

START requires two consecutive valid windows. Confirmed START has precedence
over STOP when both conditions are true. The controller keeps NUMA balancing
enabled and changes only `migration_enabled`.

The complete policy and required kernel ABI are documented in
`design/fault_bucket_controller/DESIGN.md`.

## Fixed Protocol

The top-level compatibility entrypoint and staging path enforce these values;
the canonical VM runners use the same defaults:

```text
GAPBS graph mode                 generated
GAPBS graph scale                29
normal NUMA scan size            256 MiB
local fault scan size            64 MiB
local fault scan period          1000 ms
configs                          off on tpp ours
```

PR and BC commands use `-g 29` in the measured path. Prebuilt `.sg` and `.wsg`
graphs are neither staged nor accepted by the compatibility entrypoint.

The final controller variables are:

```text
WINDOW_SEC                       default 1
CYCLE_WINDOW_MIN_SEC             default 5
CYCLE_WINDOW_MAX_SEC             default 20
LOCAL_RATE                       default 5
MIN_LOCAL_PAGES                  default 1024
MIN_REMOTE_PAGES                 default 1024
START_CONSECUTIVE                default 2
START_CAPACITY_MARGIN_PCT        default 10
STOP_CAPACITY_RATIO_THRESHOLD    default 0.9
LOCAL_NODE                       default 0
REMOTE_NODE                      default 1
MIGRATION_ENABLED_PATH           default /sys/kernel/mm/numa_balancing/migration_enabled
```

## Staging

`stage_workloads_to_vm.sh` stages:

- the canonical controller and shared controller runner under
  `/root/design/fault_bucket_controller`;
- the canonical VM sweep and case runner under
  `/root/motivation/3_realworld/VM/scripts`;
- the real-world workload command helper under `/root/scripts`.

The staging path never creates `/root/gapbs_graphs`.

Its default workload set is `pr bc gups btree graph500 silo`, matching
the canonical case runner.

Shared VM defaults remain in `scripts/iccd_experiment_defaults.sh`. Workloads
are placed on CPU node 0 by default, and local-memory capacity is configured by
the VM topology rather than a controller-side capacity emulation knob.

## Production Kernel Config

Apply the lean experiment configuration to the active out-of-tree build with:

```bash
scripts/configure_iccd_production_kernel.sh
make -C linux O=linux-global-build -j"$(nproc)" bzImage
```

The configuration removes DWARF, KGDB/KDB, dynamic debug, function and event
tracing, scheduler debug accounting, PSI, taskstats, the legacy tick profiler,
kprobes/kallsyms, allocator/page poisoning, lockup and hung-task checks, MGLRU
historical debug statistics, unused KVM host support, and unused driver debug
code. Hardware `perf` events remain available but dormant until requested.
Normal NUMA scan controls are exposed through
`/sys/kernel/mm/numa_balancing/numa_scan_*`, so `CONFIG_DEBUG_FS` is disabled.
