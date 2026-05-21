# Migration-Friendly Session Handoff

Date: 2026-05-09 UTC

This document summarizes the end state of the 2026-05-09 session so a new
Codex session can resume without relying on chat history.

## Read First

- Use the `migration-friendly-kernel` skill.
- Active code repository: `/Serverless/Migration-friendly`.
- Active kernel tree: `/Serverless/Migration-friendly/linux`.
- Retired kernel tree: `/Serverless/iccd/linux`; do not build, patch, or boot
  it unless explicitly asked for historical comparison.
- Current workload catalog:
  `/Serverless/iccd/docs/current-migration-workloads-20260507.md`.
- Important update after the 2026-05-08 handoff: current fast-scan work no
  longer uses the old memcg `memory.numa_balancing_scan_period_scale` knob.
  Use `memory.numa_balancing_fast_scan`, exposed by the runners as
  `NUMA_FAST_SCAN`.

## Current Repository State

Repository: `/Serverless/Migration-friendly`

- Branch: `main`.
- Current HEAD: `127df02aa`.
- The worktree is dirty. Do not assume the fast-scan implementation is
  committed.
- There are many unrelated untracked logs, build artifacts, and historical
  result directories. Do not clean or revert them unless explicitly asked.

Important modified files:

- `Microbenchmark/include/mbench.h`
- `Microbenchmark/src/core/alloc.c`
- `Microbenchmark/src/core/config.c`
- `Microbenchmark/src/core/numa.c`
- `Microbenchmark/src/core/phase.c`
- `Microbenchmark/src/core/runtime.c`
- `linux/Documentation/admin-guide/cgroup-v2.rst`
- `linux/include/linux/memcontrol.h`
- `linux/kernel/sched/fair.c`
- `linux/mm/memcontrol.c`
- `scripts/bench_V2/run_cxl_halfnode_sweep.py`
- `scripts/bench_V2/run_host_mode2_coarse_sweep.py`
- `scripts/bench_V2/run_microbenchmark_cgroup_sweep.py`
- `scripts/kernel/launch_kernel_qemu.sh`
- `scripts/kernel/render_memcg_numa_knob_report.py`
- `scripts/kernel/run_qemu_memcg_numa_knob_validation.sh`
- `scripts/kernel/validate_memcg_numa_knobs.sh`
- `scripts/research/run_single_tenant_knob_case.sh`
- `scripts/research/run_vm_single_tenant_matrix.sh`

Important untracked files currently used by experiments:

- `scripts/bench_V2/run_phase_microbenchmark_setup.py`
- `scripts/kernel/run_phase_candidate_microbench_guest.sh`
- `scripts/kernel/run_qemu_phase_candidate_microbench.sh`
- `scripts/kernel/run_qemu_phase_stat_probe.sh`
- `scripts/kernel/summarize_phase_stat_probe.py`

## Fast-Scan Kernel Design

User request: replace the old scale-style scan knob with a simple on/off fast
scan knob, then make scan-period tuning happen through the existing global
scan-period knob.

Current design:

- Removed the memcg knob `memory.numa_balancing_scan_period_scale`.
- Added boolean memcg knob `memory.numa_balancing_fast_scan`.
- `fast_scan=0`: normal kernel NUMA balancing timing.
- `fast_scan=1`: bypasses only the two gates that hid scan-period changes:
  - the `MAX_SCAN_WINDOW` floor inside `task_scan_min()`;
  - the scanner overhead limiter in `task_numa_work()` that applies
    `p->node_stamp += 32 * diff`.
- `mm->numa_next_scan` and the `try_cmpxchg()` serialization remain unchanged.
  This intentionally keeps one scanner per mm at a time.
- The actual base period is still controlled by the existing debugfs/sysctl
  scan-period knob, for example
  `/sys/kernel/debug/sched/numa_balancing/scan_period_min_ms`.

Relevant kernel files:

- `/Serverless/Migration-friendly/linux/include/linux/memcontrol.h`
  - adds `u8 numa_balancing_fast_scan`.
- `/Serverless/Migration-friendly/linux/mm/memcontrol.c`
  - initializes the field to false;
  - implements read/write handlers;
  - exposes cgroup v2 file `memory.numa_balancing_fast_scan`.
- `/Serverless/Migration-friendly/linux/kernel/sched/fair.c`
  - adds `task_numa_fast_scan()`;
  - uses a fast path in `task_scan_min()`;
  - disables the scanner overhead limiter only when fast scan is enabled.
- `/Serverless/Migration-friendly/linux/Documentation/admin-guide/cgroup-v2.rst`
  - documents the new cgroup knob.

Reasoning behind this design:

- With `NUMA_SCAN_SIZE_MB=4096`, normal mode can be held by the
  `MAX_SCAN_WINDOW` floor around 1000 ms even if the RSS/window calculation
  would allow a shorter period.
- For the current 64 GiB RSS / 4 GiB scan-window shape:
  - normal floor keeps the minimum around 1000 ms;
  - fast scan with `scan_period_min_ms=1000` gives roughly 62 ms windows;
  - fast scan with `scan_period_min_ms=250` gives roughly 15.6 ms windows.
- `NUMA_SCAN_PERIOD_MIN_MS` should therefore show a visible 4x period-model
  difference only when `NUMA_FAST_SCAN=1`.

Review:

- A review agent checked the fast-scan implementation during this session.
- It found stale old scale-knob references in `scripts/research`; those were
  fixed.
- It also noted that some `bench_V2` metadata, variable names, and CLI flags
  still say `scan_period_scale`. Those paths now write
  `numa_balancing_fast_scan`, but the naming is still legacy and should be
  cleaned before treating those scripts as polished.

## Runner And Script Changes

Current phase-candidate runner variables:

- `NUMA_FAST_SCAN=0|1`
  - writes `memory.numa_balancing_fast_scan` in the workload cgroup.
- `NUMA_SCAN_PERIOD_MIN_MS=<ms>`
  - optional;
  - writes `/sys/kernel/debug/sched/numa_balancing/scan_period_min_ms`;
  - the guest runner saves and restores the original value;
  - run metadata records both requested and effective values.
- `NUMA_SCAN_SIZE_MB=4096`
  - still used for the scan window size.

Important changed runner files:

- `/Serverless/Migration-friendly/scripts/kernel/run_phase_candidate_microbench_guest.sh`
- `/Serverless/Migration-friendly/scripts/kernel/run_qemu_phase_candidate_microbench.sh`
- `/Serverless/Migration-friendly/scripts/kernel/validate_memcg_numa_knobs.sh`
- `/Serverless/Migration-friendly/scripts/kernel/run_qemu_memcg_numa_knob_validation.sh`
- `/Serverless/Migration-friendly/scripts/kernel/render_memcg_numa_knob_report.py`
- `/Serverless/Migration-friendly/scripts/research/run_single_tenant_knob_case.sh`
- `/Serverless/Migration-friendly/scripts/research/run_vm_single_tenant_matrix.sh`

Important caution:

- Current post-fast-scan experiments should use `NUMA_FAST_SCAN` and optionally
  `NUMA_SCAN_PERIOD_MIN_MS`.
- Do not use the old `SCAN_PERIOD_SCALE` mental model for this new work.
- Some older docs and the skill text still mention `SCAN_PERIOD_SCALE`; treat
  this handoff as the newer source of truth for fast-scan experiments.

## Canonical VM Setup

Default topology used in the current experiments:

```text
MEMORY=96G
CPUS=32
HOST_CPUS=0-31
NUMA_NODE0_CPUS=0-31
NUMA_NODE0_MEM=32G
NUMA_NODE1_MEM=64G
NUMA_NODE0_HOST_NODES=0
NUMA_NODE1_HOST_NODES=2
NUMA_MEM_POLICY=bind
NUMA_PREALLOC=1
CAPACITY_PAGES=4194304
LOCAL_NODE=0
REMOTE_NODE=1
CPUSET_CPUS=0-31
CPUSET_MEMS=0,1
```

Default memory-management state:

```text
MGLRU expected: /sys/kernel/mm/lru_gen/enabled == 0x0007
NUMA_SCAN_SIZE_MB=4096
HOT_THRESHOLD_MS=0
NUMA_MIGRATION_STOP_ENABLED=0
NUMA_PINGPONG_STAT_ENABLED=0
```

For ordinary experiments, explicitly keep early stop and ping-pong accounting
disabled unless the experiment name says it is a diagnostic run.

## Build And Validation State

Validation completed during this session:

- `bash -n` passed for the changed shell scripts.
- `python3 -m py_compile` passed for the changed Python scripts.
- `git diff --check` passed.
- Kernel build passed:
  `make -C /Serverless/Migration-friendly/linux -j$(nproc) bzImage`.
- Stale root-owned build artifacts had to be removed before the successful
  build:
  - `/Serverless/Migration-friendly/linux/init/version.o`
  - `/Serverless/Migration-friendly/linux/init/.version.o.d`

Current build artifacts:

- Kernel image:
  `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`
- Kernel seen in current runs:
  `6.18.0modified #159`
- Fresh initrd used for fast-scan experiments:
  `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-fastscan-20260509.img`
- That initrd is root-owned and mode `0600`, but it was used successfully by
  the current QEMU experiments.

No long-running QEMU experiment was intentionally left active at handoff.

## Current Workload Shape

Main friendly moving-hotset candidate added/used in this session:

```text
skew_lf_hotremote_4g_move_60s_remoteonly_mulshift_persistent
```

Definition summary:

- candidate kind: friendly
- arena/RSS: 64 GiB
- hotset/window size: 4 GiB
- hotset placement before measurement: remote node
- possible moving-window offsets: 16 GiB through 60 GiB, step 4 GiB
- move policy: random
- move interval: 60 seconds
- access pattern: read-only skewed hotset, `mulshift` index mode
- threads: 32
- important placement detail: this is remote-window first-touch, not global
  remote-first-touch. The benchmark resets VMA policy after prefaulting the
  hot window.

Guest runner case location:

- `/Serverless/Migration-friendly/scripts/kernel/run_phase_candidate_microbench_guest.sh`

The older remote-only phase experiments also used this conceptual pair:

- friendly: moving 4 GiB remote hot window;
- unfriendly: 32 GiB streaming / 4 KiB stride style, with split or remote-only
  placement depending on the specific experiment.

## Important Prior Results

### Moving 60s, Fast Scan, 5s Promotion Samples

Experiment directory:

```text
/Serverless/iccd/experiments/20260509-move60-fastscan-on-5s-promotion
```

Run:

```text
run_id=20260509T082855Z-move60-fastscan-on5s
candidate=skew_lf_hotremote_4g_move_60s_remoteonly_mulshift_persistent
policy=on
NUMA_FAST_SCAN=1
NUMA_SCAN_SIZE_MB=4096
scan_period_min_ms=1000 implicit default
LIVE_SAMPLE_SEC=5
duration=120s
kernel=6.18.0modified #159
MGLRU=0x0007
```

Overall:

| metric | value |
| --- | ---: |
| promotions | 2,098,610 pages |
| promoted GiB | 8.01 |
| demotions | 2,166,539 pages |
| demoted GiB | 8.26 |
| hint faults | 4,988,863 |
| mean throughput | 1123.3 Mops/s |
| median throughput | 1255.9 Mops/s |

Window totals:

| window | offset | promote GiB | hint faults | demote pages |
| --- | ---: | ---: | ---: | ---: |
| window1 | 16 GiB | 2.86 | 1,840,714 | 854,382 |
| window2 | 20 GiB | 4.99 | 3,037,014 | 1,312,157 |
| post | 44 GiB | 0.16 | 45,583 | 0 |

Summary files:

- `/Serverless/iccd/experiments/20260509-move60-fastscan-on-5s-promotion/summaries/promotion_5s.md`
- `/Serverless/iccd/experiments/20260509-move60-fastscan-on-5s-promotion/summaries/promotion_5s.csv`

### Moving 60s, Period Compare: 1000ms vs 250ms

Experiment directory:

```text
/Serverless/iccd/experiments/20260509-move60-period-compare-5s-promotion
```

Both runs used:

```text
candidate=skew_lf_hotremote_4g_move_60s_remoteonly_mulshift_persistent
policy=on
NUMA_FAST_SCAN=1
NUMA_SCAN_SIZE_MB=4096
LIVE_SAMPLE_SEC=5
duration=120s
kernel=6.18.0modified #159
MGLRU=0x0007
```

The 1000 ms case reuses the run from
`20260509-move60-fastscan-on-5s-promotion`.

Overall comparison:

| case | period_min_ms | promotions | promote GiB | demotions | demote GiB | hint faults | mean Mops/s | median Mops/s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1000ms-default | 1000 | 2,098,610 | 8.01 | 2,166,539 | 8.26 | 4,988,863 | 1123.3 | 1255.9 |
| 250ms | 250 | 2,106,145 | 8.03 | 1,894,166 | 7.23 | 5,746,264 | 1380.1 | 1800.8 |

Window follow-speed comparison:

| case | window | offset | promote GiB | hint faults | demote GiB | first promo | promo 1GiB | promo 2GiB | promo 4GiB | 1000 Mops | 1500 Mops |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1000ms-default | window1 | 16 GiB | 2.86 | 1,840,714 | 3.26 | 15.2s | 15.2s | 40.3s | NA | 25.2s | 50.4s |
| 1000ms-default | window2 | 20 GiB | 4.99 | 3,037,014 | 5.01 | 5.4s | 10.4s | 25.6s | 50.7s | 35.6s | 35.6s |
| 250ms | window1 | 16 GiB | 4.00 | 2,377,522 | 3.32 | 5.1s | 5.1s | 20.2s | 40.3s | 5.1s | 5.1s |
| 250ms | window2 | 20 GiB | 3.34 | 2,773,738 | 3.19 | 30.6s | 30.6s | 55.8s | NA | 40.6s | 40.6s |

Interpretation:

- In window1, `scan_period_min_ms=250` clearly followed the moving hotset
  faster than the 1000 ms default:
  first promotion 5.1s vs 15.2s, 1 GiB at 5.1s vs 15.2s, and 2 GiB at 20.2s
  vs 40.3s.
- The 250 ms run had better overall mean and median throughput, similar total
  promotion, and less total demotion.
- Window2 did not follow faster in the single 250 ms run. It had first
  promotion at 30.6s vs 5.4s for the 1000 ms run. Treat this as unresolved
  until repeated with multiple seeds or fixed offsets.

Summary files:

- `/Serverless/iccd/experiments/20260509-move60-period-compare-5s-promotion/summaries/period_compare.md`
- `/Serverless/iccd/experiments/20260509-move60-period-compare-5s-promotion/summaries/period_compare_5s.csv`
- `/Serverless/iccd/experiments/20260509-move60-period-compare-5s-promotion/summaries/period_compare_window_totals.csv`

## Older Results Still Useful For Context

Friendly-only moving 60s, remote-only before fast-scan cleanup:

| policy | experiment | mean | median | promotions | demotions | hint faults |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| on | `/Serverless/iccd/experiments/20260509-friendly-move60s-remoteonly-on` | 1289.93 Mops/s | 1799.36 Mops/s | 2,100,132 pages / 8.01 GiB | 1,754,430 pages / 6.69 GiB | 4,696,404 |
| off | `/Serverless/iccd/experiments/20260509-friendly-move60s-remoteonly-off` | 228.22 Mops/s | 228.26 Mops/s | 0 | 0 | near 0 |

Two-phase 120s baseline plus early-stop diagnostic:

```text
/Serverless/iccd/experiments/20260509-remoteonly-phase2-120s-baseline-earlystop
```

| policy | friendly mean | unfriendly mean | notes |
| --- | ---: | ---: | --- |
| off | 228.58 Mops/s | 4513.00 MB/s | no migration |
| on | 272.19 Mops/s | 2197.60 MB/s | promoted 15.43 GiB, demoted 14.33 GiB, 23.84M hints |
| adaptive | 269.67 Mops/s | 4199.70 MB/s | promoted 6.97 GiB, demoted 6.66 GiB, 13.88M hints |
| earlystop(on) | 258.93 Mops/s | 2320.15 MB/s | stopped about 49.7s into P1, restarted about 5.15s into P2 |

Six-phase 200s remote-only on/off/adaptive:

```text
/Serverless/iccd/experiments/20260509-remoteonly-scan4096-phase200-timeout1500-onoff-adaptive
```

Mean phase results:

| policy | P1 friendly | P2 unfriendly | P3 friendly | P4 unfriendly | P5 friendly | P6 unfriendly |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| off | ~228 | ~4519 | ~228 | ~4519 | ~228 | ~4519 |
| on | 271.48 | 2280.98 | 691.58 | 3022.21 | 736.38 | 3354.95 |
| adaptive | 274.69 | 3932.91 | 439.58 | 4210.88 | 742.07 | 2522.70 |

Interpretation at the time:

- Adaptive reduced hint faults relative to always-on migration.
- The low adaptive P6 result likely came from inherited placement from P5 while
  migration was disabled, rather than from ongoing fault volume.
- This is still not fully resolved.

## Key Technical Conclusions So Far

- `task_scan_min()` with `NUMA_SCAN_SIZE_MB=4096` and the normal
  `MAX_SCAN_WINDOW` floor can prevent scan-period changes from taking effect
  as expected.
- Fast scan is intended to make existing scan-period tuning visible, not to
  replace the scan-period knob.
- Lowering `scan_period_min_ms` without `NUMA_FAST_SCAN=1` is not expected to
  bypass the normal floor.
- `mm->numa_next_scan` should not be changed to a 1-tick interval by default;
  it serializes scanners per mm and avoids redundant concurrent scans.
- The single 250 ms period run supports the idea that faster scanning can
  follow a moving hotset faster, but only window1 showed the expected behavior
  cleanly. Window2 needs repeat runs.
- Promotion and candidate counts are event volumes, not unique hotset coverage.
  With a large scan size, the same page can be scanned and counted repeatedly.

## Suggested Next Steps

- Repeat the moving-60s period comparison with fixed offsets or multiple seeds
  before making a strong claim about 250 ms vs 1000 ms follow speed.
- Clean legacy `scan_period_scale` naming in `bench_V2` so the scripts and
  reports match the new boolean fast-scan model.
- Update the `migration-friendly-kernel` skill or workload catalog if this
  fast-scan design becomes the stable workflow; the current skill text still
  contains stale `SCAN_PERIOD_SCALE` guidance.
- If preparing a commit, stage only the intended fast-scan and runner changes.
  The repository has many unrelated untracked artifacts and older local files.
