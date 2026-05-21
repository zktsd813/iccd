# Local-First-Touch With Friendly Hotset-Remote Validation

Date: 2026-05-07

## Run

- Run ID: `localft_hotremote_ft_nosettle_onoff_20260507T140759Z`
- Artifacts: `/Serverless/iccd/experiments/20260507-localft-hotremote-firsttouch-nosettle-onoff-256scan-initrd/qemu-logs/phase_candidate_microbench/localft_hotremote_ft_nosettle_onoff_20260507T140759Z`
- Guest summary: `guest-artifacts/localft_hotremote_ft_nosettle_onoff_20260507T140759Z/summary.jsonl`
- Checklist read before run: `/Serverless/iccd/docs/current-migration-workloads-20260507.md`

## Build And VM Settings

- Kernel image: `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`
- Initrd image: `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260507T131826Z-256scan.img`
- Guest kernel: `Linux kernel 6.18.0modified #109 SMP PREEMPT_DYNAMIC Thu May 7 13:21:07 UTC 2026 x86_64`
- QEMU/KVM: KVM used.
- VM CPU/memory: `CPUS=32`, `MEMORY=96G`, `HOST_CPUS=0-31`.
- VM NUMA binding: guest node0 CPUs `0-31`, node0 `32G` on host node0; guest node1 `64G` on host node2; `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1`.
- Cgroup cap: `CAPACITY_PAGES=4194304` (16GiB).
- Knobs: `GLOBAL_NUMA_ON=0`, `NODE_BALANCING_ON=2`, `KSWAPD_DEMOTION_ON=1`, `OFF_DEMOTION_ON=1`.
- Scan tuning: `NUMA_SCAN_SIZE_MB=256`, `SCAN_PERIOD_SCALE=1`, `HOT_THRESHOLD_MS=0`.
- Workload: `THREADS=32`, `ARENA_SIZE=64G`, `PAUSE_NS=0`, `OPS_PER_PASS=65536`, `MBENCH_FORCE_DURATION_MS=60000`.
- Prefault gate: enabled, but reclaimd prefault settle disabled with `PREFAULT_SETTLE_RECLAIMD=0` so the run starts with node0 already filled near the cap.
- mbench change: added `--hotset-prefault-node N`, which first-touches the skewed-hotset window on node `N`, resets thread mempolicy to default, then first-touches the remaining arena normally. This avoids persistent `mbind` policy that would block later NUMA balancing.
- Demotion accounting below is `pgdemote_direct + pgdemote_kswapd`.

## Initial Residency

Measured just before workload start:

| candidate | policy | anon node0 | anon node1 | live max node0 exact |
| --- | --- | ---: | ---: | ---: |
| `skew_lf_hotremote_4g_fixed_rss16g_mulshift_persistent` | off | 15.68 GiB | 48.32 GiB | 15.68 GiB |
| `skew_lf_hotremote_4g_fixed_rss16g_mulshift_persistent` | on | 15.34 GiB | 48.66 GiB | 15.24 GiB |
| `sparse_stride_read_64g_block2m_localft` | off | 15.36 GiB | 48.64 GiB | 15.29 GiB |
| `sparse_stride_read_64g_block2m_localft` | on | 15.22 GiB | 48.78 GiB | 15.68 GiB |

This confirms the new start condition: node0 is filled first up to the cgroup
cap/high watermark, with the remainder on node1. Friendly additionally used
`--hotset-prefault-node 1`.

## Results

| candidate | expected | policy | throughput | promoted pages | promoted GiB | demoted pages | demoted GiB | hint faults |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `skew_lf_hotremote_4g_fixed_rss16g_mulshift_persistent` | friendly | off | 394.51 Mops/s | 0 | 0.00 | 0 | 0.00 | 0 |
| `skew_lf_hotremote_4g_fixed_rss16g_mulshift_persistent` | friendly | on | 392.76 Mops/s | 12 | 0.00 | 72,960 | 0.28 | 1,048,610 |
| `sparse_stride_read_64g_block2m_localft` | unfriendly | off | 1186.25 MiB/s | 0 | 0.00 | 76,347 | 0.29 | 0 |
| `sparse_stride_read_64g_block2m_localft` | unfriendly | on | 1322.39 MiB/s | 125,772 | 0.48 | 41,376 | 0.16 | 10,039,612 |

## Verdict

- Friendly hotset-remote did not benefit: `on/off = 0.996x` (`-0.4%`). The hotset was first-touched on node1, but node0 started near the low watermark and almost no pages reached the promotion candidate path.
- Unfriendly local-first-touch still improved mildly: `on/off = 1.115x` (`+11.5%`), with 125,772 promoted pages and 41,376 demoted pages.
- This run confirms the previous anomaly source: placement matters. Starting with node0 already filled removes the large remote-firsttouch promotion upside, but it also leaves little reserve for the hot-threshold bypass unless the policy actively demotes cold local pages before the hotset scan.

## Promotion Path Diagnostic

- During the measured friendly-on window, the promotion hard-block counters did
  not increase: `numa_migrate_fail_promotion_blocked=0`,
  `numa_migrate_fail_promotion_over_high=0`, and `pgmigrate_fail=0`.
- The failure point was earlier than allocation: `1,048,610` hint faults led to
  only `12` promotions, `12` `PGPROMOTE_CANDIDATE_NRL` pages, and `9`
  sampled/refaulted promotion pages.
- The normal hot-threshold candidate counter was effectively zero:
  `PGPROMOTE_CANDIDATE` did not increase during measurement. In
  `should_numa_migrate_memory()`, that means the faults returned before
  `numa_promotion_rate_limit()`, most likely at `latency >= th`.
- Node0 low watermark was `3984588` pages and the current promotion reserve is
  `262144` pages, so `mem_cgroup_node_promotion_wmark_ok()` only bypasses the
  hot threshold when projected node0 usage is at or below `3722444` pages.
  Live samples stayed around `3984637` pages, so the bypass path was off.
- The strongest current suspect is stale prefault-time scanning. The workload
  prefaults the hotset first, then touches the rest of the 64G arena while
  cgroup NUMA balancing is already enabled. The hotset is then idle during the
  remaining prefault/demotion work, so PTEs can be marked before measurement.
  The first measured hotset accesses then refault too late for the default
  `1000ms` hot threshold and rebuild the PTEs without migration.
- Therefore this result should be interpreted as "promotion candidates were not
  generated under the local-first-touch filled-node start", not as "promotion
  allocation was blocked by the old headroom check".
