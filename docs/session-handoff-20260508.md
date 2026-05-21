# Migration-Friendly Session Handoff

Date: 2026-05-08 UTC

This document summarizes the end state of the 2026-05-08 session so the next
Codex session can resume without relying on chat scrollback.

## Read First

- Use the `migration-friendly-kernel` skill.
- Active code repository: `/Serverless/Migration-friendly`.
- Active kernel tree: `/Serverless/Migration-friendly/linux`.
- Retired kernel tree: `/Serverless/iccd/linux`; do not build or patch it
  unless explicitly asked for historical comparison.
- Current workload catalog:
  `/Serverless/iccd/docs/current-migration-workloads-20260507.md`.
- Also read this file before continuing. The workload catalog has accumulated
  experiment results; this file records the current code/git state and the
  latest interpretation.

## Current Git State

Repository: `/Serverless/Migration-friendly`

- Branch: `main`.
- Current pushed HEAD: `127df02aa`.
- Remote push target used this session:
  `origin git@github.com:zktsd813/Migration-friendly.git`.
- The latest kernel build after debug removal produced:
  `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`, kernel build
  number `#156`.

Recent pushed commits:

| commit | meaning |
| --- | --- |
| `127df02aa` | `mm/memcg: remove temporary NUMA debug counters`; removes `numa_dbg_*`, scheduler/vmscan debug hooks, and `debug_*` cgroup output fields. |
| `fc86a396a` | `mm/memcg: improve promotion headroom and latency diagnostics`; keeps the functional cgroup promotion headroom/reclaim retry change, but the temporary latency diagnostics were later removed by `127df02aa`. |
| `e97c4d418` | `Microbenchmark: add phase workloads and persistent hotset state`; current microbenchmark code is committed. |
| `99141a0a8` | `mm/memcg: unblock reclaimd-driven promotions`; earlier reclaimd balanced-accounting fix used by the successful friendly/unfriendly experiments. |

Current important uncommitted/untracked files in `/Serverless/Migration-friendly`:

- `scripts/kernel/launch_kernel_qemu.sh` is modified but not committed. The
  local diff adds host CPU affinity, guest memory backend host-node binding,
  `--numa-prealloc`, and parallel `modules_install` for initrd builds. These
  local changes are important for the canonical bound VM setup, but they were
  intentionally not pushed when the user asked for kernel-only commits.
- These runner/summarizer files are untracked but currently used locally:
  - `scripts/kernel/run_phase_candidate_microbench_guest.sh`
  - `scripts/kernel/run_qemu_phase_candidate_microbench.sh`
  - `scripts/kernel/run_qemu_phase_stat_probe.sh`
  - `scripts/kernel/summarize_phase_stat_probe.py`
- `Microbenchmark/` has no uncommitted changes as of this handoff.
- There are many untracked QEMU logs, experiment outputs, and module build
  artifacts. Do not commit them unless explicitly requested.

## Current Kernel State

The current pushed kernel keeps the functional promotion-headroom fix and
removes temporary debug instrumentation.

What remains:

- `mem_cgroup_node_over_high()` now tries to create cgroup-node promotion
  headroom through reclaimd before treating the cgroup redirect limit as a hard
  over-high failure.
- The promotion path no longer directly wakes reclaimd from
  `alloc_misplaced_dst_folio()`; the cgroup gate owns that feedback.
- Normal migration counters remain available, including:
  `numa_migrate_success_total`, `numa_migrate_success_promotion`,
  `numa_migrate_fail_promotion_blocked`,
  `numa_migrate_fail_promotion_over_high`,
  `numa_migrate_fail_promotion_alloc`,
  `numa_demote_promoted`, `numa_demote_promoted_referenced`, and
  `numa_promote_candidate_demoted`.

What was removed:

- All `numa_dbg_promote_*` and `numa_dbg_reclaimd_*` fields.
- Scheduler promotion debug update macros/hooks.
- vmscan reclaimd debug update hooks.
- `debug_*` output lines in `memory.numa_migrate_state` and
  `memory.reclaimd_state`.

Verification completed:

- `grep` for `numa_dbg_*`, relevant `debug_*`, and `memcg_reclaimd_dbg*`
  references in touched kernel files returned no matches.
- `git diff --check` passed.
- `make -C /Serverless/Migration-friendly/linux -j$(nproc) bzImage` succeeded
  and produced `bzImage #156`.

## Current Microbenchmark And Runner

Microbenchmark path:

- Source/build directory: `/Serverless/Migration-friendly/Microbenchmark`.
- Binary used by QEMU runner:
  `/Serverless/Migration-friendly/Microbenchmark/mbench`.
- Host runner default:
  `/Serverless/Migration-friendly/scripts/kernel/run_qemu_phase_candidate_microbench.sh`.
- Guest runner default:
  `/Serverless/Migration-friendly/scripts/kernel/run_phase_candidate_microbench_guest.sh`.

Execution flow:

1. Host runner sets `MBENCH_BIN` to
   `/Serverless/Migration-friendly/Microbenchmark/mbench`.
2. If missing, it runs `make -C /Serverless/Migration-friendly/Microbenchmark`.
3. It copies the binary into the VM as `/root/mbench`.
4. The guest runner executes `/root/mbench` under the configured cgroup policy.

Important workload labels:

- Phase pair: `phase_mulshift4g_block2m_sparse64_localft`.
- Friendly phase shape: `mulshift-hotset-4g-fixed`.
- Current standalone friendly smoke:
  `skew_lf_hotremote_4g_fixed_rss16g_mulshift_persistent`.
- HSS variants:
  `skew_lf_hotremote_16g_fixed_rss16g_mulshift_persistent`,
  `skew_lf_hotremote_32g_fixed_rss16g_mulshift_persistent`.
- Primary standalone unfriendly:
  `sparse_stride_read_64g_block2m_localft`.
- Secondary standalone unfriendly:
  `sparse_stride_read_64g`.

## Canonical Experiment Settings

Use the skill and workload catalog as canonical. The older
`docs/session-handoff-20260507.md` contains some outdated scan-period notes;
current default is `SCAN_PERIOD_SCALE=100`, not `1`.

Default topology:

- `MEMORY=96G`
- `CPUS=32`
- `HOST_CPUS=0-31`
- guest node0 CPUs: `NUMA_NODE0_CPUS=0-31`
- guest node0 memory: `NUMA_NODE0_MEM=32G`
- guest node1 memory: `NUMA_NODE1_MEM=64G`
- bind guest node0 memory to host node0 DRAM:
  `NUMA_NODE0_HOST_NODES=0`
- bind guest node1 memory to host node2 CXL:
  `NUMA_NODE1_HOST_NODES=2`
- host NUMA policy/preallocation:
  `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1`
- cgroup local node cap:
  `CAPACITY_PAGES=4194304` for 16 GiB.
- threads: `THREADS=32`

Default memory-management knobs:

- MGLRU must be enabled in the guest:
  `/sys/kernel/mm/lru_gen/enabled` should be `0x0007`.
- `NUMA_SCAN_SIZE_MB=4096` unless explicitly testing scan-size sensitivity.
- `SCAN_PERIOD_SCALE=100` unless explicitly requested otherwise.
- `HOT_THRESHOLD_MS=0` so the kernel uses Linux default hot threshold
  currently `1000ms`.
- Normal experiments must explicitly keep these disabled:
  `NUMA_MIGRATION_STOP_ENABLED=0`,
  `NUMA_PINGPONG_STAT_ENABLED=0`.
- For local-first-touch microbench runs:
  `PREFAULT_PHASE_GATE=1`,
  `PREFAULT_SETTLE_RECLAIMD=0`,
  `LOCAL_NODE=0`,
  `REMOTE_NODE=1`,
  `CPUSET_CPUS=0-31`,
  `CPUSET_MEMS=0,1`.

Build and VM hygiene:

- Kernel builds must use all CPUs:
  `make -C /Serverless/Migration-friendly/linux -j$(nproc) bzImage`.
- For VM runs after kernel changes, build and pass a fresh initrd. Do not rely
  on wrapper fallback to `/boot/vmlinuz-*` or `/boot/initrd.img-*`.
- Every experiment result should state kernel image, initrd, KVM status, VM
  binding, cgroup cap, MGLRU runtime value, earlystop/pingpong state, scan
  tuning, workload, throughput, promoted pages/GiB, and demoted pages/GiB.
- Report demotion as `pgdemote_direct + pgdemote_kswapd` when both are
  available.

## Current Interpretation

The current best explanation for the confusing promotion results is:

- Early failures were not primarily caused by stale NUMA candidates or no hint
  faults. Temporary hooks showed candidates were produced and latency could
  pass for large volumes of remote hotset pages.
- A real cgroup headroom problem existed: promotion could stop near the
  `high - reserve` to `high` range where new promotions were rejected but the
  reclaim trigger did not continuously create the same kind of headroom that
  physical-node kswapd paths tend to maintain.
- The current kernel addresses that by retrying synchronous cgroup reclaimd
  headroom creation from the cgroup over-high gate.
- Node1 allocation failure was a separate bottleneck during demotion. Raising
  guest node1 capacity to 128G removed most demotion allocation failures and
  increased promotion substantially, but did not by itself fully promote a
  32G hotset.
- After node1 was enlarged and over-high behavior improved, the remaining
  issue shifted toward the latency/hotness filter and NUMA scan timing:
  initial candidate bursts can pass, while later phases may fail latency once
  scan/candidate timing and access cadence diverge.
- Because temporary latency bucket counters were removed from the current
  kernel, future latency-filter analysis needs either a new short-lived hook
  or a non-debug production counter design.

Important nuance:

- `candidate/HSS` values from large scan-size runs are event volumes, not
  unique hotset coverage. The same page can be re-armed and counted repeatedly
  as a candidate, especially with `NUMA_SCAN_SIZE_MB=4096`.
- Low `promotion/HSS` does not automatically mean the scanner never touched
  the HSS; it can also mean candidates repeatedly failed at headroom,
  allocation, rate, or latency gates.

## Experiment Results To Keep In Mind

The workload catalog contains the detailed tables. The short current picture:

- Phase full on/off, no earlystop/no pingpong, local-first-touch:
  `phase_mulshift4g_block2m_sparse64_localft`.
  - Overall: off `600.66 Mops/s`, on `1388.38 Mops/s`, `2.311x`.
  - Friendly phases: off `949.14 Mops/s`, on `2633.09 Mops/s`, `2.774x`.
  - Unfriendly sparse phases: off `256.08 Mops/s`, on `159.00 Mops/s`,
    `0.621x`.
  - On promoted `5,229,907` pages (`19.95 GiB`) and demoted `5,249,549`
    pages (`20.03 GiB`).
- Adaptive/oracle no-earlystop/no-pingpong baseline:
  - Overall `1324.07 Mops/s`, `2.204x` vs off, `0.954x` vs full-on.
  - Friendly phases `2408.90 Mops/s`, `0.915x` vs full-on.
  - Sparse phases `251.81 Mops/s`, `0.983x` vs off and `1.584x` vs full-on.
- Earlystop diagnostic axis:
  - Run only when explicitly testing earlystop/pingpong.
  - It stopped in friendly phases and restarted in sparse phases.
  - It carried measurable overhead versus no-earlystop full-on, so keep it off
    by default.
- HSS32 same friendly access shape:
  - Off `225.73 Mops/s`, on `255.19 Mops/s`, mean `1.131x`, median `0.999x`,
    last-10s `1.681x`.
  - On promoted `887,008` pages (`3.38 GiB`) and demoted `1,013,852` pages
    (`3.87 GiB`).
  - This looked "friendly" by mean, but promotion volume is much smaller than
    the 32G HSS. Treat it as a scanner/gate/latency diagnostic workload rather
    than a clean friendly baseline.
- Confirmed standalone unfriendly candidates:
  - `sparse_stride_read_64g_block2m_localft`: off `1978.71 MiB/s`, on
    `1121.61 MiB/s`, on/off `0.567x`.
  - `sparse_stride_read_64g`: off `1667.92 MiB/s`, on `1194.97 MiB/s`,
    on/off `0.716x`.

Recent diagnostic experiment directories:

- `/Serverless/iccd/experiments/20260508-hss32-randomread-latbucket-600s-node1-128g`
- `/Serverless/iccd/experiments/20260508-overhigh-long600-pc-random-node1-128g`
- `/Serverless/iccd/experiments/20260508-friendly-hss32-scan4096-600s-cgroup`
- `/Serverless/iccd/experiments/20260508-reclaimd-demotion-detail-hook-hss32-180s`
- `/Serverless/iccd/experiments/20260508-physical-node16-hss32-scan4096-400s-phys-hook`
- `/Serverless/iccd/experiments/20260508-phase-onoff-adaptive-nostop-noping-localft-256scan-initrd`
- `/Serverless/iccd/experiments/20260508-phase-earlystop-axis-localft-256scan-initrd`

## What To Do Next

Likely next investigation:

1. Re-read `docs/current-migration-workloads-20260507.md` and this handoff.
2. Confirm the code state:
   `git -C /Serverless/Migration-friendly rev-parse --short HEAD` should be
   `127df02aa` if using the current pushed kernel.
3. Decide whether to commit the local QEMU launcher/runner scripts. Current
   local experiments depend on those local scripts for host CPU/node binding,
   but they are not pushed.
4. If continuing the latency-filter question, add a temporary hook only for
   the targeted run and remove it afterward before committing/pushing.
5. Prefer comparing:
   - `sparse_stride_read_64g_block2m_localft` on/off under current clean
     kernel,
   - HSS32 random-read under current clean kernel,
   - and phase on/off/adaptive under clean kernel,
   while keeping `NUMA_MIGRATION_STOP_ENABLED=0` and
   `NUMA_PINGPONG_STAT_ENABLED=0`.
6. For any new experiment, create a fresh initrd from the current kernel and
   store outputs under a new `/Serverless/iccd/experiments/<name>/` directory.

## Do Not Forget

- The current kernel no longer exposes the temporary latency bucket/debug
  counters. Do not expect `debug_promote_latency_*`, `debug_shrink_enter`, or
  similar fields in cgroup state files.
- Historical experiment summaries that mention `debug_*` fields refer to
  temporary hook/debug kernels, not the current clean pushed kernel.
- `SCAN_PERIOD_SCALE=100` is the current normal default. Lower values scan
  more often and are diagnostic.
- `NUMA_SCAN_SIZE_MB=4096` can inflate candidate event volume; note it in
  summaries and switch back to `256` only for explicit 256MB comparison runs.
- For ordinary runs, earlystop and pingpong stat are off unless the user
  explicitly asks for the `earlystop` axis.
