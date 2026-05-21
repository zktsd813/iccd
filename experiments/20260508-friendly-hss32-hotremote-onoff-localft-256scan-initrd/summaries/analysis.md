# Friendly Access Pattern With 32G Hotset

Date: 2026-05-08

## Goal

Run the same friendly access pattern as
`skew_lf_hotremote_4g_fixed_rss16g_mulshift_persistent`, but increase HSS from
`4G` to `32G`. Only `off` and `on` were tested.

## Workload

Runner label:
`skew_lf_hotremote_32g_fixed_rss16g_mulshift_persistent`

Command shape:

```text
--mode skewed-hotset
--window-size 32G
--window-offset 0
--move-policy fixed
--hotset-pages 8388608
--hot-prob-pct 100
--hotset-read-pct 100
--hotset-write-pct 0
--hotset-rmw-pct 0
--hotset-index-mode mulshift
--hotset-prefault-node 1
--threads 32
--duration-ms 60000
```

This keeps the arena local-first-touch and places only the 32G hotset/window on
remote node1 before measurement.

## Setup

| item | value |
| --- | --- |
| kernel image | `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage` |
| initrd | `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260508T003500Z-nostop-noping.img` |
| guest kernel | `Linux kernel 6.18.0modified #122 SMP PREEMPT_DYNAMIC Thu May 7 23:30:15 UTC 2026 x86_64` |
| KVM | enabled (`-accel kvm`) |
| VM topology | `MEMORY=96G`, `CPUS=32`, `HOST_CPUS=0-31`, guest node0 CPUs `0-31` |
| VM memory binding | node0 `32G` on host node0, node1 `64G` on host node2 CXL, `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1` |
| cgroup cap | `CAPACITY_PAGES=4194304` (`16 GiB`) |
| MGLRU | `/sys/kernel/mm/lru_gen/enabled = 0x0007` |
| scan tuning | `NUMA_SCAN_SIZE_MB=256`, effective `256`, `SCAN_PERIOD_SCALE=1`, `HOT_THRESHOLD_MS=0` |
| diagnostic knobs | `NUMA_MIGRATION_STOP_ENABLED=0`, `NUMA_PINGPONG_STAT_ENABLED=0`, `NUMA_PROMOTE_SAMPLE_STAT_ENABLED=0` |
| placement | local-first-touch arena, hotset-only remote first-touch, `remote_firsttouch=0` |

Initial anon residency after prefault:

| policy | node0 | node1 |
| --- | ---: | ---: |
| `off` | `15.68 GiB` | `48.32 GiB` |
| `on` | `15.44 GiB` | `48.56 GiB` |

## Result

| policy | mean | median | promoted | demoted |
| --- | ---: | ---: | ---: | ---: |
| `off` | `225.73 Mops/s` | `225.77 Mops/s` | `0` pages (`0.00 GiB`) | `359,104` pages (`1.37 GiB`) |
| `on` | `255.19 Mops/s` | `225.51 Mops/s` | `887,008` pages (`3.38 GiB`) | `1,013,852` pages (`3.87 GiB`) |

Mean on/off is `1.131x`. Median on/off is `0.999x`.

Windowed throughput:

| window | off | on | on/off |
| --- | ---: | ---: | ---: |
| first 10s | `225.76 Mops/s` | `225.54 Mops/s` | `0.999x` |
| middle 10s | `225.76 Mops/s` | `225.35 Mops/s` | `0.998x` |
| last 10s | `225.67 Mops/s` | `379.35 Mops/s` | `1.681x` |

## Interpretation

The 32G HSS workload is not immediately friendly under the 16G local cap. The
full-run mean improves by `13.1%`, but the median is effectively unchanged
because promotion begins late in the 60 second measurement. Only the last 10
seconds show a strong benefit (`1.681x`), after about `3.38 GiB` has been
promoted.

This is qualitatively different from the 4G hotset friendly workload: the 32G
hotset exceeds the local cap, so the migration policy can only promote a
fraction of the active set during the short run.

## Why Promotion And Demotion Are Low

The low migration volume is not because migration is disabled. It is the
combination of scan coverage, hot-threshold/candidate filtering, and the 16G
local-cap watermark.

From the migration-on run:

- `numa_hint_faults=4,252,330` pages, about `16.22 GiB` of hint-fault coverage.
  That is only about half of the 32G hotset during the 60 second measurement.
- `debug_promote_latency_fail=2,205,618` and
  `debug_promote_latency_pass=1,957,996`, so only about `7.47 GiB` became
  promotion candidates.
- Of those candidates, `887,008` pages (`3.38 GiB`) promoted successfully, but
  `1,070,995` pages (`4.09 GiB`) failed the promotion over-high gate.
- Reclaimd ran only one additional measured pass (`run_count +1`) and demoted
  about `1,013,852` pages (`3.87 GiB`). This created enough headroom for only a
  few GiB of successful promotion.

The live sampler shows the timing:

- Before promotion starts, node0 is held around `14.31 GiB` and node1 around
  `49.69 GiB`; promotion counters remain zero for most of the run.
- Around the last part of the measurement, hint faults resume and promotion
  begins. Node0 quickly reaches the high watermark near `4,110,417` pages
  (`~15.68 GiB`), and `numa_migrate_fail_promotion_over_high` rises.
- Reclaimd then demotes roughly `1M` pages, but there is not enough time in the
  60 second window for repeated scan/promote/demote cycles across a 32G hotset.

So the limiting path is:

```text
32G hotset > 16G cap
  -> only partial hotset can be local
  -> NUMA scan covers only part of it in 60s
  -> first hint faults mostly fail the hot-threshold latency test
  -> later candidates hit node0 high watermark
  -> reclaimd creates only a few GiB of headroom before the run ends
```

For a clearer steady-state answer, rerun this exact HSS32 workload with a longer
measurement window, for example `MBENCH_FORCE_DURATION_MS=180000` or `300000`,
and compare last-window throughput plus cumulative promoted/demoted pages.

Artifact:

- `/Serverless/iccd/experiments/20260508-friendly-hss32-hotremote-onoff-localft-256scan-initrd/qemu-logs/phase_candidate_microbench/friendly_hss32_hotremote_onoff_20260508T012500Z`
