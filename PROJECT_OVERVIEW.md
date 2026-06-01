# ICCD Project Overview

This file is the top-level map for the current ICCD checkout.

## Mandatory Pre-Read

Read these before running or interpreting experiments:

1. `docs/session-handoff-20260601.md`
   - Defines the current repo and submodule state.
   - Establishes `/Serverless/iccd-git` as the only source of truth for current
     work.
   - Records that `VM/` is the `linux-kernel-vm` submodule.
   - Keeps workload scripts in the root repo under `scripts/`.
   - Directs new experiment outputs to `/Serverless/iccd-git/experiments/`.

2. `docs/iccd-experiment-protocol-20260601.md`
   - Defines the current VM topology, host-CXL mode, HMAT metadata, kernel
     image, build directory, and runtime kernel knobs.
   - Excludes cgroup and memcg NUMA controls from the current baseline.
   - Sets the common experiment placement and result metadata rules.

## Optional References

Read these only when the task needs the extra detail:

- `docs/current-migration-workloads-20260507.md`
  - Current workload catalog.
  - Friendly/unfriendly candidate descriptions.
  - Phase-pair notes and historical workload pitfalls.

- `docs/pre-linux-global-results-summary-20260601.md`
  - Historical pre-linux-global result summary.

- `docs/removed-pre-linux-global-experiments-20260601.txt`
  - Historical output directory list that was removed from the tracked tree.

## Canonical Workspace

- Repo root: `/Serverless/iccd-git`
- Kernel source: `/Serverless/iccd-git/linux`
- Kernel build: `/Serverless/iccd-git/linux-global-build`
- Kernel image: `/Serverless/iccd-git/linux-global-build/arch/x86/boot/bzImage`
- VM helper: `/Serverless/iccd-git/VM/vmctl.sh`
- Shared defaults: `/Serverless/iccd-git/scripts/iccd_experiment_defaults.sh`
- Workload scripts: `/Serverless/iccd-git/scripts`
- Experiment outputs: `/Serverless/iccd-git/experiments/<name>/`

Do not use `/Serverless/iccd` for current work.

## VM Baseline

Use this topology unless a specific experiment says otherwise:

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

- Guest node0 is fast/local memory backed by host node0.
- Guest node1 is slow memory backed by host node2, the host CXL NUMA node.
- `host-cxl` keeps guest node1 as KVM RAM and exposes HMAT metadata so the
  guest kernel separates the memory tiers.
- `qemu-cxl` is for CXL Type3 topology and driver validation, not performance
  measurements.

## Runtime Baseline

Use global kernel controls:

```text
MGLRU_ENABLED=0x0007
DEMOTION_ENABLED=true
DEMOTION_TARGET="0 1"
NUMA_BALANCING_ON=2
NUMA_BALANCING_OFF=0
NUMA_SCAN_SIZE_MB=4096
NUMA_SCAN_PERIOD_MIN_MS=1000
```

Before interpreting a result, verify:

- guest memory tiers split node0 and node1
- MGLRU is `0x0007`
- demotion is enabled
- demotion target contains `0 1`
- NUMA balancing has the expected global value

## Workload Placement

The repo-wide default workload placement is CPU binding to guest node0:

```text
numactl --cpunodebind=0
```

The default is encoded in `scripts/iccd_experiment_defaults.sh`:

```text
ICCD_WORKLOAD_CPU_NODE=0
```

Control experiments may add explicit memory binding when the experiment requires
all-fast or all-slow placement.

## Result Summaries

Each experiment summary should record:

- kernel image and guest `uname -a`
- rootfs or overlay path
- VM CPU and memory topology
- host NUMA backing nodes
- slow memory mode and HMAT metadata
- guest memory tier nodelists
- MGLRU, global NUMA balancing, and demotion settings
- scan size and scan period
- workload command and placement
- promoted/demoted pages, hint faults, and PTE updates when available

## Git Discipline

- Commit from `/Serverless/iccd-git`.
- Keep `VM/` as a submodule.
- Keep workload scripts in the root repo, not in `VM/`.
- Do not commit kernel build outputs, VM images, serial logs, raw QEMU run
  directories, or large experiment result trees unless explicitly requested.
