# NUMA policy resync validation, 256MB scan

Date: 2026-05-09

## Patch

Final tested kernel:

- Kernel image: `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`
- Initrd: `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-policy-resync-20260509.img`
- Guest kernel: `Linux kernel 6.18.0modified #163 SMP PREEMPT_DYNAMIC Sat May 9 12:53:28 UTC 2026`
- MGLRU runtime: `lru_gen_enabled=0x0007`

The temporary diagnostic behavior that forced `p->numa_scan_period = task_scan_min(p)`
on every `task_numa_work()` was removed.  The final implementation uses an
automatic policy-resync mechanism:

- `mem_cgroup::numa_balancing_policy_seq` is incremented when memcg NUMA policy
  changes (`memory.node_balancing`, `memory.numa_balancing_fast_scan`, disable).
- Each task caches the effective policy seq/mode/fast bit.
- `task_numa_sync_scan_policy()` runs from both NUMA tick and NUMA work.
- Same-policy stale events clear the stale bit without resetting scan cadence.
- Scan cadence is reset and `mm->numa_next_scan` is pulled forward only on
  scan-accelerating transitions: disabled-to-enabled or fast_scan 0-to-1.
- Cgroup attach and non-final `task_numa_free()` mark the task stale so attach
  and exec/reset paths re-read policy automatically.
- `init_numa_balancing()` initializes the policy cache from the task's current
  effective policy, preserving CLONE_VM thread scan staggering for no-fast tasks.

An intermediate run showed why this distinction matters: treating every
new-task stale state as a cadence reset made 1000ms/no-fast lose thread
staggering and over-scan early.  That was fixed before the final #163 runs.

## VM setup

Common settings:

- VM: 32 vCPUs, 96G RAM, KVM enabled.
- Guest node0: CPUs 0-31, 32G, host node0, `policy=bind`, preallocated.
- Guest node1: 64G, host node2, `policy=bind`, preallocated.
- Cgroup cap: `CAPACITY_PAGES=4194304` (16G).
- Workload: `skew_lf_hotremote_4g_move_60s_remoteonly_mulshift_persistent`
- Policy: `on`, `NODE_BALANCING_ON=2`, `GLOBAL_NUMA_ON=0`
- Demotion: `KSWAPD_DEMOTION_ON=1`, `OFF_DEMOTION_ON=1`
- Diagnostics: `NUMA_MIGRATION_STOP_ENABLED=0`, `NUMA_PINGPONG_STAT_ENABLED=0`
- `NUMA_SCAN_SIZE_MB=256`, `HOT_THRESHOLD_MS=0`
- Measurement: `MBENCH_FORCE_DURATION_MS=120000`, live sample every 5s.

Compared runs:

- `20260509TSCAN256-p1000-fastoff-resync3-on5s`: `NUMA_SCAN_PERIOD_MIN_MS=1000`, `NUMA_FAST_SCAN=0`
- `20260509TSCAN256-p250-faston-resync3-on5s`: `NUMA_SCAN_PERIOD_MIN_MS=250`, `NUMA_FAST_SCAN=1`

## Overall live deltas

Live deltas are from the first live sample to the sample nearest 120s.  They
exclude prefault-time work already present before measurement sample 0.

| run | window | hint faults | PTE updates | PTE GiB | promote success | promote candidates | direct demote GiB |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1000ms no-fast | 0.051-120.729s | 3,700,649 | 16,227,586 | 61.90 | 2,097,158 | 2,097,158 | 8.40 |
| 250ms fast-on | 0.044-120.669s | 4,824,860 | 17,133,072 | 65.36 | 2,103,581 | 2,103,581 | 8.57 |

Full case counter diffs, from `cgroup.before` to `cgroup.after`:

| run | hint faults | PTE updates | promote success | direct demote |
| --- | ---: | ---: | ---: | ---: |
| 1000ms no-fast | 3,733,433 | 16,227,589 | 2,097,166 | 2,238,912 |
| 250ms fast-on | 4,824,879 | 17,395,222 | 2,103,589 | 2,250,310 |

## 10s live buckets

| run | bucket | hint faults | PTE updates | PTE GiB | promote success |
| --- | --- | ---: | ---: | ---: | ---: |
| 1000ms no-fast | 0-10s | 0 | 6,488,064 | 24.75 | 0 |
| 1000ms no-fast | 10-20s | 339,127 | 5,224,208 | 19.93 | 308,285 |
| 1000ms no-fast | 20-30s | 786,670 | 1,475,663 | 5.63 | 463,806 |
| 1000ms no-fast | 30-40s | 304,141 | 542,218 | 2.07 | 276,491 |
| 1000ms no-fast | 40-50s | 0 | 428,736 | 1.64 | 0 |
| 1000ms no-fast | 50-60s | 0 | 0 | 0.00 | 0 |
| 1000ms no-fast | 60-70s | 0 | 0 | 0.00 | 0 |
| 1000ms no-fast | 70-80s | 1,048,578 | 0 | 0.00 | 0 |
| 1000ms no-fast | 80-90s | 1,146,566 | 1,048,576 | 4.00 | 979,879 |
| 1000ms no-fast | 90-100s | 0 | 514,461 | 1.96 | 0 |
| 1000ms no-fast | 100-110s | 75,567 | 505,660 | 1.93 | 68,697 |
| 1000ms no-fast | 110-120s | 0 | 0 | 0.00 | 0 |
| 250ms fast-on | 0-10s | 2,069,036 | 14,611,832 | 55.74 | 1,051,275 |
| 250ms fast-on | 10-20s | 7 | 6 | 0.00 | 2 |
| 250ms fast-on | 20-30s | 5 | 5 | 0.00 | 5 |
| 250ms fast-on | 30-40s | 0 | 0 | 0.00 | 0 |
| 250ms fast-on | 40-50s | 0 | 0 | 0.00 | 0 |
| 250ms fast-on | 50-60s | 0 | 0 | 0.00 | 0 |
| 250ms fast-on | 60-70s | 0 | 0 | 0.00 | 0 |
| 250ms fast-on | 70-80s | 1,048,578 | 0 | 0.00 | 0 |
| 250ms fast-on | 80-90s | 1,707,234 | 2,521,229 | 9.62 | 1,052,299 |
| 250ms fast-on | 90-100s | 0 | 0 | 0.00 | 0 |
| 250ms fast-on | 100-110s | 0 | 0 | 0.00 | 0 |
| 250ms fast-on | 110-120s | 0 | 0 | 0.00 | 0 |

## Interpretation

The automatic resync is working.  Fast-on no longer behaves like the stale
1000ms path: it front-loads PTE protection and hint faults, then goes idle after
the relevant pages are protected/refaulted.

The 120s total PTE-update count is not a good discriminator at
`NUMA_SCAN_SIZE_MB=256`.  With a 64G resident working set:

- `task_nr_scan_windows ~= 64G / 256M = 256`
- no-fast `scan = 1000ms / 256 ~= 3ms`
- no-fast floor from `MAX_SCAN_WINDOW=2560MB/s` is `1000 / (2560/256) = 100ms`
- so no-fast still scans up to about 2.5GiB/s and can cover most of the
  address space in the 120s window.

Therefore the expected difference is mostly temporal, not total:

- no-fast spreads the initial scan across about 0-50s, with additional work
  around 80-110s after the phase/window change.
- fast-on completes the initial scan in the first 10s and the phase-change scan
  mostly in 80-90s.

Promotion totals are also close because both runs eventually identify and
promote roughly the same hot moving-window pages.  More scans after pages are
already protected do not create proportional extra promotions.

## Artifacts

- Final no-fast run:
  `/Serverless/iccd/experiments/20260509-scan256-policy-resync-pte/qemu-logs/phase_candidate_microbench/20260509TSCAN256-p1000-fastoff-resync3-on5s`
- Final fast-on run:
  `/Serverless/iccd/experiments/20260509-scan256-policy-resync-pte/qemu-logs/phase_candidate_microbench/20260509TSCAN256-p250-faston-resync3-on5s`

