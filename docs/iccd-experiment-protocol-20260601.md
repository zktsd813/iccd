# ICCD Experiment Protocol - 2026-06-01

This document is the required pre-read before running or interpreting current
ICCD experiments in `/Serverless/iccd-git`.

## Source Of Truth

- Repo root: `/Serverless/iccd-git`
- Kernel source: `/Serverless/iccd-git/linux`
- Kernel build: `/Serverless/iccd-git/linux-global-build`
- Kernel image: `/Serverless/iccd-git/linux-global-build/arch/x86/boot/bzImage`
- VM helper: `/Serverless/iccd-git/VM/vmctl.sh`
- Shared defaults: `/Serverless/iccd-git/scripts/iccd_experiment_defaults.sh`

Do not use `/Serverless/iccd` for current work. Do not use cgroup or memcg NUMA
controls as part of the current implementation or experiment baseline.

## VM Topology

Use this topology unless an experiment explicitly states otherwise:

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

Interpretation:

- Guest node0 is the fast/local DRAM node.
- Guest node0 memory is backed by host NUMA node0.
- Guest node1 is the slow memory node.
- Guest node1 memory is backed by host NUMA node2, which is the real host CXL
  memory node on the current machine.
- QEMU must preallocate and bind memory so backing pages are actually allocated
  from the intended host NUMA nodes.

For PR `-g29` local-memory experiments:

```text
LOCAL16_FAST_MEM=16G
LOCAL16_SLOW_MEM=176G
```

For all-fast PR `-g29`, use enough fast memory for the graph and bind the VM's
fast memory to host DRAM:

```text
ALLFAST_FAST_MEM=160G
ALLFAST_SLOW_MEM=4G
ALLFAST_HOST_NODE=0-1
```

## Slow Memory Modes

Use `host-cxl` for performance experiments.

```text
--slow-memory-mode host-cxl
```

This mode keeps guest node1 as normal KVM RAM backed by host NUMA node2, then
adds ACPI HMAT metadata so the guest kernel classifies node1 as a lower memory
tier. It does not inject latency and does not route guest load/store traffic
through QEMU CXL MMIO emulation.

The default HMAT metadata is:

```text
HMAT_FAST_LATENCY_NS=80
HMAT_SLOW_LATENCY_NS=250
HMAT_FAST_BANDWIDTH=40000M
HMAT_SLOW_BANDWIDTH=10000M
```

Use `qemu-cxl` only for CXL topology, driver, and enumeration validation:

```text
--slow-memory-mode qemu-cxl
```

`qemu-cxl` creates a QEMU CXL Type3 volatile memory device. The CXL Fixed Memory
Window uses QEMU `MemoryRegionOps` callbacks, so it can add large emulation
overhead to memory access. Do not use it for performance results unless the
experiment is explicitly measuring QEMU CXL emulation behavior.

Legacy aliases:

- `hmat` is accepted as `host-cxl`.
- `cxl` is accepted as `qemu-cxl`.
- `numa` is the old no-HMAT RAM NUMA mode and should not be used for current
  local-vs-CXL performance experiments.

## Guest Kernel Runtime Knobs

Use these kernel runtime settings unless the experiment explicitly overrides
them:

```text
MGLRU_ENABLED=0x0007
DEMOTION_ENABLED=true
DEMOTION_TARGET="0 1"
NUMA_BALANCING_ON=2
NUMA_BALANCING_OFF=0
NUMA_SCAN_SIZE_MB=4096
NUMA_SCAN_PERIOD_MIN_MS=1000
```

For on/off experiments:

- migration on: write `2` to `/proc/sys/kernel/numa_balancing`
- migration off: write `0` to `/proc/sys/kernel/numa_balancing`

Before interpreting results, verify:

```text
/sys/kernel/mm/lru_gen/enabled = 0x0007
/sys/kernel/mm/numa/demotion_enabled = true
/sys/kernel/mm/numa/demotion_target contains "0 1"
/sys/devices/virtual/memory_tiering/*/nodelist separates node0 and node1
```

Expected memory-tier result with `host-cxl`:

```text
memory_tier*/nodelist=0
memory_tier*/nodelist=1
```

The exact tier IDs can vary. The important condition is that node0 and node1 are
not in the same tier.

## Why This Is Required

Without HMAT, QEMU exposes both guest nodes as default DRAM. The guest kernel
then places node0 and node1 in the same memory tier, so memory-tiering-only NUMA
balancing can treat node1 as top-tier memory and skip top-tier page scans.

With `host-cxl`, node1 is still backed by real host CXL memory, but the guest
also sees enough HMAT metadata to build a proper demotion path:

```text
Node 0 -> Node 1
```

## Minimum Result Metadata

Every experiment summary should include:

- kernel image path
- rootfs/overlay path
- `SLOW_MEMORY_MODE`
- host CPU pinning
- guest CPU count and guest node0 CPU range
- fast/slow guest memory sizes
- fast/slow host NUMA backing nodes
- HMAT latency/bandwidth values
- guest memory tier nodelists
- MGLRU value
- global NUMA balancing value
- demotion enabled/target values
- NUMA scan size and scan period
- promoted and demoted page counters
