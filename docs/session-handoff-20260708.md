# Session Handoff - 2026-07-08

## Current Goal

Run only VM-based 16G local-memory experiments for `silo` and `liblinear`, after rebooting the host to clear physical host-side limitations. The controller must keep quantile/window information after the first migration stop: migration stops, but sampling/window logging continues.

Do not use host-native benchmark results for this next step. The host-side VM launcher is only orchestration for guest VM runs.

## Current Machine State Before Reboot

- No active QEMU VM was found after cleanup.
- The interrupted VM run tmux sessions were killed.
- Host SMT was observed as `off`, and online CPUs were `0-31`.
- A reboot was requested by the user to clear physical hardware limitations before rerunning VM experiments.
- The actual `sudo -n reboot` command was not executed because the user redirected to this handoff documentation.

## Important Code Changes Made

### Controller behavior

Relevant files:

- `design/fault_bucket_controller/bucket_latency_controller.py`
- `design/fault_bucket_controller/run_guest.sh`
- `design/fault_bucket_controller/test_bucket_latency_controller.py`
- `design/fault_bucket_controller/DESIGN.md`

Changes:

- Removed `remote_low_sample` as a stop reason.
  - The controller should not stop just because remote samples drop below the minimum.
  - Low remote sample now falls through to the invalid/skip path.
- Added `--monitor-after-stop`.
  - With `--initial-stop-only`, the controller no longer exits immediately after first stop when `--monitor-after-stop` is set.
  - After first stop, it keeps advancing windows and logging quantile snapshots.
  - Restart logic is not used in this monitoring mode.
- Stop action remains `observe`.
  - On stop, `migration_enabled=0`.
  - `numa_balancing` stays in observation mode.
  - Local sampling remains enabled.
- Default local fault sampling for experiments remains:
  - `LOCAL_FAULT_SCAN_SIZE_MB=64`
  - `LOCAL_FAULT_SCAN_PERIOD_MS=1000`

Validation already run:

```bash
python3 -m unittest test_bucket_latency_controller.py
python3 -m py_compile design/fault_bucket_controller/bucket_latency_controller.py design/fault_bucket_controller/plot_controller.py
bash -n design/fault_bucket_controller/run_guest.sh motivation/3_realworld/VM/scripts/run_workload_case_guest.sh motivation/3_realworld/VM/scripts/run_vm_sweep_host.sh motivation/3_realworld/VM/scripts/run_vm_sweep_guest.sh motivation/3_realworld/VM/scripts/run_vm_sweep_tmux.sh motivation/3_realworld/VM/scripts/run_vm_controller_tmux.sh
```

Observed result:

- Unit tests passed: 22 tests.
- Python compile passed.
- Shell syntax checks passed.

### VM and host controller unification

Relevant files:

- `motivation/3_realworld/VM/scripts/run_workload_case_guest.sh`
- `motivation/3_realworld/VM/scripts/run_vm_sweep_host.sh`
- `motivation/3_realworld/VM/scripts/run_vm_sweep_guest.sh`
- `motivation/3_realworld/VM/scripts/run_vm_sweep_tmux.sh`
- `motivation/3_realworld/VM/scripts/run_vm_controller_tmux.sh`
- `submission/eval_1_realworld/host_native/run_host_native_migration_sweep.sh`
- `submission/eval_1_realworld/host_native/start_quantile_after_reboot.sh`

Changes:

- VM and host paths both use the shared controller runner:
  - `design/fault_bucket_controller/run_guest.sh`
  - staged inside VM as `/root/design/fault_bucket_controller/run_guest.sh`
- VM scripts now propagate:
  - `CONTROLLER_MONITOR_AFTER_STOP`
  - `CONTROLLER_INITIAL_STOP_ONLY`
  - `CONTROLLER_STOP_FAULT_SAMPLING_ON_STOP`
  - `CONTROLLER_STOP_ACTION`
  - `CONTROLLER_MIGRATION_ENABLED_PATH`
- Host-native scripts were also wired to the same runner/settings, but the next requested run is VM-only.

### VM launcher hardware-limit defaults changed

Relevant file:

- `motivation/3_realworld/VM/scripts/run_vm_sweep_host.sh`
- `motivation/3_realworld/VM/scripts/run_vm_sweep_tmux.sh`

Changes made after the user pointed out host-side limitations:

- `FORBID_HOST_NODE1` default changed from `1` to `0`.
- `DISABLE_SMT` default changed from `1` to `0`.
- `RESTORE_SMT` default changed from `1` to `0`.
- `REBOOT_AFTER_STAGE` default changed from `1` to `0`.

Reason:

- The next experiment should run after a host reboot with physical host constraints cleared.
- The VM launcher should not disable SMT or enforce host-node restrictions again.
- Stage-time guest reboot was unnecessary and caused extra risk because QEMU stop was not always immediate.

### QEMU stop guard added

Relevant file:

- `motivation/3_realworld/VM/scripts/run_vm_sweep_host.sh`

Problem observed:

- `vmctl stop` returned while the old QEMU process was still alive.
- The launcher then started the next config VM.
- This caused overlap between old and new QEMU processes and possible benchmark interference.

Fix added:

- `qemu_active_pids_for_name`
- `wait_qemu_stopped`
- `force_stop_qemu_name`

New behavior:

- After stopping a VM, the launcher waits for the QEMU process with that VM name to disappear.
- If QEMU remains active, it sends TERM/KILL as needed.
- If the VM still cannot be stopped, it refuses to start the next config.

## Skill Update

The `iccd-experiments` skill was updated earlier in this session at:

```text
/home/ijkim/.codex/skills/iccd-experiments/SKILL.md
```

Added rules:

- VM and host ours-quantile controller runs must use the shared runner from `design/fault_bucket_controller/run_guest.sh`.
- Default ours controller mode:
  - `STOP_ACTION=observe`
  - `INITIAL_STOP_ONLY=1`
  - `MONITOR_AFTER_STOP=1`
  - `STOP_FAULT_SAMPLING_ON_STOP=0`
- After first stop, migration is disabled while NUMA scanning and quantile/window logging continue.

## Interrupted Runs To Discard

Do not use these result directories for final analysis:

```text
motivation/3_realworld/VM/results/20260708T013522Z-vm-local16-silo-liblinear-monitor-after-stop
motivation/3_realworld/VM/results/20260708T021323Z-vm-local16-silo-liblinear-monitor-after-stop-cleanvm
```

Reason:

- `20260708T013522Z...` had VM overlap: the `off` VM remained active while the `on` VM started.
- `20260708T021323Z...` used the new QEMU stop guard, but still included the stage-time guest reboot path before `REBOOT_AFTER_STAGE=0` was set as the default.
- Both were interrupted before completing all required VM 16G cases.

Partial numbers observed, for debugging only:

```text
20260708T013522Z:
  off/silo      929 s
  off/liblinear 466 s

20260708T021323Z:
  off/silo      1279 s
  off/liblinear 383 s
```

Do not compare these against final on/ours results.

## Next Run After Reboot

After host reboot, first verify:

```bash
cat /sys/devices/system/cpu/smt/control
cat /sys/devices/system/cpu/online
pgrep -af qemu-system-x86_64
tmux ls
```

Expected:

- SMT should not be forced off by our scripts.
- No stale QEMU from the interrupted runs.

Then run VM-only 16G:

```bash
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-vm-local16-silo-liblinear-monitor-after-stop-noreboot" \
LOCAL_SIZES_GIB="16" \
CONFIGS="off on ours_t075 ours_t100" \
WORKLOADS="silo liblinear" \
REBOOT_AFTER_STAGE=0 \
DISABLE_SMT=0 \
RESTORE_SMT=0 \
FORBID_HOST_NODE1=0 \
DISABLE_SWAP=1 \
NUMA_SCAN_SIZE_MB=256 \
NUMA_SCAN_PERIOD_MIN_MS=1000 \
LOCAL_FAULT_SCAN_SIZE_MB=64 \
LOCAL_FAULT_SCAN_PERIOD_MS=1000 \
CONTROLLER_MONITOR_AFTER_STOP=1 \
CONTROLLER_INITIAL_STOP_ONLY=1 \
CONTROLLER_STOP_FAULT_SAMPLING_ON_STOP=0 \
CONTROLLER_STOP_ACTION=observe \
CONTROLLER_LOCAL_FAULT_SCAN_SIZE_MB=64 \
CONTROLLER_LOCAL_FAULT_SCAN_PERIOD_MS=1000 \
CONTROLLER_BASELINE_SKIP_WINDOWS=0 \
CONTROLLER_EWMA_ALPHA=1.0 \
CONTROLLER_CONSECUTIVE_NO_IMPROVE=2 \
STOP_VM_WAIT_SEC=120 \
STOP_VM_ON_SUCCESS=1 \
STOP_VM_ON_FAILURE=1 \
STOP_VM_ON_EXIT=1 \
RESUME=1 \
CLEAN_SCRIPTS=1 \
STAGE_WORKLOADS=1 \
motivation/3_realworld/VM/scripts/run_vm_sweep_host.sh
```

Notes:

- This is still a VM run. The script name contains `host` because it launches and manages QEMU from the host side.
- The workloads execute inside the guest VM.
- Keep checking that there is only one active non-zombie QEMU process at a time.
- For ours configs, validate controller CSV after completion:
  - exactly one first stop event if the policy stops,
  - post-stop `sample` rows continue,
  - quantile files continue after stop,
  - `controller_monitor_after_stop=1`,
  - no `remote_low_sample` stop reason.

## Current Open Question

After reboot, decide whether to use the default host CPU range `0-31` or explicitly expand host/guest CPU allocation now that physical limitations are cleared. The current scripts still default to:

```text
HOST_CPUS=0-31
GUEST_CPUS=32
GUEST_NODE0_CPUS=0-31
```

If the goal is to use all available physical CPUs, update `scripts/iccd_experiment_defaults.sh` or pass explicit `HOST_CPUS`, `GUEST_CPUS`, and `GUEST_NODE0_CPUS` for the next VM run.
