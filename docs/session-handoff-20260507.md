# Migration-Friendly Session Handoff

Date: 2026-05-07 UTC

This document summarizes the current state so a new Codex session can resume
without relying on chat scrollback.

## Read First

- Use the `migration-friendly-kernel` skill.
- Active project: `/Serverless/Migration-friendly`.
- Active kernel: `/Serverless/Migration-friendly/linux`.
- Retired kernel: `/Serverless/iccd/linux`; do not use it unless explicitly
  asked for historical comparison.
- Current workload catalog:
  `/Serverless/iccd/docs/current-migration-workloads-20260507.md`.
- Re-read the current workload catalog before every new experiment and include
  its VM/build/reporting checklist in the final result summary.
- New experiment outputs must go under
  `/Serverless/iccd/experiments/<experiment-name>/`.

## Canonical VM And Experiment Settings

- VM CPU: `CPUS=32`, `HOST_CPUS=0-31`, guest node0 CPUs `0-31`.
- Fast memory: guest node0 32G, bound to host node0 DRAM with
  `NUMA_NODE0_HOST_NODES=0`.
- Slow memory: guest node1 64G, bound to host node2 CXL with
  `NUMA_NODE1_HOST_NODES=2`.
- QEMU memory binding: `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1`.
- cgroup node0 local cap: 16G, `CAPACITY_PAGES=4194304`.
- Arena/RSS: usually `ARENA_SIZE=64G`.
- Threads: `THREADS=32`.
- Migration on policy: `GLOBAL_NUMA_ON=0`, cgroup `NODE_BALANCING_ON=2`.
- Demotion should remain enabled for cap control:
  `KSWAPD_DEMOTION_ON=1`, `OFF_DEMOTION_ON=1`.
- Scan tuning: `NUMA_SCAN_SIZE_MB=256`, `SCAN_PERIOD_SCALE=1`.
- Do not force the cgroup hot threshold. Use `HOT_THRESHOLD_MS=0`, which means
  inherit Linux default `sysctl_numa_balancing_hot_threshold=1000ms`.
- Current requested placement mode: local-first-touch before measurement. For
  friendly validation, first-touch only the hotset/window on remote node1 and
  leave the rest as normal local-first-touch; report initial node0/node1
  residency from `memory.numa_stat.before.txt` and `live.csv`.
- Build kernels with `make -C /Serverless/Migration-friendly/linux -j$(nproc)
  bzImage`.
- Kernel-related builds, including `bzImage`, `modules`, and initrd rebuilds,
  must use all available CPUs, for example `-j$(nproc)` or
  `BUILD_JOBS=$(nproc)`.
- For VM experiments after kernel changes, build and pass a fresh initrd
  explicitly with `KERNEL_IMAGE=/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`
  and the matching `INITRD_IMAGE`. Do not rely on the wrapper fallback to
  `/boot/vmlinuz-*` or `/boot/initrd.img-*`.
- Every experiment result summary must restate the kernel/initrd, KVM status,
  VM node bindings, cgroup cap, migration/demotion knobs, scan tuning, workload
  candidate, on/off throughput, promoted pages/GiB, and demoted pages/GiB.
  Demotion should be reported as `pgdemote_direct + pgdemote_kswapd` when both
  counters are available.
- When MGLRU is part of the question, record both kernel config
  (`CONFIG_LRU_GEN*`) and guest runtime state
  `/sys/kernel/mm/lru_gen/enabled` in the result.

Results without host node0/node2 memory binding are invalid for local-vs-CXL
interpretation.

## Current Workload Labels

- Friendly: `mulshift-hotset-4g-fixed`.
  - Implemented in phase runner candidate `phase_mulshift4g_sparse64`.
  - 4G fixed hotset at offset 60G, read-only, `mulshift`, persistent workers.
  - Hotset is below the 16G local cap, so migration should help.
- Unfriendly candidate: `sparse_stride_read_64g_block2m_remoteft`.
  - Standalone runner candidate.
  - 64G sparse read, `--bw-stride 512`, `--bw-block 2M`, fixed,
    remote-firsttouch.
  - Earlier larger-scan runs showed migration hurting it, but the latest
    required `NUMA_SCAN_SIZE_MB=256` VM validation did not confirm it as
    unfriendly.
- Avoid old labels:
  - `sparse_stride_read_64g_remoteft` used 4KiB block sparse and was much
    weaker.
  - The built-in sparse phase of `phase_mulshift4g_sparse64` is also the old
    4KiB-block sparse shape.
  - For future alternating experiments, use or create an explicit preset like
    `phase_mulshift4g_block2m_sparse64`.

## Main Results So Far

### Unfriendly Remote-Firsttouch Rerun After Balanced-Accounting Fix

Experiment:
`/Serverless/iccd/experiments/20260507-unfriendly-remoteft-onoff-balancedfix-256scan-initrd/summaries/analysis.md`

- Candidate: `sparse_stride_read_64g_block2m_remoteft`.
- Policies: `off,on`, one repetition each.
- Kernel/initrd:
  `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage` and
  `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260507T171412Z-unfriendly.img`.
- The initrd was freshly built for this run; launcher reported
  `build initrd: enabled (jobs=64, strip=1, hostonly=0)`.
- Guest kernel: `Linux kernel 6.18.0modified #121 SMP PREEMPT_DYNAMIC Thu May 7 16:47:15 UTC 2026`.
- VM topology matched the canonical settings: KVM, `CPUS=32`, `MEMORY=96G`,
  `HOST_CPUS=0-31`, node0 `32G` on host node0, node1 `64G` on host node2 CXL,
  `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1`.
- Scan and policy knobs: `NUMA_SCAN_SIZE_MB=256`, `SCAN_PERIOD_SCALE=1`,
  `HOT_THRESHOLD_MS=0`, `GLOBAL_NUMA_ON=0`, `NODE_BALANCING_ON=2`,
  `KSWAPD_DEMOTION_ON=1`, `OFF_DEMOTION_ON=1`.
- Guest runtime confirmed MGLRU: `lru_gen_enabled=0x0007`.
- Placement: remote-firsttouch; initial anon residency was `0.00 GiB` on
  node0 and about `62.37-62.38 GiB` on node1.
- OFF result: mean `407.79 MiB/s`, median `408.00 MiB/s`, promoted `0`
  pages, demoted `0` pages.
- ON result: mean `1077.16 MiB/s`, median `1104.00 MiB/s`, promoted
  `3,718,762` pages (`14.19 GiB`), demoted `356,984` pages (`1.36 GiB`).
- Full-run mean on/off was `2.641x`; last-10s on/off was about `1.92x`.
- Interpretation: this candidate is still not validated as unfriendly under
  the current 256 MiB scan setup. Migration on improves throughput materially,
  despite some churn (`numa_demote_promoted=351,441` pages).

### FRIENDLY Hotset-Remote On/Off After Balanced-Accounting Fix

Experiment:
`/Serverless/iccd/experiments/20260507-friendly-hotremote-onoff-balancedfix-256scan-initrd/summaries/analysis.md`

- Candidate: `skew_lf_hotremote_4g_fixed_rss16g_mulshift_persistent`.
- Policies: `off,on`, one repetition each.
- Kernel/initrd:
  `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage` and
  `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260507T164413Z-promotion-debug.img`.
- Guest kernel: `Linux kernel 6.18.0modified #121 SMP PREEMPT_DYNAMIC Thu May 7 16:47:15 UTC 2026`.
- VM topology matched the canonical settings: KVM, `CPUS=32`, `MEMORY=96G`,
  `HOST_CPUS=0-31`, node0 `32G` on host node0, node1 `64G` on host node2 CXL,
  `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1`.
- Scan and policy knobs: `NUMA_SCAN_SIZE_MB=256`, `SCAN_PERIOD_SCALE=1`,
  `HOT_THRESHOLD_MS=0`, `GLOBAL_NUMA_ON=0`, `NODE_BALANCING_ON=2`,
  `KSWAPD_DEMOTION_ON=1`, `OFF_DEMOTION_ON=1`.
- Guest runtime confirmed MGLRU: `lru_gen_enabled=0x0007`.
- Placement: local-first-touch arena with only the friendly 4 GiB hotset/window
  first-touched on remote node1. Initial anon residency was about `15.4-15.6
  GiB` on node0 and `48.4-48.6 GiB` on node1.
- OFF result: mean `619.66 Mops/s`, median `620.82 Mops/s`, promoted `0`
  pages, demoted `123,648` pages (`0.47 GiB`).
- ON result: mean `1441.81 Mops/s`, median `613.00 Mops/s`, promoted
  `1,048,575` pages (`4.00 GiB`), demoted `1,020,225` pages (`3.89 GiB`).
- Full-run mean on/off was `2.327x`; last-10s on/off was about `4.98x`.
  The full-run median is misleading because the on run spends roughly the
  first half of the measurement while promotion is still ramping.
- Interpretation: FRIENDLY is now confirmed after the reclaimd balanced
  accounting fix. The remaining `443,762` over-high failures occur after the
  useful 4 GiB hotset has already been promoted; `debug_promote_rate_limited=0`.

### Local-First-Touch Plus Friendly Hotset-Remote

Experiment:
`/Serverless/iccd/experiments/20260507-localft-hotremote-firsttouch-nosettle-onoff-256scan-initrd/summaries/analysis.md`

- Added mbench option `--hotset-prefault-node N`: first-touch the hotset/window
  on node `N`, reset thread mempolicy to default, then first-touch the remaining
  arena normally. This avoids persistent `mbind` policy.
- Prefault settle was disabled with `PREFAULT_SETTLE_RECLAIMD=0`; otherwise
  the run waits forever because node0 intentionally starts at the high
  watermark.
- Initial residency confirmed local-first-touch: all cases started with about
  `15.2-15.7 GiB` on node0 and about `48 GiB` on node1.
- Friendly hotset-remote candidate
  `skew_lf_hotremote_4g_fixed_rss16g_mulshift_persistent`: on/off `0.996x`
  (`-0.4%`), promoted `12` pages, demoted `72,960` pages (`0.28 GiB`).
- Unfriendly local-first-touch candidate `sparse_stride_read_64g_block2m_localft`:
  on/off `1.115x` (`+11.5%`), promoted `125,772` pages (`0.48 GiB`),
  demoted `41,376` pages (`0.16 GiB`).

Interpretation: node0-full start removes the large remote-firsttouch promotion
upside. A later temporary hook rerun showed the earlier stale-scan/candidate
absence explanation was wrong for the current kernel path. The hotset does
become a promotion candidate, but actual promotion is blocked afterward by
node0 headroom/over-high checks.

### Friendly Hotset-Remote Hook Diagnostic

Experiment:
`/Serverless/iccd/experiments/20260507-friendly-hotremote-hook-on-256scan-initrd/summaries/analysis.md`

- Candidate: `skew_lf_hotremote_4g_fixed_rss16g_mulshift_persistent`.
- Policy: migration on.
- Kernel/initrd used for the diagnostic hook:
  `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage` and
  `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260507T144157Z-hook.img`.
- VM topology matched the canonical settings: KVM, `CPUS=32`, `MEMORY=96G`,
  `HOST_CPUS=0-31`, node0 `32G` on host node0, node1 `64G` on host node2 CXL,
  `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1`.
- Scan and policy knobs: `NUMA_SCAN_SIZE_MB=256`, `SCAN_PERIOD_SCALE=1`,
  `HOT_THRESHOLD_MS=0`, `GLOBAL_NUMA_ON=0`, `NODE_BALANCING_ON=2`, demotion on.
- Placement: local-first-touch arena with hotset-only remote placement.
- Result: `649.59 Mops/s`, promoted `0` pages / `0.00 GiB`, demoted `0` pages
  / `0.00 GiB`.
- Hook counters: `14,620,875` hint faults,
  `numa_dbg_target_candidate=13,572,297`,
  `numa_dbg_latency_pass=13,572,297`,
  `numa_dbg_rate_pass=13,572,297`,
  `vmstat.pgpromote_candidate=13,571,172`.
- The actual block was after candidacy:
  `numa_migrate_fail_promotion_over_high=13,572,297`,
  `numa_migrate_success_promotion=0`, `vmstat.pgpromote_success=0`,
  `vmstat.pgmigrate_fail=0`.
- Root cause for this run: node0 stayed near `4,110,417` pages, but redirect
  headroom requires usage at or below `3,932,160` pages
  (`CAPACITY_PAGES=4,194,304`, reserve `262,144` pages). Destination folio
  allocation on node0 is rejected by the promotion over-high gate.
- The temporary hook was removed after the experiment. A clean no-hook kernel
  was rebuilt with all CPUs and a fresh no-hook initrd was created:
  `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260507T145532Z-nohook.img`.

### MGLRU-On Reclaimd Rerun

Experiment:
`/Serverless/iccd/experiments/20260507-friendly-hotremote-mglru-on-256scan-initrd/summaries/analysis.md`

- This run corrected a prior misinterpretation: the requested change was to
  enable VM kernel Multi-gen LRU, not to force `PF_KSWAPD`.
- The temporary `memcg_reclaimd()` PF_KSWAPD change was reverted before this
  build. `memcg_reclaimd()` is back to `PF_MEMALLOC` only.
- Kernel config now has:
  `CONFIG_LRU_GEN=y`, `CONFIG_LRU_GEN_ENABLED=y`,
  `CONFIG_LRU_GEN_STATS=y`, `CONFIG_LRU_GEN_WALKS_MMU=y`.
- Kernel/initrd:
  `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage` and
  `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260507T152933Z-mglru.img`.
- Kernel was built with all CPUs: `-j$(nproc)`, `nproc=64`; resulting kernel
  was `6.18.0modified #113`.
- VM topology and knobs matched the canonical settings: KVM, `CPUS=32`,
  `MEMORY=96G`, `HOST_CPUS=0-31`, node0 `32G` on host node0, node1 `64G` on
  host node2 CXL, `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1`,
  `NUMA_SCAN_SIZE_MB=256`, `SCAN_PERIOD_SCALE=1`, `HOT_THRESHOLD_MS=0`,
  `GLOBAL_NUMA_ON=0`, `NODE_BALANCING_ON=2`, demotion on.
- Guest runtime confirmed MGLRU: `lru_gen_enabled=0x0007`,
  `lru_gen_min_ttl_ms=0`.
- Workload: `skew_lf_hotremote_4g_fixed_rss16g_mulshift_persistent`, migration
  `on`, local-first-touch arena with hotset-only remote placement.
- Initial residency after prefault: node0 `15.680 GiB`, node1 `48.320 GiB`;
  node0 usage was exactly the high watermark (`4,110,417` pages).
- Result: `620.16 Mops/s`, promoted `0` pages, demoted `0` pages. Reclaimd
  woke and ran (`wake_count=1`, `run_count=1`) but `pgscan_direct=0`,
  `pgscan_kswapd=0`, `pgsteal_direct=0`, `pgsteal_kswapd=0`.
- Promotion candidates still formed: `8,408,803` candidates, all rejected by
  `numa_migrate_fail_promotion_over_high`.
- Interpretation: enabling MGLRU alone did not create node0 headroom. With
  MGLRU on and PF_KSWAPD off, reclaimd wakes but does not demote in this
  workload.

### Reclaimd/MGLRU Plus Promotion EAGAIN Retry

Experiment:
`/Serverless/iccd/experiments/20260507-friendly-hotremote-reclaimd-eagain-256scan-initrd/summaries/analysis.md`

- Kernel/initrd were rebuilt fresh from `/Serverless/Migration-friendly/linux`.
- Kernel: `Linux kernel 6.18.0modified #115 SMP PREEMPT_DYNAMIC Thu May  7 16:05:12 UTC 2026`.
- Initrd:
  `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260507T160220Z-reclaimd-eagain.img`.
- Build used all CPUs: launcher `--build-initrd` reported `jobs=64`; host
  `nproc=64`.
- VM topology and knobs matched the canonical settings: KVM, `CPUS=32`,
  `MEMORY=96G`, `HOST_CPUS=0-31`, node0 `32G` on host node0, node1 `64G` on
  host node2 CXL, `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1`,
  `NUMA_SCAN_SIZE_MB=256`, `SCAN_PERIOD_SCALE=1`, `HOT_THRESHOLD_MS=0`,
  `GLOBAL_NUMA_ON=0`, `NODE_BALANCING_ON=2`, demotion on.
- Guest runtime confirmed MGLRU: `lru_gen_enabled=0x0007`,
  `lru_gen_min_ttl_ms=0`.
- Workload: `skew_lf_hotremote_4g_fixed_rss16g_mulshift_persistent`, migration
  `on`, local-first-touch arena with hotset-only remote placement.
- Initial residency after prefault: node0 `15.680 GiB`, node1 `48.321 GiB`;
  node0 usage was exactly the high watermark (`4,110,417` pages).
- Result: mean `317.41 Mops/s`, median `563.68 Mops/s`, promoted `0` pages,
  demoted `0` pages. Reclaimd woke and ran (`wake_count=1`, `run_count=1`) but
  `pgscan_direct=0`, `pgscan_kswapd=0`, `pgsteal_direct=0`,
  `pgsteal_kswapd=0`.
- Promotion candidates formed: `10,969,306` candidates, with `10,969,272`
  over-high rejects. The new `-EAGAIN` retry path is visible because these
  failures now also show as `pgmigrate_fail=10,969,272`.
- Interpretation: the retry patch fixed/brought back migration failure
  accounting for over-high promotion attempts, but it did not create node0
  headroom. Promotion is still blocked by reclaimd failing to scan/steal/demote
  under MGLRU with PF_KSWAPD off.

### PF_KSWAPD Diagnostic Rerun

Experiment:
`/Serverless/iccd/experiments/20260507-friendly-hotremote-pfkswapd-on-256scan-initrd/summaries/analysis.md`

- This was an accidental diagnostic run from misreading "turn it back on" as
  PF_KSWAPD rather than VM kernel MGLRU. Do not treat this as the requested
  MGLRU result.
- `memcg_reclaimd()` was temporarily changed to set `PF_KSWAPD` while it ran,
  restoring vmscan paths guarded by `current_is_kswapd()`. That change has now
  been reverted.
- Kernel/initrd: `#112` with
  `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260507T151455Z-memcgpfkswapd.img`.
- Same canonical VM topology and friendly hotset-remote placement.
- Demotion was restored. During prefault, `pgdemote_kswapd` rose by about
  `7.46M` pages, about `28.5 GiB`, and node0 reached below high before
  measurement.
- During the measured window, cgroup `pgdemote_kswapd` rose by `68,016` pages
  (`0.259 GiB`), promotion over-high failures stayed `0`, but promotion success
  was still only `13` pages.
- Interpretation from the diagnostic only: the PF_KSWAPD-equivalent path can
  make reclaimd demotion visible and effective, but this is not the current
  requested kernel state.

### 256MB-Scan VM On/Off Validation

Experiment:
`/Serverless/iccd/experiments/20260507-friendly-unfriendly-onoff-256scan-initrd/summaries/analysis.md`

- Kernel/initrd were rebuilt fresh from `/Serverless/Migration-friendly/linux`.
- Build used all CPUs: `-j$(nproc)`, with `nproc=64`.
- VM used KVM, `CPUS=32`, `MEMORY=96G`, `HOST_CPUS=0-31`,
  node0 `32G` bound to host node0, node1 `64G` bound to host node2,
  `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1`.
- Scan tuning: `NUMA_SCAN_SIZE_MB=256`, `SCAN_PERIOD_SCALE=1`,
  `HOT_THRESHOLD_MS=0`.
- Friendly standalone candidate
  `skew_rf_read_4g_fixed_rss16g_mulshift_persistent`: on/off `2.189x`
  (`+118.9%`), promoted `680,641` pages (`2.60 GiB`), demoted `0`.
- Unfriendly candidate `sparse_stride_read_64g_block2m_remoteft`: on/off
  `3.478x` (`+247.8%`), promoted `3,882,738` pages (`14.81 GiB`), demoted
  `137,375` pages (`0.52 GiB`, direct + kswapd).

Interpretation: friendly is confirmed under the new 256MB scan setting; the
previous unfriendly candidate is not confirmed and should be rerun with more
reps or replaced before using it as the negative case.

### Strong Unfriendly Standalone

Experiment:
`/Serverless/iccd/experiments/20260507-unfriendly-block2m-deep-bound-cxl/summaries/analysis.md`

- Candidate: `sparse_stride_read_64g_block2m_remoteft`.
- 60s measured run, 3 reps, remote prefault excluded.
- off: mean `392.17 MB/s`.
- on: mean `128.72 MB/s`.
- on/off: `0.328x` (`-67.2%`).
- on promoted about `18.72 GiB`, with about `29.5M` hint faults.

Interpretation: this was the strongest unfriendly case before switching the
default scan size to 256MB. Do not assume it remains unfriendly under the new
default without rerunning or using the validation result above.

### 6-Phase Friendly/Unfriendly

Experiment:
`/Serverless/iccd/experiments/20260507-phase-mulshift4g-block2m-sparse64-local-refault/summaries/analysis.md`

- Phases 1/3/5: friendly `mulshift-hotset-4g-fixed`.
- Phases 2/4/6: unfriendly `sparse-stride-read-64g-block2m`.
- Policies: `off`, `on`, `adaptive_cgroup`.
- `adaptive_cgroup`: cgroup NUMA balancing `2` for friendly phases and `0` for
  sparse phases; global NUMA balancing remains `0`.

Aggregate from that run:

| policy | kind | mean Mops/s | mean MB/s | promoted GiB | hint faults |
| --- | --- | ---: | ---: | ---: | ---: |
| off | friendly | 403.08 | 25797.3 | 0.00 | 0.0M |
| off | unfriendly | 32.70 | 261.6 | 0.00 | 0.0M |
| on | friendly | 2863.22 | 183245.9 | 4.02 | 5.6M |
| on | unfriendly | 50.23 | 401.9 | 4.49 | 29.7M |
| adaptive | friendly | 3647.40 | 233433.3 | 4.08 | 1.2M |
| adaptive | unfriendly | 42.75 | 342.0 | 0.00 | 0.0M |

Note: this result predates the latest promotion watermark/headroom diagnostic.
Rerun it after the next headroom fix, using the clean no-hook kernel/initrd or
newer.

### Demotion Accounting Debug

Experiment:
`/Serverless/iccd/experiments/20260507-demotion-debug-hook-block2m/notes/demotion-debug-summary.md`

Historical conclusion before the PF_KSWAPD reclaimd rerun:

- `memcg_reclaimd` demotion is happening.
- It is accounted as `pgdemote_direct`, not `pgdemote_kswapd`.
- Reason: `memcg_reclaimd()` sets `PF_MEMALLOC` but not `PF_KSWAPD`;
  `vmscan.c::reclaimer_offset()` reports kswapd only when
  `current_is_kswapd()` is true.
- Do not use `pgdemote_kswapd` alone to decide whether cgroup demotion ran.
  Use `pgdemote_direct + pgdemote_kswapd`, or add a dedicated reclaimd stat.

Temporary debug hooks were removed. Clean kernels were rebuilt afterward.
The later PF_KSWAPD reclaimd run changed this accounting: reclaimd demotion is
now visible as `pgdemote_kswapd`.

### Sparse64 On/Off Demotion Check

Experiment:
`/Serverless/iccd/experiments/20260507-sparse64-onoff-demotion-check/summaries/sparse64-onoff-demotion.md`

- Kernel: `#107`.
- Workload: `sparse_stride_read_64g_block2m_remoteft`.
- 50s measured after remote-firsttouch prefault.
- off: `417.82 MB/s`, promote `0`, demote `0`.
- on: `1725.43 MB/s`, promote `14.89 GiB`, demote direct `0.86 GiB`,
  hint faults `202805231`, reclaimd wake/run `1/1`.
- This run mostly measured cold local fill after prefault, so do not treat it
  as steady-state unfriendly evidence.

## Kernel State

Current git baseline commits near HEAD:

- `49dd7d882 Normalize memcg demotion mode to node watermark`
- `7f4b5ff22 mm/memcg: add NUMA migration stop knobs`
- `414484131 mm/memcg: stop pingpong NUMA migrations`
- `8e90bc17b mm/memcg: sample promotion refaults`
- `fb560591e sched/numa: add cgroup-scoped reuse-time recorder`

Important existing features in the active kernel:

- cgroup-scoped NUMA balancing mode, including memory tiering `0x2`.
- cgroup demotion mode normalized to node watermark behavior.
- migration stop knobs and pingpong mitigation.
- local promotion refault sampling stats.
- `memory.numa_migrate_state` includes
  `numa_promote_sampled_refault_total_ms`.
- `HOT_THRESHOLD_MS=0` should be used by experiment scripts so cgroup inherits
  Linux default hot threshold. It was previously forced to `1ms`, which made
  older runs harder to interpret.

## Latest Code Change In This Session

User wanted cgroup promotion headroom to mimic Linux memory tiering more
closely:

- Linux uses a free-space bypass:
  `usable_free > WMARK_PROMO + max(1GB, node_present_pages / 16)`.
- Because cgroup watermarks are usage-based, the equivalent bypass is:
  `projected_usage <= low_wmark - reserve`.
- Reserve should be `max(1GB, capacity / 16)`.
- Hard rejection should not reuse the reserve threshold. It should wake
  reclaimd and reject only when projected usage exceeds the high watermark.

Implemented target and current diagnostic:

- `/Serverless/Migration-friendly/linux/mm/memcontrol.c`
  - replaced 64MB promotion reserve with
    `max(1GB, node_capacity / 16)`.
  - changed `mem_cgroup_node_promotion_wmark_ok()` to return true only for
    `projected_usage <= low_wmark - reserve`.
  - removed the old `mem_cgroup_node_promotion_blocked()` path that used
    `high - reserve` as a hard block.
- `/Serverless/Migration-friendly/linux/mm/migrate.c`
  - promotion prepare path now checks `mem_cgroup_node_over_high()`;
    if true, it wakes `memcg_reclaimd` and returns `-EAGAIN`.
  - allocation callback keeps a race guard: if cgroup high is exceeded by the
    time allocation is attempted, it wakes reclaimd and fails the allocation.
- `/Serverless/Migration-friendly/linux/include/linux/memcontrol.h`
  - removed the obsolete `mem_cgroup_node_promotion_blocked()` declaration and
    stub.
- Temporary hook VM run showed the current implementation still rejects actual
  promotion allocation through `mem_cgroup_node_over_high()` once
  `memcg_watermark_reclaim_enabled()` routes to
  `memcg_node_redirect_has_headroom()`. In the friendly hotset-remote run,
  this produced `13,572,297` `numa_migrate_fail_promotion_over_high` events
  and zero successful promotions.

Intended behavior still to preserve when fixing the headroom gate:

```text
usage <= low - max(1GB, cap/16):
  bypass hot threshold, like Linux pgdat_free_space_enough()

low - reserve < usage <= high:
  promotion can still happen through hot-threshold/rate-limit path

usage + nr_pages > high:
  wake memcg_reclaimd and return -EAGAIN
```

Build result:

- Command shape used for kernel builds:
  `make -C /Serverless/Migration-friendly/linux -j$(nproc) bzImage modules`.
- The temporary hook diagnostic kernel built as `#110`.
- After the hook run, hook code was removed and the clean no-hook kernel rebuilt
  as `#111`.
- Clean no-hook initrd:
  `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260507T145532Z-nohook.img`.
- PF_KSWAPD reclaimd test kernel built as `#112`; fresh initrd:
  `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260507T151455Z-memcgpfkswapd.img`.
- Corrected MGLRU-on kernel built as `#113`; fresh initrd:
  `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260507T152933Z-mglru.img`.
- Reclaimd/MGLRU plus promotion `-EAGAIN` retry kernel built as `#115`; fresh
  initrd:
  `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260507T160220Z-reclaimd-eagain.img`.
- Reclaimd/MGLRU balanced-accounting debug kernel built as `#121`; fresh
  initrd:
  `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260507T164413Z-promotion-debug.img`.

## Latest Reclaimd/MGLRU Debug Result

Experiment:
`/Serverless/iccd/experiments/20260507-friendly-hotremote-promotion-debug-hook-256scan-initrd/summaries/analysis.md`

- Workload: `skew_lf_hotremote_4g_fixed_rss16g_mulshift_persistent`, policy
  `on`, local-first-touch baseline with hotset-only remote first-touch.
- VM: `MEMORY=96G`, `CPUS=32`, `HOST_CPUS=0-31`, guest node0 32G on host node0,
  guest node1 64G on host node2 CXL, `NUMA_PREALLOC=1`.
- Runtime: MGLRU `0x0007`, `NUMA_SCAN_SIZE_MB=256`, `HOT_THRESHOLD_MS=0`.
- Result: promoted `1,048,570` pages (`4.00 GiB`), demoted `1,074,048` pages
  (`4.10 GiB`), throughput mean `989.29 Mops/s`, median `603.85 Mops/s`.
- Reclaimd path is alive under MGLRU/PF_KSWAPD-off:
  `debug_kswapd_shrink +9`, `debug_evict_calls +16,782`,
  `debug_evict_delta_pages +1,073,870`.
- Promotion gate debug:
  `debug_promote_enter=2,975,533`,
  `debug_promote_latency_pass=1,621,530`,
  `debug_promote_latency_fail=1,353,995`,
  `debug_promote_rate_limited=0`,
  `numa_migrate_fail_promotion_over_high=572,637`.
- Root cause of previous zero-demotion run: `pgdat_memcg_balanced()` and
  `kswapd_shrink_node()` sized memcg reclaim from legacy LRU-list accounting,
  which could report balanced under MGLRU while exact/live node usage was above
  the node watermark. Switching the node-wmark reclaim path to live node usage
  let reclaimd scan and demote.

## Latest Unfriendly Sweep Result

Experiment:
`/Serverless/iccd/experiments/20260507-unfriendly-localfixed-6h-sweep-256scan-initrd/summaries/analysis.md`

- Goal: search local-memory-fixed unfriendly candidates with broad access
  pattern, hotset/window size, fixed vs moving window, and movement interval
  combinations. Strong cutoff was on/off `<=0.8`; allowed cutoff was `<=0.9`.
- VM and knobs: fresh initrd
  `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260507T171412Z-unfriendly.img`,
  kernel image `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`,
  KVM enabled, `CPUS=32`, `MEMORY=96G`, `HOST_CPUS=0-31`, guest node0 32G on
  host node0, guest node1 64G on host node2 CXL, `NUMA_PREALLOC=1`,
  `CAPACITY_PAGES=4194304`, `NUMA_SCAN_SIZE_MB=256`, `HOT_THRESHOLD_MS=0`,
  MGLRU runtime `0x0007`.
- Placement: final candidates used local-first-touch (`remote_firsttouch=0`)
  under the fixed 16 GiB local cap, not remote-firsttouch.
- Broad smoke sweep: 43 candidates, `REPS=1`, 30 second windows. Strong hits
  were `sparse_stride_read_64g_block2m_localft` (`0.547x`),
  `sparse_stride_read_64g_block2m` (`0.602x`, duplicate runner args), and
  `sparse_stride_read_64g` (`0.760x`). `stream_triad_sweep_32g` was a weak
  hit at `0.844x`; `sparse_stride_write_64g` was a near miss at `0.905x`.
- Final 3-run validation, 60 second windows:
  `sparse_stride_read_64g_block2m_localft` is the primary unfriendly case:
  off `1978.71 +/- 14.49 MiB/s`, on `1121.61 +/- 5.44 MiB/s`, on/off
  `0.567 +/- 0.007`, on promoted `2,005,879` pages (`7.65 GiB`) and demoted
  `2,202,975` pages (`8.40 GiB`).
- Secondary unfriendly case: `sparse_stride_read_64g`, off
  `1667.92 +/- 17.04 MiB/s`, on `1194.97 +/- 11.79 MiB/s`, on/off
  `0.716 +/- 0.004`, on promoted `1,957,369` pages (`7.47 GiB`) and demoted
  `1,953,943` pages (`7.45 GiB`).
- Rejected near-miss: `stream_triad_sweep_32g` ended at on/off
  `0.906 +/- 0.019`, just above the allowed `0.9` cutoff.

## Latest Phase Full On/Off Result

Experiment:
`/Serverless/iccd/experiments/20260507-phase-overall-onoff-localft-256scan-initrd/summaries/analysis.md`

- Added local-first-touch runner label
  `phase_mulshift4g_block2m_sparse64_localft` because the older
  `phase_mulshift4g_block2m_sparse64` label still sets
  `CANDIDATE_REMOTE_FIRSTTOUCH=1`.
- Workload: `mulshift-hotset-4g-fixed` friendly phase alternating with
  `sparse-stride-read-64g-block2m` unfriendly phase. `PHASE_MS=60000`,
  `PHASE_REPEAT=3`, `REPS=1`, `POLICIES=off,on`.
- VM and knobs: fresh initrd
  `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260507T233548Z-phase-onoff.img`,
  kernel `#122`, KVM enabled, canonical 32 vCPU / 96G topology, node0 host
  node0, node1 host node2 CXL, `CAPACITY_PAGES=4194304`,
  `NUMA_SCAN_SIZE_MB=256`, `HOT_THRESHOLD_MS=0`, MGLRU runtime `0x0007`.
- Placement: local-first-touch, `remote_firsttouch=0`,
  `PREFAULT_PHASE_GATE=1`, `PREFAULT_SETTLE_RECLAIMD=0`. Initial anon
  residency after prefault was about `15.4-15.6 GiB` on node0 and
  `48.4-48.6 GiB` on node1.
- Full-policy result: overall on/off `2.109x`, off `595.43 Mops/s`, on
  `1255.80 Mops/s`; on promoted `5,377,548` pages (`20.51 GiB`) and demoted
  `5,462,850` pages (`20.84 GiB`).
- Phase split: friendly mean on/off `2.512x` (`941.63` to
  `2365.81 Mops/s`); unfriendly sparse block2M mean on/off `0.621x`
  (`253.49` to `157.53 Mops/s`).
- Interpretation: full migration-on wins overall because friendly phases
  dominate after promotion ramps, but the unfriendly phases are consistently
  slower under migration-on. Use this as the full-off/full-on baseline before
  testing adaptive/oracle phase policies.

## Latest Phase Miracle/Adaptive Result

Experiment:
`/Serverless/iccd/experiments/20260508-phase-miracle-adaptive-localft-256scan-initrd/summaries/analysis.md`

- Policy: `oracle_cgroup_global0`, interpreted as the miracle/adaptive
  baseline. Global NUMA balancing stays `0`; cgroup `node_balancing` is `2`
  for friendly phases and `0` for sparse phases.
- Workload: same `phase_mulshift4g_block2m_sparse64_localft` local-first-touch
  alternating phase candidate as the full-off/full-on baseline.
- VM and knobs: fresh initrd
  `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260508T000457Z-phase-miracle.img`,
  kernel `#122`, KVM enabled, canonical 32 vCPU / 96G topology, node0 host
  node0, node1 host node2 CXL, `CAPACITY_PAGES=4194304`,
  `NUMA_SCAN_SIZE_MB=256`, `HOT_THRESHOLD_MS=0`, MGLRU runtime `0x0007`.
- Initial anon residency after prefault: `15.45 GiB` on node0 and `48.55 GiB`
  on node1.
- Overall: `1329.82 Mops/s`, which is `2.233x` vs off and `1.059x` vs
  full-on.
- Friendly phases: `2412.79 Mops/s`, `2.562x` vs off and `1.020x` vs full-on.
- Sparse block2M phases: `251.46 Mops/s`, `0.992x` vs off and `1.596x` vs
  full-on.
- Counters: promoted `709,078` pages (`2.70 GiB`) and demoted `799,617` pages
  (`3.05 GiB`), much lower than full-on's `20.51 GiB` promoted and
  `20.84 GiB` demoted.
- Interpretation: miracle/adaptive preserves friendly steady-state benefit and
  suppresses sparse-phase churn. This is the current upper-bound behavior for
  a real phase detector/adaptive policy.

## Latest Phase No-Earlystop/No-Pingpong Rerun

Experiment:
`/Serverless/iccd/experiments/20260508-phase-onoff-adaptive-nostop-noping-localft-256scan-initrd/summaries/analysis.md`

- Runner defaults changed so ordinary phase runs now default to
  `NUMA_MIGRATION_STOP_ENABLED=0` and `NUMA_PINGPONG_STAT_ENABLED=0`; this
  prevents accidental earlystop/pingpong activation when the env overrides are
  omitted.
- This rerun also set `NUMA_PROMOTE_SAMPLE_STAT_ENABLED=0` to remove optional
  diagnostic sampling overhead from the comparison.
- Workload: same `phase_mulshift4g_block2m_sparse64_localft` local-first-touch
  alternating phase candidate, `PHASE_MS=60000`, `PHASE_REPEAT=3`.
- VM and knobs: fresh initrd
  `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260508T003500Z-nostop-noping.img`,
  kernel `#122`, KVM enabled, canonical 32 vCPU / 96G topology, node0 host
  node0, node1 host node2 CXL, `CAPACITY_PAGES=4194304`,
  `NUMA_SCAN_SIZE_MB=256`, `HOT_THRESHOLD_MS=0`, MGLRU runtime `0x0007`.
- Validation: run meta shows `numa_migration_stop_enabled=0`,
  `numa_pingpong_stat_enabled=0`, `numa_promote_sample_stat_enabled=0`; live
  samples kept `cg_migration_stop_effective=0`, `cg_earlystop_running=1`, and
  `cg_promote_sampled` delta `0`.
- Full on/off: off `600.66 Mops/s`, full-on `1388.38 Mops/s`, overall
  `2.311x`; friendly mean `2.774x` (`949.14` to `2633.09 Mops/s`); sparse
  block2M mean still `0.621x` (`256.08` to `159.00 Mops/s`). Full-on promoted
  `5,229,907` pages (`19.95 GiB`) and demoted `5,249,549` pages (`20.03 GiB`).
- Adaptive/oracle `oracle_cgroup_global0`: overall `1324.07 Mops/s`,
  `2.204x` vs off and `0.954x` vs full-on; friendly `2408.90 Mops/s`
  (`2.538x` vs off, `0.915x` vs full-on); sparse `251.81 Mops/s`
  (`0.983x` vs off, `1.584x` vs full-on). Adaptive promoted `692,335` pages
  (`2.64 GiB`) and demoted `771,538` pages (`2.94 GiB`).
- Interpretation: without earlystop/pingpong, the sparse-phase damage remains
  a full-on migration effect, not an earlystop/stat artifact. Adaptive still
  recovers sparse performance and greatly reduces migration volume, but in this
  no-diagnostic run full-on has the higher six-phase overall mean because
  friendly phases dominate the aggregate.

## Latest Phase Earlystop Axis Diagnostic

Experiment:
`/Serverless/iccd/experiments/20260508-phase-earlystop-axis-localft-256scan-initrd/summaries/analysis.md`

- Added an `earlystop` policy label in the guest runner as an alias for full
  migration-on, so the artifact path and summary policy are labeled
  `earlystop`.
- Workload: same `phase_mulshift4g_block2m_sparse64_localft` local-first-touch
  alternating phase candidate, `PHASE_MS=60000`, `PHASE_REPEAT=3`.
- VM and knobs: fresh initrd
  `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260508T011000Z-earlystop-axis.img`,
  kernel `#122`, KVM enabled, canonical 32 vCPU / 96G topology, node0 host
  node0, node1 host node2 CXL, `CAPACITY_PAGES=4194304`,
  `NUMA_SCAN_SIZE_MB=256`, `HOT_THRESHOLD_MS=0`, MGLRU runtime `0x0007`.
  Initrd build used all CPUs: `make -j64 bzImage modules` and
  `make -j64 modules_install`.
- Earlystop knobs: `NUMA_MIGRATION_STOP_ENABLED=1`,
  `NUMA_PINGPONG_STAT_ENABLED=1`, `NUMA_PROMOTE_SAMPLE_STAT_ENABLED=0`.
  `run_meta.txt`/`meta.env` and `live.csv` are the source of truth because the
  runner resets the cgroup after the case; `live.csv` showed
  `cg_migration_stop_effective=1`.
- Result: `earlystop` overall `1262.67 Mops/s`, friendly mean
  `2385.60 Mops/s`, sparse mean `152.70 Mops/s`; promoted `4,831,614` pages
  (`18.43 GiB`) and demoted `5,143,293` pages (`19.62 GiB`).
- Compared with the no-earlystop full-on run: overall `0.909x`, friendly
  `0.906x`, sparse `0.960x`. Compared with migration-off: overall `2.102x`,
  friendly `2.513x`, sparse `0.596x`.
- Stop/restart timeline (`cg_earlystop_running=1` means migration running,
  `0` means stopped): initial running at `0.048s` in phase 1 friendly; stopped
  at `144.228s` in phase 3 friendly; restarted at `186.142s` in phase 4
  sparse; stopped at `266.986s` in phase 5 friendly; restarted at `306.870s`
  in phase 6 sparse.
- Interpretation: this earlystop heuristic is not the desired adaptive policy.
  It stops in friendly phases and restarts in sparse phases, so it does not
  recover the sparse/unfriendly phase and lowers overall throughput relative to
  the no-earlystop full-on run.

## Latest Friendly HSS 32G Probe

Experiment:
`/Serverless/iccd/experiments/20260508-friendly-hss32-hotremote-onoff-localft-256scan-initrd/summaries/analysis.md`

- Added runner label
  `skew_lf_hotremote_32g_fixed_rss16g_mulshift_persistent`.
- Workload: same access shape as the current 4G friendly standalone candidate:
  `skewed-hotset`, fixed window, `100%` read, `hot-prob=100%`,
  `hotset-index-mode=mulshift`, local-first-touch arena plus hotset-only remote
  first-touch. Changed HSS to `32G` with `--window-size 32G` and
  `--hotset-pages 8388608`.
- VM and knobs: reused the no-stop/no-pingpong initrd
  `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260508T003500Z-nostop-noping.img`,
  kernel `#122`, KVM enabled, canonical 32 vCPU / 96G topology, node0 host
  node0, node1 host node2 CXL, `CAPACITY_PAGES=4194304`,
  `NUMA_SCAN_SIZE_MB=256`, `HOT_THRESHOLD_MS=0`, MGLRU runtime `0x0007`.
  Earlystop, pingpong stat, and promote-sample stat were all disabled.
- Measurement: `MBENCH_FORCE_DURATION_MS=60000`, `TIMEOUT_SEC=600`,
  `POLICIES=off,on`.
- Initial anon residency after prefault: off `15.68 GiB` node0 /
  `48.32 GiB` node1; on `15.44 GiB` node0 / `48.56 GiB` node1.
- Result: off mean `225.73 Mops/s`, median `225.77 Mops/s`; on mean
  `255.19 Mops/s`, median `225.51 Mops/s`. Mean on/off `1.131x`, median
  on/off `0.999x`.
- Windowed result: first 10s `0.999x`, middle 10s `0.998x`, last 10s
  `1.681x`. Promotion starts late; on promoted `887,008` pages (`3.38 GiB`)
  and demoted `1,013,852` pages (`3.87 GiB`).
- Interpretation: the 32G HSS version is not immediately friendly under the
  16G local cap. It only shows a strong benefit near the end of the 60s run,
  after a small fraction of the 32G hotset is promoted.

## Open Next Steps

1. Implement or run the real adaptive detector policy and compare it against
   the `oracle_cgroup_global0` miracle baseline.
2. Use `sparse_stride_read_64g_block2m_localft` as the primary standalone
   unfriendly case and `sparse_stride_read_64g` as a secondary negative case if
   a different block shape is needed.
3. Do not use `stream_triad_sweep_32g` as a final negative case unless the
   cutoff is relaxed beyond `0.9`.
4. Continue reporting kernel image, initrd, KVM, VM binding, cgroup cap, scan
   knobs, MGLRU status, placement, throughput, promoted pages/GiB, and demoted
   pages/GiB after each experiment.
