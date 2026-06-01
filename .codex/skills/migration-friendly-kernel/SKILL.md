---
name: migration-friendly-kernel
description: Use when working on ICCD / Migration-friendly Linux kernel experiments, global NUMA balancing, memory tiering, demotion/promotion, QEMU or VM validation, workload staging, or microbenchmark runs for this ICCD repository checkout.
---

# Migration-Friendly Kernel

## Canonical workspace

- This repo-local copy is the source of truth for the skill. On another
  machine, install it by copying or symlinking
  `.codex/skills/migration-friendly-kernel` into `$CODEX_HOME/skills/`.
- In this checkout, `/Serverless/iccd-git` is the canonical repo root. If the
  repository is cloned elsewhere, substitute that checkout root for
  `/Serverless/iccd-git` in the paths below.
- Use `/Serverless/iccd-git` as the canonical ICCD git checkout for commits, pushes, docs, and root workload scripts.
- Treat the current working directory `/Serverless/iccd-git` as the repo root when running repo-relative commands.
- Read `/Serverless/iccd-git/docs/session-handoff-20260601.md` when resuming a session or when repo/submodule state matters.
- Use `/Serverless/iccd-git/VM` as the `linux-kernel-vm` submodule. Keep workload scripts in `/Serverless/iccd-git/scripts`, not in the VM submodule.
- Use `/Serverless/iccd-git/linux` as the active kernel source tree for implementation unless the user explicitly requests another tree.
- Use `/Serverless/iccd-git/linux-global-build` as the active out-of-tree kernel build directory unless the user explicitly requests another build directory.
- Use `/Serverless/iccd-git/linux-global-build/arch/x86/boot/bzImage` as the experiment kernel image.
- Do not use `/Serverless/iccd` for current work.
- Treat `/Serverless/Migration-friendly/linux` as an upstream/reference tree only. Do not patch it, build it, or boot it for current ICCD experiments unless the user explicitly asks.
- Before running or interpreting any experiment, read `/Serverless/iccd-git/docs/iccd-experiment-protocol-20260601.md`. This is the current VM topology, host-CXL, HMAT, and kernel-runtime source of truth.
- Use `/Serverless/iccd-git/PROJECT_OVERVIEW.md` for a high-level map of the repo and references.
- Read `/Serverless/iccd-git/docs/current-migration-workloads-20260507.md` only when selecting or interpreting the current workload candidates; it is not a mandatory pre-read for every experiment.

## Required pre-experiment summary

- Use `/Serverless/iccd-git` only; do not use `/Serverless/iccd`.
- Do not use cgroup or memcg NUMA controls for the current baseline.
- Boot `/Serverless/iccd-git/linux-global-build/arch/x86/boot/bzImage` with `/Serverless/iccd-git/VM/vmctl.sh`.
- Use `SLOW_MEMORY_MODE=host-cxl` for performance experiments and verify guest memory tiers split node0/node1.
- Bind guest node0 memory to host node0 and guest node1 memory to host node2 with QEMU preallocation and host NUMA bind policy.
- Verify guest MGLRU is `0x0007`, global demotion is enabled, and `demotion_target` contains `0 1`.
- Use global NUMA balancing only: `2` for migration on, `0` for migration off.
- Use the repo-wide workload placement `numactl --cpunodebind=0`.
- For all-fast/all-slow controls, size the VM appropriately and use explicit `numactl --membind` for the control node.

## Experiment outputs

- Store each new experiment under `/Serverless/iccd-git/experiments/<experiment-name>/`.
- Use `/Serverless/iccd-git/experiments/<experiment-name>/qemu-logs/phase_candidate_microbench` as the host `OUTDIR` for that experiment's phase-candidate microbench/QEMU runs.
- Store derived summaries under `/Serverless/iccd-git/experiments/<experiment-name>/summaries` and plots/graphs under `/Serverless/iccd-git/experiments/<experiment-name>/graphs`.
- After generating any graph or figure, also copy it into `/Serverless/iccd-git/experiments/figure/` so the latest figures are easy to find. Keep the experiment-local copy as the source artifact and use a descriptive filename in `experiments/figure`.
- Keep notes or manual analysis snippets under `/Serverless/iccd-git/experiments/<experiment-name>/notes`.
- Use a short, descriptive, timestamped experiment name when practical, for example `20260507-mulshift4g-sparse64-phase`.
- Keep raw outputs, VM run directories, logs, and large generated result trees out of `/Serverless/iccd-git` unless the user explicitly asks to commit a summarized artifact.
- Put reusable host/guest workload changes in `/Serverless/iccd-git/scripts`; put paper/repo summaries in `/Serverless/iccd-git/docs`.

## Optional workload references

- Workload catalog: `/Serverless/iccd-git/docs/current-migration-workloads-20260507.md`.
- Read it when a task asks for workload selection, candidate interpretation, phase-pair details, or historical workload comparison.
- Do not treat it as a required pre-read for every kernel, VM, or PR run.

## Required experiment VM topology

- For migration-friendliness experiments, pin the VM CPUs to host NUMA node0 CPUs: `HOST_CPUS=0-31`, `CPUS=32`, and guest node0 CPUs `NUMA_NODE0_CPUS=0-31`.
- Bind guest NUMA node0 memory to host NUMA node0 DRAM: `NUMA_NODE0_HOST_NODES=0`. Treat this as the fast/local node.
- Bind guest NUMA node1 memory to host NUMA node2 CXL memory: `NUMA_NODE1_HOST_NODES=2`. Treat this as the slow/remote node.
- Use host NUMA memory policy `NUMA_MEM_POLICY=bind` and preallocate with `NUMA_PREALLOC=1` so QEMU memory backing is actually allocated from the intended host NUMA nodes.
- Use VM slow-memory mode `host-cxl` for performance experiments. This keeps guest node1 as KVM RAM backed by host NUMA node2 and exposes HMAT so the guest kernel separates node0/node1 memory tiers. Do not use QEMU Type3 `qemu-cxl`/`cxl` mode for performance results unless explicitly measuring QEMU CXL emulation overhead.
- Run workloads with the repo-wide default placement from `scripts/iccd_experiment_defaults.sh`: `ICCD_WORKLOAD_CPU_NODE=0`, or `numactl --cpunodebind=0`.
- Do not force a NUMA hot threshold unless an experiment explicitly asks for it. Use the kernel default hot threshold.
- Use the default NUMA scan size `NUMA_SCAN_SIZE_MB=4096` unless an experiment explicitly asks for a different scan size.
- Use the default NUMA scan period minimum `NUMA_SCAN_PERIOD_MIN_MS=1000` unless an experiment explicitly asks for a different scan cadence. Do not use old `SCAN_PERIOD_SCALE` reasoning for current runs.
- For workload candidate-specific placement, phase-pair, or first-touch rules, consult `/Serverless/iccd-git/docs/current-migration-workloads-20260507.md` only when needed.
- Results without these host bindings are not valid for local-vs-CXL interpretation, even if guest NUMA placement appears correct.

## Required VM Memory-Management State

- MGLRU means the guest kernel Multi-Gen LRU runtime state, not the PF_KSWAPD diagnostic path. Do not conflate these.
- Current experiments must run with MGLRU enabled in the guest. Verify `/sys/kernel/mm/lru_gen/enabled` before interpreting a result; the expected value is `0x0007`.
- If `/sys/kernel/mm/lru_gen/enabled` exists but is not `0x0007`, enable it in the guest before running the workload with `echo 0x0007 > /sys/kernel/mm/lru_gen/enabled`, then re-read the file.
- If the sysfs file is missing, stop and check the booted kernel/config before running the experiment; do not treat non-MGLRU results as current validation.
- Result summaries must include the MGLRU runtime value, for example `lru_gen_enabled=0x0007`.
- Use global NUMA balancing state for on/off experiments: `echo 2 > /proc/sys/kernel/numa_balancing` for migration on, and `echo 0 > /proc/sys/kernel/numa_balancing` for migration off.
- Use global demotion state when needed: `/sys/kernel/mm/numa/demotion_enabled` and `/sys/kernel/mm/numa/demotion_target`.

## GAPBS graph input rule

- For GAPBS PR/BC experiments, do not use `-g<scale>` inside the measured run path unless the user explicitly asks to measure graph generation/building.
- Prebuild the synthetic graph once with GAPBS `converter`, then run PR/BC with `-f <serialized-graph.sg>` so each policy/period run loads the same graph instead of regenerating and rebuilding it.
- For the current GAPBS `-g28` experiments, the canonical host cache is `/Serverless/benchmark/gapbs/benchmark/graphs/kron_g28.sg`.
- Inside the guest, use or create `/root/gapbs_graphs/kron_g28.sg`, then execute PR/BC with `-f /root/gapbs_graphs/kron_g28.sg`.
- Use this prebuild command shape when the cache is missing: `cd /Serverless/benchmark/gapbs && env OMP_NUM_THREADS=32 OMP_PROC_BIND=true OMP_PLACES=cores ./converter -g28 -b benchmark/graphs/kron_g28.sg`.
- Summaries for GAPBS experiments must state whether `-f` was used, the serialized graph path, and whether graph build time was excluded from the measured policy run. If validating the cache, report `Read Time`; do not mix `Generate Time`/`Build Time` into PR/BC trial averages.

## Common commands

- Kernel builds must use all available CPUs: pass `-j$(nproc)` for any direct kernel build, including `bzImage`, `modules`, and combined build targets.
- Kernel build: `make -C /Serverless/iccd-git/linux O=/Serverless/iccd-git/linux-global-build -j$(nproc) bzImage`
- Kernel + modules build: `make -C /Serverless/iccd-git/linux O=/Serverless/iccd-git/linux-global-build -j$(nproc) bzImage modules`
- When using scripts that rebuild initramfs/modules, keep their build parallelism at `$(nproc)`; for `launch_kernel_qemu.sh --build-initrd`, use the default or set `BUILD_JOBS=$(nproc)`.
- Current ICCD workload staging entrypoint: `/Serverless/iccd-git/scripts/stage_workloads_to_vm.sh`
- Current VM lifecycle helper: `/Serverless/iccd-git/VM/vmctl.sh`
- If `/Serverless/iccd-git/VM/vmctl.sh` is missing, run `git submodule update --init VM` from `/Serverless/iccd-git`.
- Legacy phase microbench QEMU launcher: `/Serverless/Migration-friendly/scripts/kernel/launch_kernel_qemu.sh`
- Default kernel image: `/Serverless/iccd-git/linux-global-build/arch/x86/boot/bzImage`
- Default QEMU tree: `/Serverless/Migration-friendly/qemu`
- Phase microbench output override: `EXP_NAME=<experiment-name>; mkdir -p /Serverless/iccd-git/experiments/${EXP_NAME}/{qemu-logs/phase_candidate_microbench,summaries,graphs,notes}; OUTDIR=/Serverless/iccd-git/experiments/${EXP_NAME}/qemu-logs/phase_candidate_microbench /Serverless/Migration-friendly/scripts/kernel/run_qemu_phase_candidate_microbench.sh`
- Required VM binding variables for phase experiments: `HOST_CPUS=0-31 GUEST_CPUS=32 GUEST_NODE0_CPUS=0-31 FAST_HOST_NODE=0 SLOW_HOST_NODE=2 SLOW_MEMORY_MODE=host-cxl NUMA_MEM_POLICY=bind NUMA_PREALLOC=1 NUMA_SCAN_SIZE_MB=4096 NUMA_SCAN_PERIOD_MIN_MS=1000`.
- Read `/Serverless/iccd-git/docs/current-migration-workloads-20260507.md` only when workload candidate details are needed.
- After every experiment, include the kernel image, initrd image, KVM status, VM CPU/memory/node binding, global NUMA/demotion knobs, scan tuning, workload, on/off throughput, promoted pages/GiB, and demoted pages/GiB in the result summary. Report demotion as `pgdemote_direct + pgdemote_kswapd` when both counters are available.

## Git discipline

- When committing ICCD project changes, run git commands from `/Serverless/iccd-git`.
- Keep `/Serverless/iccd-git/VM` as a submodule. `git ls-tree HEAD VM` should show mode `160000`, not `040000 tree`.
- Do not push ICCD workload scripts to `linux-kernel-vm`; root workload scripts belong under `/Serverless/iccd-git/scripts`.
- Stage only files relevant to the requested change; this repository often has unrelated untracked experiment outputs.
- Do not commit build artifacts, QEMU images, serial logs, benchmark output directories, or unrelated dirty files unless the user explicitly requests it.
