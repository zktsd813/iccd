# ICCD Ours Scripts

The active script set is intentionally small. Do not add per-experiment
`run_*.sh` files under `experiments/`; use these scripts with environment
variables instead.

`VM/` is a git submodule that provides the reusable VM lifecycle harness
(`vmctl.sh`). Initialize it before using host-side VM actions:

```bash
git submodule update --init VM
```

Before running current ICCD experiments, read:

```text
docs/iccd-experiment-protocol-20260601.md
```

Current performance runs should use `SLOW_MEMORY_MODE=host-cxl`, which binds the
guest slow node to the real host CXL NUMA node and exposes HMAT metadata. The
`qemu-cxl` mode is for CXL Type3 topology/driver validation, not throughput or
latency measurements.

## Files

- `run_ours_experiment.sh`: one workload execution wrapper. Current ICCD
  global experiments should rely on global NUMA/demotion/local-fault knobs, not
  memcg NUMA controls.
- `local_util_adapt_controller.py`: userspace controller for `ours`. It reads
  local-fault stats and toggles global NUMA balancing when the configured local
  access condition is met.
- `run_workload_case_guest.sh`: workload command implementations and RSS60
  profiles for real-world cases.
- `run_workload_suite_guest.sh`: reusable guest-side orchestrator for matrix or
  calibration runs. Configure with `WORKLOADS`, `POLICIES`, `CAPS`, `OUTROOT`,
  and `MODE`.
- `stage_workloads_to_vm.sh`: host-side staging helper. It copies the active
  scripts and selected workload payloads into a live VM. With `VM_ACTION` set,
  it also calls `VM/vmctl.sh` from the submodule for boot, wait, verify, run,
  and stop operations.

## Examples

Boot an 8G/160G PR smoke VM through the `VM` submodule, stage PR, run `off` and
`ours`, and print the guest summary:

```bash
VM_ACTION=pr-smoke WORKLOADS=pr PORT=10084 \
KERNEL=/path/to/bzImage \
INITRD=/path/to/initramfs.img \
ROOTFS=/path/to/ubuntu.img \
SSH_KEY=/path/to/id_rsa \
BENCHMARK_DIR=/Serverless/benchmark \
./scripts/stage_workloads_to_vm.sh
```

Stage scalable RSS60 workloads:

```bash
PORT=10064 WORKLOADS=scalable ./stage_workloads_to_vm.sh
```

Stage only GAPBS PR into a live VM:

```bash
PORT=10084 SSH_KEY=/path/to/id_rsa WORKLOADS=pr \
BENCHMARK_DIR=/Serverless/benchmark ./stage_workloads_to_vm.sh
```

Run one matrix inside the guest:

```bash
OUTROOT=/root/rss60-8g WORKLOADS=scalable POLICIES="off on ours" \
CAPS=physical:0 MODE=matrix /root/scripts/run_workload_suite_guest.sh
```

Run a short PR smoke matrix inside the guest:

```bash
OUTROOT=/root/script-smoke-pr WORKLOADS=pr POLICIES="off ours" \
CAPS=physical:0 MODE=matrix PR_ITERATIONS=1 PR_TRIALS=1 \
TIMEOUT_SEC=1200 OMP_THREADS=32 WINDOW_SEC=2 MIN_ARM_WINDOWS=1 \
MAX_ARM_WINDOWS=2 OBSERVE_WINDOWS=1 \
/root/scripts/run_workload_suite_guest.sh
```

Calibrate RSS:

```bash
OUTROOT=/root/rss60-cal WORKLOADS=scalable MODE=calibrate \
/root/scripts/run_workload_suite_guest.sh
```
