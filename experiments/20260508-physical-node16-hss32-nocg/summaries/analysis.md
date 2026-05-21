# Physical Node16 No-Cgroup HSS32 Comparison

Date: 2026-05-08

## Goal

Compare the existing HSS32 cgroup-cap migration-on result with the same
workload under a physical local-node capacity limit: guest node0 is 16G, guest
node1 is 64G, and no workload cgroup/cgroup capacity is used.

## Setup

| item | value |
| --- | --- |
| kernel image | `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage` |
| initrd | `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260508T003500Z-nostop-noping.img` |
| guest kernel | `Linux kernel 6.18.0modified #122 SMP PREEMPT_DYNAMIC Thu May 7 23:30:15 UTC 2026 x86_64` |
| KVM | enabled (`-accel kvm`) |
| VM topology | `MEMORY=80G`, `CPUS=32`, `HOST_CPUS=0-31`, guest node0 CPUs `0-31` |
| VM memory binding | node0 `16G` on host node0, node1 `64G` on host node2 CXL, `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1` |
| cgroup cap | none |
| execution cgroup | root cgroup `0::/`, with no per-workload cgroup knobs or capacity |
| global NUMA mode | `/proc/sys/kernel/numa_balancing=2` |
| demotion | `/sys/kernel/mm/numa/demotion_enabled=true`, target `0 1` |
| MGLRU | `/sys/kernel/mm/lru_gen/enabled=0x0007` |
| scan tuning | `scan_size_mb=256` |
| diagnostic knobs | no earlystop/pingpong workload cgroup exists; cgroup debug counters are unavailable |

The workload command was:

```text
taskset -c 0-31 /root/mbench --csv --quiet --sample-ms 1000 --ops-per-pass 65536 --pause-ns 100000 --arena-size 64G --mode skewed-hotset --window-size 32G --window-offset 0 --move-policy fixed --hotset-pages 8388608 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --hotset-index-mode mulshift --hotset-prefault-node 1 --threads 32 --duration-ms 60000
```

This preserves the same placement shape as the cgroup-cap HSS32 run:
local-first-touch arena plus hotset-only remote first-touch.

Initial process residency after prefault:

| run | node0 | node1 |
| --- | ---: | ---: |
| cgroup-cap on | `15.44 GiB` | `48.56 GiB` |
| physical node16 no-cg on | `14.14 GiB` | `49.86 GiB` |

## Result

| metric | cgroup-cap on | physical node16 no-cg on | physical/cgroup |
| --- | ---: | ---: | ---: |
| mean throughput | `255.19 Mops/s` | `471.13 Mops/s` | `1.846x` |
| median throughput | `225.51 Mops/s` | `483.20 Mops/s` | `2.143x` |
| first 10s throughput | `225.54 Mops/s` | `359.05 Mops/s` | `1.592x` |
| last 10s throughput | `379.35 Mops/s` | `541.28 Mops/s` | `1.427x` |
| promoted | `887,008` pages (`3.38 GiB`) | `783,279` pages (`2.99 GiB`) | `0.883x` |
| demoted | `1,013,852` pages (`3.87 GiB`) | `782,745` pages (`2.99 GiB`) | `0.772x` |

Counter comparison:

| counter | cgroup-cap on | physical node16 no-cg on | physical/cgroup |
| --- | ---: | ---: | ---: |
| `numa_hint_faults` | `4,252,330` | `2,097,874` | `0.493x` |
| `numa_hint_faults_local` | `88,708` | `0` | `0.000x` |
| `pgpromote_candidate` | `1,957,996` | `984,611` | `0.503x` |
| `pgpromote_candidate_nrl` | `8` | `398` | `49.750x` |
| `pgpromote_success` | `887,008` | `783,279` | `0.883x` |
| `numa_pages_migrated` | `887,008` | `783,354` | `0.883x` |
| `pgmigrate_success` | `1,872,700` | `1,566,099` | `0.836x` |
| `pgmigrate_fail` | `1,070,997` | `149` | `0.000x` |
| `pgdemote_direct` | `985,692` | `0` | `0.000x` |
| `pgdemote_kswapd` | `0` | `782,745` | n/a |
| `pgscan_direct` | `0` | `0` | n/a |
| `pgscan_kswapd` | `0` | `783,996` | n/a |
| `pgsteal_direct` | `0` | `0` | n/a |
| `pgsteal_kswapd` | `0` | `782,745` | n/a |

## Interpretation

With physical node0 capped at 16G, the kernel promoted slightly less memory
than the cgroup-cap path (`2.99 GiB` vs `3.38 GiB`), but throughput was much
higher. The big behavioral difference is the failure path: cgroup-cap hit
`1,070,997` migration failures, mostly the cgroup over-high gate, while the
physical-node run had only `149` `pgmigrate_fail` events.

Demotion also moved through a different path. The cgroup-cap run demoted via
the memcg/reclaimd direct path (`pgdemote_direct`), while the physical-node run
used global kswapd reclaim/demotion (`pgscan_kswapd`, `pgsteal_kswapd`,
`pgdemote_kswapd`).

Two preliminary no-cgroup attempts left the benchmark in the SSH/systemd
service cgroup. In this kernel, non-root memcgs use their own
`node_balancing_mode`, which defaults to `0`, so global
`/proc/sys/kernel/numa_balancing` did not drive NUMA scanning there. Those
attempts produced `0` hint faults and `0` promotion. The valid physical-node
comparison above moves only the runner into the root cgroup (`0::/`) so the
global physical-node tiering path is used, without creating a workload cgroup
or capacity cap.

## Why Physical Was Faster With Less Total Promotion

An additional physical-node16 no-cgroup off run was used to rule out runner or
base-placement differences:

| run | mean | promoted | demoted | hint faults |
| --- | ---: | ---: | ---: | ---: |
| cgroup-cap off | `225.73 Mops/s` | `0` | `359,104` | `0` |
| physical node16 no-cg off | `224.00 Mops/s` | `0` | `0` | `0` |
| cgroup-cap on | `255.19 Mops/s` | `887,008` | `1,013,852` | `4,252,330` |
| physical node16 no-cg on | `471.13 Mops/s` | `783,279` | `782,745` | `2,097,874` |

So the fast physical result is not because the custom no-cgroup runner has a
higher off baseline. The off baselines are effectively identical.

The difference is timing and wasted work:

| 10s window | cgroup-cap on | physical node16 no-cg on |
| --- | ---: | ---: |
| `0-10s` | `225.54 Mops/s` | `359.05 Mops/s` |
| `10-20s` | `225.53 Mops/s` | `403.44 Mops/s` |
| `20-30s` | `225.46 Mops/s` | `451.14 Mops/s` |
| `30-40s` | `225.41 Mops/s` | `496.94 Mops/s` |
| `40-50s` | `225.56 Mops/s` | `536.41 Mops/s` |
| `50-60s` | `394.72 Mops/s` | `541.28 Mops/s` |

The cgroup-cap run spent most of the measurement at the off-rate and only
ramped in the last window. Its live counters show a large first hint-fault
batch with no promotion candidates, then promotion starts late. When promotion
does start, node0 reaches the cgroup high/reserve gate quickly and
`pgmigrate_fail` rises to `1,070,997`.

The physical-node run starts promoting and demoting early, and the promotion
volume accumulates throughout the measurement. It also does about half the
hint faults and almost no failed migrations. In other words, the physical run
does not win because it ends with much more local memory; it wins because the
useful part of the migration happens during the whole run, while the cgroup
run spends most of the run paying scan/fault/check overhead without moving
pages, then pays over-high failure overhead during the late ramp.

The code path explains why the two gates are different. In
`should_numa_migrate_memory()`, the cgroup case first asks
`mem_cgroup_node_promotion_wmark_ok()`. That function only applies to non-root
memcgs with cgroup node capacity; root/no-cgroup returns `-EOPNOTSUPP`.
For root/no-cgroup, the promotion decision falls back to global pgdat free
space via `pgdat_free_space_enough()`. For the cgroup-cap run, the memcg path
uses `node_capacity`, low/high watermarks, and a promotion reserve before it
allows bypass or allocation.

So reclaimd and kswapd are not equivalent even if both eventually call into
vmscan/demotion machinery:

- physical-node pressure is driven by global fast-node zone watermarks and
  kswapd. Demotion is coupled to physical node pressure, so allocation and
  kswapd can keep a small amount of fast-node headroom moving.
- cgroup-cap pressure is driven by memcg node-capacity accounting. Promotion
  is rejected by the cgroup high/reserve gate even when the physical node still
  has global free space, and reclaimd only reacts through the memcg reclaim
  scheduling loop.
- the measured cgroup-cap run shows exactly that mismatch: reclaimd did demote
  pages, but not early or continuously enough to prevent the late
  `1.07M` over-high failures.

This means the current memcg/reclaimd path is not just "kswapd but scoped to a
cgroup"; its trigger, high/reserve gate, and feedback timing are different.
The next thing to validate is whether waking reclaimd before or at the
promotion-candidate burst, or making promotion retry wait for reclaimd-created
headroom, makes the cgroup-cap timeline look more like the physical-node
timeline.

## Cgroup-Specific Root Cause Detail

There are four concrete cgroup-side differences from the physical/root path.

First, the cgroup run used a much more aggressive per-memcg scan period. The
runner writes:

```text
memory.numa_balancing_scan_period_scale = 1
memory.numa_balancing_hot_threshold_ms = 0
```

In the kernel this scale is interpreted as a percentage of the normal scan
period. So `1` means `1%`, not "default". The physical/root no-cgroup runner
did not set equivalent global scan-period debugfs knobs, so it used the global
default scan cadence. This matters because the cgroup workload is gated after
prefault. With an extremely short memcg scan period, PTEs can be marked during
prefault/gate timing, and the first measured accesses can refault too late to
pass the memory-tiering hot-threshold test.

That matches the live counters:

| run point | hint faults | candidates | promotions | demotions | failures |
| --- | ---: | ---: | ---: | ---: | ---: |
| cgroup on, ~1s | `+1,899,549` | `0` | `0` | `+96,064` | `0` |
| cgroup on, ~63s | `+1,899,550` | `0` | `0` | `+260,288` | `0` |
| cgroup on, final | `+4,054,717` | `+1,957,996` | `+887,008` | `+944,092` | `+1,070,997` |
| physical on, ~3s | `+1,083,612` | `+57,112` | `+43,807` | `+40,897` | `+23` |
| physical on, ~65s | `+2,007,431` | `+980,884` | `+779,486` | `+774,981` | `+93` |

Second, the cgroup capacity gate is stricter and separate from physical free
space. For the current 16G cap:

```text
capacity = 4,194,304 pages = 16 GiB
low      = 95% = 3,984,588 pages = 15.20 GiB
high     = 98% = 4,110,417 pages = 15.68 GiB
promotion reserve = max(1 GiB, capacity / 16) = 262,144 pages
hot-threshold bypass only if projected <= low - reserve = 3,722,444 pages = 14.20 GiB
```

The cgroup HSS32 run starts around `15.44 GiB` on node0, which is already above
the `14.20 GiB` hot-threshold bypass boundary. So the cgroup path cannot use
the "there is enough headroom, promote without hot-threshold filtering" fast
path. Later, actual destination allocation is rejected once projected node0
usage exceeds the high/reserve gate. This is where
`numa_migrate_fail_promotion_over_high` comes from.

Third, reclaimd is reactive to cgroup accounting, not to global zone pressure.
Regular charge-side wakeups go through `memcg_reclaimd_maybe_wake_on_charge()`,
but migration destination allocation uses a non-reclaim GFP path and explicitly
clears `__GFP_RECLAIM`. The promotion path therefore mostly wakes reclaimd only
after `mem_cgroup_node_over_high()` rejects an allocation attempt. At that
point the fault path has already failed the current promotion.

Fourth, the retry loop is immediate, not coordinated with reclaimd progress.
`alloc_misplaced_dst_folio()` returns `-EAGAIN` on cgroup over-high and wakes
reclaimd. `migrate_pages()` can retry `-EAGAIN`, but those retries happen in
the same fault/migration context. They do not wait for the memcg reclaimd
thread to run vmscan, demote pages, and update node usage. So a burst of hot
promotion candidates can repeatedly hit the same high gate before reclaimd has
created usable headroom.

The physical/root path avoids this exact coupling for two reasons:

- global balancing does not use the memcg `node_capacity`/low/high/promotion
  reserve gate;
- physical memory pressure and kswapd are coupled through pgdat/zone watermarks,
  while cgroup reclaimd is a separate per-memcg work queue with pending/inflight
  coalescing and a `100ms` cooldown check after balanced reclaim.

So the cgroup path differs in both policy and timing. It scans much more
aggressively, filters many early faults as non-hot, only discovers useful
promotion candidates late, then rejects many of those candidates at a memcg
high/reserve gate. Reclaimd does demote pages, but it is not synchronized with
the promotion burst closely enough to prevent the over-high failures.

Artifacts:

- Valid physical-node run:
  `/Serverless/iccd/experiments/20260508-physical-node16-hss32-nocg/qemu-logs/phase_candidate_microbench/physical_node16_hss32_nocg_rootcg_on_20260508T021016Z`
- Physical-node no-cgroup off control:
  `/Serverless/iccd/experiments/20260508-physical-node16-hss32-nocg/qemu-logs/phase_candidate_microbench/physical_node16_hss32_nocg_rootcg_off_20260508T023049Z`
- Guest runner:
  `/Serverless/iccd/experiments/20260508-physical-node16-hss32-nocg/notes/run_physical_hss32_guest.sh`
- Baseline cgroup-cap HSS32 run:
  `/Serverless/iccd/experiments/20260508-friendly-hss32-hotremote-onoff-localft-256scan-initrd/qemu-logs/phase_candidate_microbench/friendly_hss32_hotremote_onoff_20260508T012500Z`
