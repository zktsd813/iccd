# Eval 1 Host-Native Boot Targeting

This directory prepares host-native eval_1 runs without the VM.

The boot-target script writes a guarded GRUB drop-in that:

- keeps node 0 as the local DRAM node,
- keeps node 2 as the slow CXL memory node,
- reserves node 1 memory at boot with `memmap=...$...`,
- boots only node 0 CPUs with `maxcpus=32` on the current host,
- disables SMT with `nosmt`,
- onlines the kept CXL memory node after reboot,
- adjusts the amount of node 0 memory left usable until node 0 free memory
  reaches the requested target.

Default targets are intended to be run one at a time:

```bash
submission/eval_1_realworld/host_native/host_boot_target.sh plan --target-gib 16
submission/eval_1_realworld/host_native/host_boot_target.sh plan --target-gib 32
submission/eval_1_realworld/host_native/host_boot_target.sh plan --target-gib 48
```

Apply and reboot for a target:

```bash
sudo submission/eval_1_realworld/host_native/host_boot_target.sh apply \
  --target-gib 16 --apply --reboot
```

After reboot, verify:

```bash
sudo submission/eval_1_realworld/host_native/host_boot_target.sh verify --target-gib 16
```

`verify` and `converge` first try to bring `KEEP_MEMORY_NODES` online.  With
the defaults this means node 2 CXL memory.  The script sets
`/sys/devices/system/memory/auto_online_blocks` to `online` when possible,
uses `daxctl online-memory` for matching `system-ram` DAX devices when
`daxctl` is available, and then falls back to onlining node memory blocks
through sysfs.

Automatic convergence across reboots:

```bash
sudo submission/eval_1_realworld/host_native/host_boot_target.sh converge \
  --target-gib 16 --apply --reboot
```

`converge` installs an `@reboot` hook. If node 0 free memory is not within
`TARGET_TOLERANCE_GIB` of the target after reboot, it rewrites the GRUB drop-in
with a different node 0 online size and reboots again, up to `MAX_REBOOTS`.
The default `MAX_REBOOTS` is `4`.  A manually started `converge --reboot`
resets the reboot counter, applies the initial plan, and reboots before making
the first decision.  The reboot hook waits `VERIFY_DELAY_AFTER_REBOOT_SEC`
seconds, default `30`, then runs one PR warmup trial with migration enabled,
drops host caches, and only then verifies the target.  The default warmup is:

```bash
numactl --cpunodebind=0 env OMP_NUM_THREADS=32 OMP_PROC_BIND=true OMP_PLACES=cores \
  /Serverless/benchmark/gapbs/pr \
    -f /Serverless/benchmark/gapbs/benchmark/graphs/kron_g29.sg \
    -i 20 -t 1e-4 -n 1
```

When the target is reached, or when the reboot limit is hit, it removes the
reboot hook.

Restore normal GRUB boot arguments:

```bash
sudo submission/eval_1_realworld/host_native/host_boot_target.sh restore --apply --reboot
```

Run the host-native sweep from the beginning:

```bash
sudo submission/eval_1_realworld/host_native/run_host_native_migration_sweep.sh start-tmux
sudo tmux attach -t eval1-host-native-sweep
```

The default sweep uses targets `16 32`, migration modes `off on`, and
workloads `pr bc gups btree graph500 liblinear`.  GAPBS reads the prebuilt
`kron_g29.sg` graph.  PR and BC both use 4 trials by default.  Graph500 uses
`bench_graph500_mt -s 28`.  Liblinear uses the existing `kdd12` dataset with
`train -s 6 -m 32`, writing the model file into the per-workload result
directory.  The runner persists state under
`/var/lib/iccd/eval1-host-native-migration-sweep` and installs an `@reboot`
resume hook so a target-convergence reboot continues the sweep in a new
`eval1-host-native-sweep` tmux session.

Current-host default plan:

- target 16G: keep node0 24G, reserve `232G@0x680000000`
- target 32G: keep node0 40G, reserve `216G@0xa80000000`
- target 48G: keep node0 56G, reserve `200G@0xe80000000`

The extra 8G above the requested target is intentional boot overhead. The
script will tune it after reboot if the measured node 0 free memory misses the
target window. The default target window is `target +/- 1G`.
