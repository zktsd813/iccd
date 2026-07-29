# Session Handoff - 2026-06-07

This handoff records the host-CXL workload retry and SPEC CPU2017 preparation
session. Start future work by reading `docs/session-handoff-20260601.md`,
`docs/session-handoff-20260605.md`, then this file.

## Current Stop State

All experiments were stopped by user request at `2026-06-07T05:18:26Z`.

- Active experiment tmux session `iccd-host-failed-realworld-all-controls` was
  killed.
- Root crontab reboot hook for
  `host-full-local8-16-32-20260606T050033Z` was removed.
- No matching host sweep, workload, SPEC, probe, redis, or memcached experiment
  process remained after cleanup.
- Host guard state was restored:
  - SMT: `on`
  - online CPUs: `0-127`
  - node1 CPUs: online
  - node0 memory: restored to full size, `numactl -H` showed
    `node 0 size: 128594 MB`, `node 0 free: 121343 MB`
  - node2 CXL memory: online, `node 2 size: 262144 MB`

Stop markers:

- `motivation/host/results/host-full-local8-16-32-20260606T050033Z/state/progress.txt`
  now has `state=stopped_by_user`.
- `motivation/host/results/host-full-local8-16-32-20260606T050033Z/state/stopped-20260607T0516Z.txt`
  records the manual stop.

## Host Failed-Workload Retry

The failed-workload retry was started, then stopped.

- Run root:
  `motivation/host/results/host-full-local8-16-32-20260606T050033Z`
- tmux session that was started and then killed:
  `iccd-host-failed-realworld-all-controls`
- Archive ID used before stop:
  `failed-realworld-all-controls-20260607T050938Z`
- Dry-run before launch reported `106` pending cases.
- Matrix:
  - `LOCAL_SIZES='8 16 32'`
  - `WORKLOADS=failed_realworld`
  - normal configs: `all_fast all_slow migration_off migration_on tpp`
  - THP configs: `all_fast all_slow migration_off migration_on`
  - `xsbench` remained excluded.
- Reboot settings:
  - `ALLOW_REBOOT=1`
  - `MAX_REBOOTS_PER_CASE=4`
  - `MAX_TOTAL_REBOOTS=400`
  - `AUTO_ONLINE_CXL=1`

Progress before stop:

- Completed during this retry:
  - `control/all_slow/memcached_ycsb_uniform`
  - `returncode=0`, `elapsed_s=272`
  - status file:
    `motivation/host/results/host-full-local8-16-32-20260606T050033Z/host-results/control/all_slow/memcached_ycsb_uniform/status.txt`
- Interrupted:
  - `control/all_slow/faster_uniform`
  - status file existed but had no completed `returncode` when inspected.

Important resume note: do not reuse
`RERUN_ARCHIVE_ID=failed-realworld-all-controls-20260607T050938Z` with the
default `SKIP_FAILED_AFTER_RERUN_ATTEMPT=1`, because the interrupted
`faster_uniform` case already has an archive entry for that ID and may be
skipped. Use a fresh `RERUN_ARCHIVE_ID` or set
`SKIP_FAILED_AFTER_RERUN_ATTEMPT=0`.

Recommended resume command, only if the user explicitly asks to continue:

```bash
sudo -n env \
  RUN_ID=host-full-local8-16-32-20260606T050033Z \
  RESULTS_ROOT=/Serverless/iccd-git/motivation/host/results \
  LOCAL_SIZES='8 16 32' \
  CONFIGS='all_fast all_slow migration_off migration_on tpp' \
  THP_CONFIGS='all_fast all_slow migration_off migration_on' \
  WORKLOADS=failed_realworld \
  REMAINING_ONLY=1 \
  RERUN_ARCHIVE_ID=failed-realworld-all-controls-$(date -u +%Y%m%dT%H%M%SZ) \
  ALLOW_REBOOT=1 \
  MAX_REBOOTS_PER_CASE=4 \
  MAX_TOTAL_REBOOTS=400 \
  AUTO_ONLINE_CXL=1 \
  TMUX_SESSION=iccd-host-failed-realworld-all-controls \
  motivation/host/scripts/run_host_sweep_tmux.sh
```

## SPEC CPU2017 State

SPEC CPU2017 rate candidates were probed with 32 copies. Corrected summary:

- `experiments/20260607-spec2017-rate-rss-probe/rss_summary.corrected.csv`

Measured peak tree RSS and local-size targets:

| Benchmark | Elapsed | Peak RSS | 25% target | 50% target |
| --- | ---: | ---: | ---: | ---: |
| `503.bwaves_r` | 1093s | 26.110 GiB | 7G | 13G |
| `507.cactuBSSN_r` | 216s | 25.097 GiB | 6G | 13G |
| `519.lbm_r` | 1080s | 13.245 GiB | 3G | 7G |
| `505.mcf_r` | 470s | 19.448 GiB | 5G | 10G |
| `520.omnetpp_r` | 496s | 7.973 GiB | 2G | 4G |

`520.omnetpp_r` initially failed due to the `SPEC_HYPOT` registration issue.
It was fixed in the SPEC tree by registering the symbol as a 2-argument math
function:

- `/Serverless/benchmark/spec/benchspec/CPU/520.omnetpp_r/src/simulator/nedfunctions.cc`
- `/Serverless/benchmark/spec/benchspec/CPU/520.omnetpp_r/build/build_base_mytest-m64.0000/simulator/nedfunctions.cc`
- `/Serverless/benchmark/spec-iso-1.0.2/benchspec/CPU/520.omnetpp_r/src/simulator/nedfunctions.cc`

The SPEC run config also has:

- `verify_binaries = no`
- `strict_rundir_verify = 0`

SPEC fraction experiment was prepared but not started, because the user stopped
all experiments while the failed-workload retry was running.

Prepared launcher:

- `motivation/host/scripts/run_spec2017_fraction_sweep_tmux.sh`

Dry-run verified `40` SPEC cases:

- controls: `all_fast`, `all_slow`
- migration configs: `migration_off`, `migration_on`, `tpp`
- per-workload local targets as listed above
- no THP SPEC runs

Recommended SPEC start command, only if the user explicitly asks to run it:

```bash
sudo -n env \
  RUN_ID=spec2017-rssfrac-$(date -u +%Y%m%dT%H%M%SZ) \
  motivation/host/scripts/run_spec2017_fraction_sweep_tmux.sh
```

## Script Changes In This Session

New or changed host scripts:

- `scripts/run_workload_case_guest.sh`
  - SPEC runner now tees `runcpu` output and treats internal `Error:` lines or
    missing `Success:` as failure even if `runcpu` exits `0`.
- `motivation/host/scripts/run_host_sweep.sh`
  - Added `WORKLOAD_LOCAL_SIZES`, allowing per-workload local targets.
  - Count, pending count, dry-run output, and real matrix execution now respect
    per-workload sizes.
  - Passes `SPEC2017_OUTPUT_ROOT` through to the case runner.
- `motivation/host/scripts/run_host_sweep_tmux.sh`
  - Persists SPEC variables and `WORKLOAD_LOCAL_SIZES` into tmux/reboot-resume
    environment files.
- `motivation/host/scripts/run_spec2017_fraction_sweep_tmux.sh`
  - New launcher that reads the corrected SPEC RSS summary, computes nearest
    GiB 25%/50% targets, and starts one reboot-resumable host sweep.

Earlier host/SPEC helper files from the same working set:

- `motivation/host/scripts/probe_spec2017_rss.sh`
  - SPEC RSS probe with process-tree RSS/PSS sampling and `Error:` detection.
- `motivation/host/scripts/run_spec32.sh`
  - SPEC wrapper for 32-thread/32-copy host runs.
- `motivation/host/README.md`
  - Documents `spec32_rate`, `spec32_all`, and measured SPEC RSS.

The worktree is intentionally dirty and includes unrelated kernel and
experiment changes. Do not reset or delete generated experiment outputs unless
the user explicitly asks.

## Verification Commands Used After Stop

```bash
ps -eo pid,ppid,stat,etime,cmd | grep -E 'run_host_sweep|run_host_case|run_workload_case_guest|timeout 21600|Faster|faster|memcached|redis-server|runcpu|specinvoke|probe_spec2017' | grep -v grep
sudo -n tmux list-sessions
sudo -n crontab -l | grep -A2 -B1 'ICCD_HOST_REBOOT_RESUME'
cat /sys/devices/system/cpu/smt/control
cat /sys/devices/system/cpu/online
numactl -H
```

At handoff time, these showed no active experiment processes or reboot hook,
and host CPU/memory state was restored.
