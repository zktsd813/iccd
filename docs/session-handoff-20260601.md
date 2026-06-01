# Session Handoff - 2026-06-01

This note is the handoff point for starting a fresh session after the ICCD repo,
VM harness, and workload scripts were cleaned up.

## Current Git State

Use `/Serverless/iccd-git` for all current ICCD work: git operations, kernel
source, build outputs, workload scripts, and new experiment outputs. The older
`/Serverless/iccd` directory is deprecated for this workflow and should not be
used as a source of truth.

Current pushed ICCD repo:

```text
repo:   git@github.com:zktsd813/iccd.git
branch: main
HEAD:   4816bc2d01a5825e8d2aedbe849764ef77dfe67a
commit: Use VM harness as submodule
```

`VM/` is now a git submodule, not a normal directory:

```text
submodule path: VM
submodule repo: git@github.com:zktsd813/linux-kernel-vm.git
submodule sha:  55ff4c1afbd99c57dab5e95fc1f6a937bae4b533
```

From a new machine:

```bash
git clone --recurse-submodules git@github.com:zktsd813/iccd.git
cd iccd
```

If the repo is already cloned:

```bash
git submodule update --init VM
```

## What Changed Today

1. A mistaken push was made to `linux-kernel-vm` with workload scripts in the VM
   repo:

   ```text
   6da3468560cd037b8199f1ba6083ac9373414cd9 Add ICCD workload runners
   ```

2. That push was reverted in `linux-kernel-vm`:

   ```text
   55ff4c1afbd99c57dab5e95fc1f6a937bae4b533 Revert "Add ICCD workload runners"
   ```

   This is the submodule commit currently pinned by `iccd`.

3. `iccd` was first updated with `VM/` as a normal directory:

   ```text
   8fa54e35e9843f404a094170cc67f69366f572db Consolidate ICCD VM workload runners
   ```

4. That was corrected by converting `VM/` into a submodule and keeping workload
   scripts in the root `scripts/` directory:

   ```text
   4816bc2d01a5825e8d2aedbe849764ef77dfe67a Use VM harness as submodule
   ```

## Current Directory Roles

`/Serverless/iccd-git`

- Clean git checkout of `zktsd813/iccd`.
- Use this for future commits and pushes.
- Contains `VM/` as a submodule.
- Contains the active kernel source under `linux/`.
- Contains the active out-of-tree kernel build under ignored directory
  `linux-global-build/`.

`/Serverless/iccd-git/linux`

- Active kernel source tree for current global NUMA experiments.
- Synchronized from the previous `linux_global` implementation on 2026-06-01.
- This is the current global NUMA baseline for implementation.

`/Serverless/iccd-git/linux-global-build`

- Active out-of-tree build directory for `linux/`.
- Ignored by git.
- Last validated kernel image:

  ```text
  /Serverless/iccd-git/linux-global-build/arch/x86/boot/bzImage
  ```

`/Serverless/iccd-git/VM`

- Submodule checkout of `linux-kernel-vm`.
- Provides `vmctl.sh` and VM lifecycle helpers.
- Does not own the workload scripts.

`/Serverless/iccd-git/scripts`

- Owns the current reusable workload scripts.
- Scripts are copied into the guest by `stage_workloads_to_vm.sh`.

## Required Experiment Protocol

Read this before running or interpreting any new ICCD experiment:

```text
docs/iccd-experiment-protocol-20260601.md
```

Current performance experiments should use `SLOW_MEMORY_MODE=host-cxl`: guest
node1 remains KVM RAM backed by host NUMA node2, and QEMU exposes HMAT metadata
so the guest kernel places node1 in a lower memory tier. Use `qemu-cxl` only for
CXL Type3 topology/driver validation because it can route memory access through
QEMU emulation callbacks.

## Active Script Set

Root `scripts/` should stay small:

```text
scripts/README.md
scripts/local_util_adapt_controller.py
scripts/run_ours_experiment.sh
scripts/run_workload_case_guest.sh
scripts/run_workload_suite_guest.sh
scripts/stage_workloads_to_vm.sh
```

Roles:

- `stage_workloads_to_vm.sh`: host-side entrypoint. It stages root scripts and
  selected workload payloads into a live VM. With `VM_ACTION`, it calls
  `VM/vmctl.sh` from the submodule for boot/wait/verify/run/stop.
- `run_workload_suite_guest.sh`: guest-side matrix/calibration orchestrator.
- `run_ours_experiment.sh`: one workload under `off`, `on`, or `ours`.
- `run_workload_case_guest.sh`: workload command/profile definitions.
- `local_util_adapt_controller.py`: userspace local-fault controller for `ours`.

Avoid adding one-off `run_*.sh` files under `experiments/`. Add workload
selection and parameters through environment variables instead.

## VM/Submodule Usage

Stage into an already running VM:

```bash
PORT=10084 SSH_KEY=/path/to/id_rsa WORKLOADS=pr \
BENCHMARK_DIR=/Serverless/benchmark \
./scripts/stage_workloads_to_vm.sh
```

If the VM submodule is initialized and there is no live VM on the target port,
set `VERIFY_PLACEMENT=0` for pure staging attempts:

```bash
VERIFY_PLACEMENT=0 PORT=10084 SSH_KEY=/path/to/id_rsa WORKLOADS=pr \
BENCHMARK_DIR=/Serverless/benchmark \
./scripts/stage_workloads_to_vm.sh
```

Boot, wait, verify, stage, run a short PR smoke, and print `summary.csv`:

```bash
VM_ACTION=pr-smoke WORKLOADS=pr PORT=10084 \
KERNEL=/path/to/bzImage \
INITRD=/path/to/initramfs.img \
ROOTFS=/path/to/ubuntu.img \
SSH_KEY=/path/to/id_rsa \
BENCHMARK_DIR=/Serverless/benchmark \
./scripts/stage_workloads_to_vm.sh
```

Useful `VM_ACTION` values:

```text
stage       default; stage scripts/workloads into an existing VM
boot-stage  boot via VM/vmctl.sh, wait/verify, then stage
pr-smoke    boot-stage plus guest PR off/ours smoke run
wait        call VM/vmctl.sh wait-ssh
verify      call VM/vmctl.sh verify-placement
stop        call VM/vmctl.sh stop
```

Important environment variables:

```text
PORT, HOST, SSH_KEY
KERNEL, INITRD, ROOTFS, ROOTFS_FORMAT
VM_NAME, QEMU_BIN
FAST_MEM, SLOW_MEM
FAST_HOST_NODE=0, SLOW_HOST_NODE=2
HOST_CPUS=0-31, GUEST_CPUS=32, GUEST_NODE0_CPUS=0-31
WORKLOADS, POLICIES, CAPS, OUTROOT
BENCHMARK_DIR=/Serverless/benchmark
```

For GAPBS PR/BC, keep using the prebuilt graph:

```text
host:  /Serverless/benchmark/gapbs/benchmark/graphs/kron_g28.sg
guest: /root/gapbs_graphs/kron_g28.sg
```

Measured PR/BC runs should use `-f /root/gapbs_graphs/kron_g28.sg`, not `-g28`.

## Recent Experiment Cleanup

Old pre-linux-global experiment directories were removed from the git-tracked
tree and summarized instead. See:

```text
docs/pre-linux-global-results-summary-20260601.md
docs/removed-pre-linux-global-experiments-20260601.txt
```

Historical outputs under `/Serverless/iccd/experiments` may still exist, but new
outputs should be written under `/Serverless/iccd-git/experiments`.

Historical post-cleanup output names included:

```text
20260530-linux-global-pr-onoff
20260530-linux-global-sysfs-vm
20260530-pr-alloc-placement
20260530-pr-on-cap8g-reserve
20260530-pr-range-placement
20260530-realworld-e2e-g29-local-sweep
20260531-candidate-localcap-matrix
20260531-cxl-disagg-workload-survey
20260531-hss32-split16-stream4k-vm-rerun
20260531-realworld-rss60-calibration
20260531-realworld-rss60-scalable-8g-long600
20260531-realworld-rss60-scalable-8g-onoff
20260601-existing-localcap-summary
20260601-pr-allfast-allslow-localcap
20260601-realworld-rss60-scalable-16g-long600
20260601-script-smoke-pr
```

Use `/Serverless/iccd-git/experiments` for raw outputs. Do not commit VM images,
logs, QEMU run directories, or large generated result trees unless explicitly
needed.

## Known Pitfalls

- Do not push workload scripts to `linux-kernel-vm`; it is the reusable VM
  harness submodule.
- Do not use `/Serverless/iccd` for current work. Use `/Serverless/iccd-git`
  for repo operations, kernel work, builds, scripts, and new experiment outputs.
- `VM/` in `iccd` must remain a submodule. `git ls-tree HEAD VM` should show
  mode `160000`, not `040000 tree`.
- If `VM/vmctl.sh` is missing after clone, run:

  ```bash
  git submodule update --init VM
  ```

- The canonical VM harness relation in the pushed `iccd` repo is the `VM`
  submodule under `/Serverless/iccd-git/VM`.

## Validation Already Done

After the latest submodule conversion:

```bash
bash -n scripts/*.sh
python3 -m py_compile scripts/local_util_adapt_controller.py
git diff --cached --check
```

After copying the current global kernel implementation into this repo:

```bash
make -C /Serverless/iccd-git/linux O=/Serverless/iccd-git/linux-global-build -j$(nproc) bzImage
```

The build completed successfully and produced:

```text
/Serverless/iccd-git/linux-global-build/arch/x86/boot/bzImage
```

No QEMU or workload process was left running after the push.

## Recommended First Steps In The Next Session

1. Start from the real repo checkout:

   ```bash
   cd /Serverless/iccd-git
   git status --short --branch
   git submodule status
   ```

2. If using a fresh machine:

   ```bash
   git clone --recurse-submodules git@github.com:zktsd813/iccd.git
   cd iccd
   ```

3. Re-read workload context before interpreting experiments:

   ```text
   docs/current-migration-workloads-20260507.md
   docs/pre-linux-global-results-summary-20260601.md
   ```

4. For a quick script sanity check, use `VM_ACTION=pr-smoke` with local kernel,
   initrd, rootfs, SSH key, and benchmark paths.
