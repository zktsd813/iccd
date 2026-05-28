# ICCD VM Experiment Scripts

This directory collects the VM launch and guest-side workload scripts currently
used for the ICCD physical-limit experiments.  The files here are a curated
snapshot from the active experiment paths so the VM setup is easier to find and
reuse.

## Current VM Setup

The latest physical 8G workload runs use this topology:

| item | value |
| --- | --- |
| kernel image | `/Serverless/iccd/linux-build-mt/arch/x86/boot/bzImage` |
| initrd | `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified.img` |
| QEMU binary | `/Serverless/Migration-friendly/qemu/build/qemu-system-x86_64` |
| rootfs | `/Serverless/Migration-friendly/qemu/build/ubuntu.img` |
| launcher | `/Serverless/Migration-friendly/scripts/kernel/launch_kernel_qemu.sh` |
| acceleration | KVM |
| vCPUs | 32 |
| host CPU pinning | `0-31` |
| guest node0 | CPUs `0-31`, memory `8G`, host NUMA node `0` |
| guest node1 | memory `160G`, host NUMA node `2` |
| total guest memory | `168G` |
| QEMU memory policy | `bind`, `prealloc=on` |
| MGLRU runtime state | `0x0007` |

Node0 is the local/fast tier.  Node1 is the remote/slow tier.  For the current
physical-limit experiments, the local capacity is enforced by the VM topology
itself: guest node0 is physically sized to 8G and the local-util runner uses
`--capacity-pages 0`.

## Directory Layout

| path | role |
| --- | --- |
| `host/` | Host-side wrappers that launch QEMU, stage binaries into the guest, run the guest workload script, and collect results. |
| `guest/` | Guest-side workload orchestrators used by recent physical on/off and ours-toggle experiments. |
| `scripts/` | Reusable controller and workload helper scripts staged into the guest by host wrappers. |

## Important Files

| file | purpose |
| --- | --- |
| `host/run_phys8g_allworkloads_ours_toggle_w5.sh` | Full host wrapper for the physical 8G all-workload `ours-toggle w5` run. |
| `host/resume_phys8g_allworkloads_ours_toggle_w5.sh` | Resume variant for the same experiment. |
| `guest/run_all_workloads_phys8g_ours_toggle_w5_guest.sh` | Runs PR, BC, Silo, Liblinear, NAS FT/LU/SP, GUPS, Graph500, BTree, and XSBench under the local-util controller. |
| `guest/run_single_workload_physical_limit_guest.sh` | Guest runner used for physical-limit migration `off` and `on` baselines. |
| `scripts/run_local_util_adapt_experiment.sh` | Workload-agnostic wrapper that creates the cgroup, applies NUMA/tiering knobs, launches the controller, and runs one benchmark command. |
| `scripts/local_util_adapt_controller.py` | Userspace controller that samples local-fault windows and toggles cgroup migration. |
| `scripts/stage_single_workloads_to_vm.sh` | Helper for staging benchmark binaries and inputs into the guest. |

## Policy Settings

Physical on/off baseline:

| policy | global NUMA balancing | demotion | cgroup node balancing |
| --- | ---: | ---: | ---: |
| `off` | `0` | `0` | `0` |
| `on` | `2` | `1` | `2` |

The latest physical on/off guest runner also sets:

- `scan_size_mb=256`
- `scan_period_min_ms=1000`
- `fast_scan=0`
- `demotion_target="0 1"`
- `cpuset.cpus=0-31`
- `cpuset.mems=0,1`

Ours-toggle w5:

- Starts with migration enabled for the workload cgroup.
- Uses `local_fault_rate=10`.
- Uses `window_sec=5`.
- Turns migration off after either local-access or remote-ratio conditions hold
  for three consecutive windows.
- Re-enables migration when the stop condition does not hold for two consecutive
  windows (`reenable_consecutive=2`).
- Keeps `capacity_pages=0`, so physical node0 size is the local-memory limit.

## Workload Inputs

Host wrappers stage benchmark files from `/Serverless/benchmark` into the guest.
For GAPBS PR/BC, the measured run uses a prebuilt graph:

```text
/root/gapbs_graphs/kron_g28.sg
```

The graph is copied from:

```text
/Serverless/benchmark/gapbs/benchmark/graphs/kron_g28.sg
```

PR/BC should use `-f /root/gapbs_graphs/kron_g28.sg` in measured runs, not
`-g28`, so graph generation and build time are excluded.

## Source Snapshot

These files were copied from:

| VM copy | source |
| --- | --- |
| `host/run_phys8g_allworkloads_ours_toggle_w5.sh` | `experiments/20260528-phys8g-allworkloads-ours-toggle-w5/notes/run_phys8g_allworkloads_ours_toggle_w5.sh` |
| `host/resume_phys8g_allworkloads_ours_toggle_w5.sh` | `experiments/20260528-phys8g-allworkloads-ours-toggle-w5/notes/resume_phys8g_allworkloads_ours_toggle_w5.sh` |
| `guest/run_all_workloads_phys8g_ours_toggle_w5_guest.sh` | `experiments/20260528-phys8g-allworkloads-ours-toggle-w5/guest/run_all_workloads_phys8g_ours_toggle_w5_guest.sh` |
| `guest/run_single_workload_physical_limit_guest.sh` | `experiments/20260527-physlimit-cgfix-8g-global02-onoff/guest/run_single_workload_physical_limit_guest.sh` |
| `scripts/*` | `/Serverless/iccd/scripts/*` |

The canonical active kernel source remains `/Serverless/iccd/linux`; the
reference Migration-friendly tree should not be patched for current ICCD runs.
