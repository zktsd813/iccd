# ICCD Experiment Protocol

Originally recorded: 2026-06-01. Current revision: 2026-07-11.

This is the required protocol for the current ICCD two-tier memory stack in
`/Serverless/iccd-git`.

## Source of Truth

```text
repository          /Serverless/iccd-git
kernel source       /Serverless/iccd-git/linux
kernel build        /Serverless/iccd-git/linux-global-build
kernel image        linux-global-build/arch/x86/boot/bzImage
VM helper           VM/vmctl.sh
VM sweep            motivation/3_realworld/VM/scripts/run_vm_sweep_host.sh
shared controller   design/fault_bucket_controller/run_guest.sh
policy definition   design/fault_bucket_controller/DESIGN.md
```

Do not use `/Serverless/iccd`, an older kernel image, a separate controller
implementation, or cgroup/memcg NUMA policy knobs for current measurements.

## Canonical Configurations

Only these result configurations are valid:

| Config | `numa_balancing` | `migration_enabled` at entry | Demotion | Local sampler |
| --- | ---: | ---: | --- | --- |
| `off` | 0 | 0 | `false` | disabled |
| `on` | 2 | 1 | `true` | disabled |
| `tpp` | 4 | 1 | `true` | disabled |
| `ours` | 2 | 1, then controller-managed | `true` | enabled |

The runner must read back all three policy states before starting a measured
workload. `off` disables both promotion and demotion. `ours` keeps NUMA
scanning enabled and changes only `migration_enabled`.

## Fixed Scan Settings

Use these values unless the current experiment request explicitly overrides
them:

```text
MGLRU_ENABLED=0x0007
NUMA_SCAN_SIZE_MB=256
NUMA_SCAN_PERIOD_MIN_MS=1000
LOCAL_FAULT_RATE=5                  # ours only
LOCAL_FAULT_SCAN_PERIOD_MS=1000     # ours only
LOCAL_FAULT_SCAN_SIZE_MB=64         # ours only
START_CAPACITY_MARGIN_PCT=10        # ours only
DEMOTION_TARGET="0 1"
```

Do not use an automatic or capacity-scaled local scan size. Do not add a
hot-threshold, histogram, arbitrary CDF, score, phase, trace, or restart-policy
knob to the current controller path.

## Controller Contract

The controller recomputes current local and remote resident pages, `L` and
`R`, from the workload PID tree every accepted window. With local P75 latency
`q`:

```text
STOP_RAW  = (F_remote_le(q) * R) / (0.25 * L) > 0.9
START_RAW = F_remote_lt(q) * R >= 1.10 * 0.75 * L
```

STOP is immediate. START requires two consecutive valid windows. Confirmed
START wins when START and STOP overlap. A false or invalid START observation
resets its consecutive count.

The required kernel ABI under `/sys/kernel/mm/numa_balancing` is:

```text
fault_latency_quantiles
local_fault_rate
local_fault_scan_period_ms
local_fault_scan_size_mb
local_fault_window
remote_scan_cycles
migration_enabled
```

The quantile snapshot must report `quantile_snapshot_v3`, algorithm
`kll_weighted_ms_v1`, and value source `sketch_latency_ms_to_ns`. Missing or
incompatible ABI data must fail closed before a policy transition.

## GAPBS Rule

PR and BC must generate the graph in the measured command:

```text
pr -g 29 ...
bc -g 29 ...
```

Do not stage or read `.sg` or `.wsg` files. Record
`gapbs_graph_mode=generated`, `gapbs_graph_scale=29`, and
`graph_build_included=1` in result metadata.

## VM Topology

The standard performance topology is:

```text
HOST_CPUS=0-31
GUEST_CPUS=32
GUEST_NODE0_CPUS=0-31
FAST_HOST_NODE=0
SLOW_HOST_NODE=2
SLOW_MEMORY_MODE=host-cxl
NUMA_MEM_POLICY=bind
NUMA_PREALLOC=1
```

Guest node 0 is local DRAM and contains all guest CPUs. Guest node 1 is the
CPU-less remote tier backed by the host CXL node. Run workloads with
`numactl --cpunodebind=0`. Verify that HMAT creates separate guest memory tiers
and that the demotion path is `node 0 -> node 1`.

Use a fresh VM for each measured configuration. Do not mix VM and host-native
absolute runtimes in one comparison because their local-capacity mechanisms
differ.

## Minimum Metadata

Every result must record:

- kernel image and kernel release/build number;
- configuration and the three policy-state readbacks;
- VM image, CPU topology, memory sizes, and host NUMA backing nodes;
- HMAT latency/bandwidth and guest memory-tier nodelists;
- MGLRU, THP, swap, normal scan, and local scan settings;
- exact workload command and generated graph metadata;
- workload PID and local/remote residency;
- elapsed workload time and return code;
- promotion, demotion, and migration counter deltas;
- controller CSV and raw quantile snapshots for `ours`.

The final cleanup and TPP availability record is in
`docs/final-controller-kernel-cleanup-20260711.md` and
`docs/tpp-baseline-feasibility-20260711.md`.
