# Eval 1 Host-Native Boot Targeting

This directory prepares host-native eval_1 runs without the VM.

The boot-target script writes a guarded GRUB drop-in that:

- keeps node 0 as the local DRAM node,
- keeps node 1 as the remote memory node on the current host,
- reserves local node 0 memory above the target and non-kept memory ranges at boot
  with `memmap=...$...`,
- boots only the initial node 0 CPU prefix with `maxcpus=...` on the current host,
- disables SMT with `nosmt`,
- onlines the kept remote memory node after reboot,
- adjusts the amount of node 0 memory left usable until node 0 free memory
  reaches the requested target.

On the 2026-06-24 booted hardware, node 2 and node 3 are present in NUMA
topology but have no memory, so the default remote memory node is node 1:
`KEEP_MEMORY_NODES=1`, `REMOTE_NODE=1`, and `OFFLINE_CPU_NODE=1`.

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
the current-host defaults this means node 1 remote memory.  The script sets
`/sys/devices/system/memory/auto_online_blocks` to `online` when possible,
uses `daxctl online-memory` for matching `system-ram` DAX devices when
`daxctl` is available, and then falls back to onlining node memory blocks
through sysfs.

Automatic convergence across reboots:

```bash
sudo submission/eval_1_realworld/host_native/host_boot_target.sh converge \
  --target-gib 16 --apply --reboot
```

`converge` installs an `@reboot` hook. If node 0 free memory is not within the
effective target window after reboot, it rewrites the GRUB drop-in with a
different node 0 online size and reboots again, up to `MAX_REBOOTS`.  The
effective target window is at least `TARGET_TOLERANCE_GIB`, but is widened to
one memory-block size when the host block size is larger.  On this host the
memory block size is 2 GiB, so the default target window is `target +/- 2G`.
The default `MAX_REBOOTS` is `4`.  A manually started `converge --reboot`
resets the reboot counter, applies the initial plan, and reboots before making
the first decision.  If a post-reboot adjustment is needed from a memmap-limited
boot, the script restores an unrestricted boot first and then applies the
adjusted plan.  The reboot hook waits `VERIFY_DELAY_AFTER_REBOOT_SEC` seconds,
default `90`, then runs one generated-scale PR warmup trial with migration
enabled, drops host caches, and only then verifies the target. The default
warmup is:

```bash
numactl --cpunodebind=0 env OMP_NUM_THREADS=32 OMP_PROC_BIND=true OMP_PLACES=cores \
  /Serverless/benchmark/gapbs/pr \
    -g 29 \
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

The default sweep uses targets `16 32 48`, migration modes `off on tpp ours`,
and workloads `pr bc gups btree graph500 silo liblinear`. GAPBS PR and BC
generate scale-29 graphs with `-g 29`; serialized graph files are not used. PR
and BC both use 4 trials by default. Graph500 uses `bench_graph500_mt -s 28`.
The runner persists state under
`/var/lib/iccd/eval1-host-native-migration-sweep` and installs an `@reboot`
resume hook so a target-convergence reboot continues the sweep in a new
`eval1-host-native-sweep` tmux session.

By default the sweep runner does not hard-code current-host memmap ranges.
When it switches targets, it asks `host_boot_target.sh converge` to generate a
fresh plan from the current full-boot topology.  Static overrides are still
available by setting both `HOST_BOOT_CMDLINE_<target>G` and
`HOST_BOOT_NODE0_ONLINE_<target>G`.

The extra 8G above the requested target is the initial boot-overhead estimate.
The script can tune it after reboot if the measured node 0 free memory misses
the target window.  The adjusted node0 online size is clamped to at least
`target + MIN_NODE0_BOOT_SURPLUS_GIB`, default 4G, so convergence does not
generate unsafe tiny local-memory boots such as `node0_online_gib=2`.

The four modes program and verify the following kernel state:

| Mode | `numa_balancing` | `migration_enabled` | `demotion_enabled` |
|---|---:|---:|---|
| `off` | 0 | 0 | `false` |
| `on` | 2 | 1 | `true` |
| `tpp` | 4 | 1 | `true` |
| `ours` | 2 | controller-managed | `true` |

The `ours` mode uses the same canonical runner as VM experiments:
`design/fault_bucket_controller/run_guest.sh`. It keeps NUMA scanning enabled
and changes only `/sys/kernel/mm/numa_balancing/migration_enabled`.

Every policy window rereads the workload process tree and obtains its current
local and remote resident pages, `L` and `R`. With local P75 latency `q`:

```text
STOP_RAW  = (F_remote_le(q) * R) / (0.25 * L) > 0.9
START_RAW = F_remote_lt(q) * R >= 1.10 * 0.75 * L
```

STOP is immediate. START requires two consecutive valid windows, and a
confirmed START wins when START and STOP overlap. Invalid or false START
observations reset the START counter. Current defaults are:

```bash
NUMA_SCAN_SIZE_MB=256
NUMA_SCAN_PERIOD_MIN_MS=1000
LOCAL_FAULT_RATE=5
LOCAL_FAULT_SCAN_PERIOD_MS=1000
LOCAL_FAULT_SCAN_SIZE_MB=64
MGLRU_ENABLED=0x0007
THP_MODE=never
THP_DEFRAG=never
DEMOTION_TARGETS=0:1
OURS_WINDOW_SEC=1
OURS_CYCLE_WINDOW_MIN_SEC=5
OURS_CYCLE_WINDOW_MAX_SEC=20
OURS_MIN_LOCAL_PAGES=1024
OURS_MIN_REMOTE_PAGES=1024
OURS_START_CONSECUTIVE=2
OURS_START_CAPACITY_MARGIN_PCT=10
OURS_STOP_CAPACITY_RATIO_THRESHOLD=0.9
```

The sweep requires the cleaned kernel ABI: `fault_latency_quantiles`,
`local_fault_window`, `local_fault_rate`, `local_fault_scan_period_ms`,
`local_fault_scan_size_mb`, `remote_scan_cycles`, and `migration_enabled`.
Preflight exits before changing policy state when this ABI is unavailable.

## Recovery

The preferred recovery path, when the machine boots far enough to log in during
the safe window, is:

```bash
sudo crontab -l
sudo submission/eval_1_realworld/host_native/run_host_native_migration_sweep.sh remove-hook
sudo submission/eval_1_realworld/host_native/host_boot_target.sh restore --apply
sudo reboot
```

`restore --apply` removes the guarded GRUB drop-in
`/etc/default/grub.d/99-iccd-eval1-host-native.cfg`, updates GRUB, removes the
boot-target reboot hook, and resets the boot-target state.  Add `--reboot` to
the restore command when you want the script to reboot immediately.

If the host cannot boot normally because the generated kernel cmdline left too
little memory, editing the GRUB entry at the boot menu and deleting the ICCD
boot arguments is the right emergency recovery.  Remove the generated
`memmap=...`, `maxcpus=...`, `nosmt`, and `memhp_default_state=...` arguments
for that one boot, then run the preferred recovery commands above after login.

Both reboot hooks now leave a default 90 second safe window after boot before
they change boot targeting or resume the sweep:

- `VERIFY_DELAY_AFTER_REBOOT_SEC=90` for `host_boot_target.sh`
- `RESUME_WAIT_SEC=90` for `run_host_native_migration_sweep.sh`
