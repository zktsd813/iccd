# Post-Reboot VM Local16 Silo/Liblinear Plan - 2026-07-08

This run is VM-only. The host command below launches and manages QEMU; the
workloads execute inside the guest through:

```text
/root/vm32_realworld/scripts/run_vm_sweep_guest.sh
/root/vm32_realworld/scripts/run_workload_case_guest.sh
```

Do not use host-native benchmark scripts for this run.

## Purpose

- VM local memory: 16 GiB fast node0, 128 GiB slow node1.
- Workloads: `silo`, `liblinear`.
- Controller policy: shared runner from `design/fault_bucket_controller/run_guest.sh`.
- Controller input: quantile.
- SMT: off for the run.
- Migration-disabled histogram overhead: compare `observe_off` against `off`.

## Config Meaning

- `off`: `numa_balancing=0`, `migration_enabled=0`, `demotion_enabled=false`.
- `observe_off`: `numa_balancing=2`, `migration_enabled=0`,
  `demotion_enabled=false`; local fault histogram sampling is enabled by
  `LOCAL_FAULT_RATE=5`.
- `on`: `numa_balancing=2`, `migration_enabled=1`, normal migration enabled.
- `ours_t075` / `ours_t100`: controller uses `STOP_ACTION=observe`; after the
  first stop it writes `migration_enabled=0` while keeping scan/window logging
  active.

## Post-Reboot Checks

```bash
cat /sys/devices/system/cpu/smt/control
cat /sys/devices/system/cpu/online
pgrep -af qemu-system-x86_64 || true
tmux ls || true
```

## Run Command

```bash
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-vm-local16-silo-liblinear-quantile-observe-off" \
LOCAL_SIZES_GIB="16" \
CONFIGS="off observe_off on ours_t075 ours_t100" \
WORKLOADS="silo liblinear" \
DISABLE_SMT=1 \
RESTORE_SMT=0 \
REBOOT_AFTER_STAGE=0 \
DISABLE_SWAP=1 \
FORBID_HOST_NODE1=0 \
NUMA_SCAN_SIZE_MB=256 \
NUMA_SCAN_PERIOD_MIN_MS=1000 \
LOCAL_FAULT_RATE=5 \
LOCAL_FAULT_SCAN_SIZE_MB=64 \
LOCAL_FAULT_SCAN_PERIOD_MS=1000 \
CONTROLLER_INPUT_MODE=quantile \
CONTROLLER_LOCAL_RATE=5 \
CONTROLLER_LOCAL_FAULT_SCAN_SIZE_MB=64 \
CONTROLLER_LOCAL_FAULT_SCAN_PERIOD_MS=1000 \
CONTROLLER_BASELINE_SKIP_WINDOWS=0 \
CONTROLLER_EWMA_ALPHA=1.0 \
CONTROLLER_CONSECUTIVE_NO_IMPROVE=2 \
CONTROLLER_INITIAL_STOP_ONLY=1 \
CONTROLLER_MONITOR_AFTER_STOP=1 \
CONTROLLER_STOP_FAULT_SAMPLING_ON_STOP=0 \
CONTROLLER_STOP_ACTION=observe \
CONTROLLER_MIGRATION_ENABLED_PATH=/sys/kernel/mm/numa_balancing/migration_enabled \
STOP_VM_WAIT_SEC=120 \
STOP_VM_ON_SUCCESS=1 \
STOP_VM_ON_FAILURE=1 \
STOP_VM_ON_EXIT=1 \
RESUME=1 \
CLEAN_SCRIPTS=1 \
STAGE_WORKLOADS=1 \
motivation/3_realworld/VM/scripts/run_vm_sweep_host.sh
```
