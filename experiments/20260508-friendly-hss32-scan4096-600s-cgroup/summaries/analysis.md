# HSS32 Scan4096 Cgroup 600s On

Date: 2026-05-08

## Setup

| item | value |
| --- | --- |
| kernel image | `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage` |
| initrd | `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260508T003500Z-nostop-noping.img` |
| guest kernel | `Linux kernel 6.18.0modified #122 SMP PREEMPT_DYNAMIC Thu May 7 23:30:15 UTC 2026 x86_64` |
| KVM | enabled (`-accel kvm`) |
| VM topology | `MEMORY=96G`, `CPUS=32`, node0 `32G`, node1 `64G` |
| host binding | node0 on host node0, node1 on host node2 CXL, `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1` |
| cgroup cap | `CAPACITY_PAGES=4194304` (`16 GiB`) |
| policy | `on`, `GLOBAL_NUMA_ON=0`, `NODE_BALANCING_ON=2`, `KSWAPD_DEMOTION_ON=1` |
| placement | local-first-touch arena, hotset-only remote first-touch via `--hotset-prefault-node 1` |
| MGLRU | `/sys/kernel/mm/lru_gen/enabled=0x0007` |
| scan tuning | `NUMA_SCAN_SIZE_MB=4096`, effective `4096`, `SCAN_PERIOD_SCALE=100`, `HOT_THRESHOLD_MS=0` |
| diagnostics | `NUMA_MIGRATION_STOP_ENABLED=0`, `NUMA_PINGPONG_STAT_ENABLED=0`, `NUMA_PROMOTE_SAMPLE_STAT_ENABLED=0` |
| duration/sampling | `MBENCH_FORCE_DURATION_MS=600000`, `SAMPLE_MS=10000`, `LIVE_SAMPLE_SEC=10` |

Workload:

```text
skew_lf_hotremote_32g_fixed_rss16g_mulshift_persistent
--mode skewed-hotset --window-size 32G --window-offset 0
--move-policy fixed --hotset-pages 8388608 --hot-prob-pct 100
--hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0
--hotset-index-mode mulshift --hotset-prefault-node 1
--threads 32 --duration-ms 600000
```

Initial cgroup residency after prefault:

| node | anon bytes | GiB |
| --- | ---: | ---: |
| node0 | `16,536,248,320` | `15.40` |
| node1 | `52,183,322,624` | `48.60` |

## Result

| metric | value |
| --- | ---: |
| total ops | `994,295,939,072` |
| 600s average | `1657.16 Mops/s` |
| steady mean | `1699.77 Mops/s` |
| steady median | `1702.84 Mops/s` |
| HSS | `8,388,608` pages (`32 GiB`) |
| promotion candidates | `3,391,305` |
| candidate/HSS | `40.43%` |
| promoted | `2,097,163` pages (`8.00 GiB`) |
| promoted/HSS | `25.00%` |
| promoted/candidate | `61.84%` |
| demoted | `2,074,817` pages (`7.91 GiB`) |
| over-high failures | `1,293,916` pages (`4.94 GiB`) |
| latency pass/fail | `3,391,305` / `1,181,036` |
| rate-limited | `0` |
| `pgmigrate_fail` | `1,293,918` |
| reclaimd run/wake | `4/4` |

Warmup/pre-measure counter movement, using the live sampler baseline near measured time zero:

| window | promoted | demoted | candidates | over-high |
| --- | ---: | ---: | ---: | ---: |
| approx `-20s..0s` | `701,475` (`2.68 GiB`) | `707,776` (`2.70 GiB`) | `1,694,734` | `993,339` |

## 10s Timeline

Full exact live counter timeline: `/Serverless/iccd/experiments/20260508-friendly-hss32-scan4096-600s-cgroup/summaries/timeline_10s_live.csv`
Combined measurement timeline: `/Serverless/iccd/experiments/20260508-friendly-hss32-scan4096-600s-cgroup/summaries/timeline_10s_combined.csv`

The combined table aligns mbench 10s samples with the nearest active live counter sample after the hidden 20s mbench warmup. Counter deltas should be read as 10s-scale approximations; raw live samples are in `timeline_10s_live.csv`.

| measured interval | ops/s | promote delta | demote delta | candidate delta | over-high delta | promote total | demote total | anon N0/N1 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `0-10s` | `565.81 Mops/s` | `772,182` | `756,544` | `985,512` | `213,317` | `1,496,664` | `3,245,449` | `15.43/48.57 GiB` |
| `10-20s` | `903.03 Mops/s` | `419` | `178,816` | `423` | `0` | `1,497,083` | `3,424,265` | `14.75/49.26 GiB` |
| `20-30s` | `1073.51 Mops/s` | `245,020` | `185,921` | `248,194` | `3,177` | `1,742,103` | `3,610,186` | `14.97/49.03 GiB` |
| `30-40s` | `1578.81 Mops/s` | `207,552` | `185,984` | `291,662` | `84,083` | `1,949,655` | `3,796,170` | `15.05/48.95 GiB` |
| `40-50s` | `1685.92 Mops/s` | `60,197` | `0` | `60,215` | `0` | `2,009,852` | `3,796,170` | `15.28/48.72 GiB` |
| `50-60s` | `1695.53 Mops/s` | `0` | `0` | `0` | `0` | `2,009,852` | `3,796,170` | `15.28/48.72 GiB` |
| `60-70s` | `1694.86 Mops/s` | `3,177` | `0` | `3,177` | `0` | `2,013,029` | `3,796,170` | `15.29/48.71 GiB` |
| `70-80s` | `1696.16 Mops/s` | `84,083` | `0` | `84,110` | `0` | `2,097,112` | `3,796,170` | `15.62/48.38 GiB` |
| `80-90s` | `1702.15 Mops/s` | `18` | `0` | `18` | `0` | `2,097,130` | `3,796,170` | `15.62/48.38 GiB` |
| `90-100s` | `1701.12 Mops/s` | `4` | `0` | `27` | `0` | `2,097,134` | `3,796,170` | `15.62/48.38 GiB` |
| `100-110s` | `1701.77 Mops/s` | `0` | `0` | `9` | `0` | `2,097,134` | `3,796,170` | `15.62/48.38 GiB` |
| `110-120s` | `1702.69 Mops/s` | `0` | `0` | `14` | `0` | `2,097,134` | `3,796,170` | `15.62/48.38 GiB` |
| `170-180s` | `1701.91 Mops/s` | `0` | `0` | `9` | `0` | `2,097,149` | `3,796,170` | `15.62/48.38 GiB` |
| `230-240s` | `1700.69 Mops/s` | `0` | `0` | `0` | `0` | `2,097,158` | `3,796,170` | `15.62/48.38 GiB` |
| `290-300s` | `1703.76 Mops/s` | `0` | `0` | `0` | `0` | `2,097,158` | `3,796,170` | `15.62/48.38 GiB` |
| `350-360s` | `1704.11 Mops/s` | `0` | `0` | `0` | `0` | `2,097,158` | `3,796,170` | `15.62/48.38 GiB` |
| `410-420s` | `1703.52 Mops/s` | `0` | `0` | `0` | `0` | `2,097,158` | `3,796,170` | `15.62/48.38 GiB` |
| `470-480s` | `1704.00 Mops/s` | `0` | `0` | `0` | `0` | `2,097,158` | `3,796,170` | `15.62/48.38 GiB` |
| `530-540s` | `1698.92 Mops/s` | `0` | `0` | `0` | `0` | `2,097,158` | `3,796,170` | `15.62/48.38 GiB` |
| `540-550s` | `1703.45 Mops/s` | `0` | `0` | `0` | `0` | `2,097,158` | `3,796,170` | `15.62/48.38 GiB` |
| `550-560s` | `1703.05 Mops/s` | `0` | `0` | `0` | `0` | `2,097,158` | `3,796,170` | `15.62/48.38 GiB` |
| `560-570s` | `1703.27 Mops/s` | `0` | `0` | `0` | `0` | `2,097,158` | `3,796,170` | `15.62/48.38 GiB` |
| `570-580s` | `1702.84 Mops/s` | `0` | `0` | `0` | `0` | `2,097,158` | `3,796,170` | `15.62/48.38 GiB` |
| `580-590s` | `1701.88 Mops/s` | `0` | `0` | `0` | `0` | `2,097,158` | `3,796,170` | `15.62/48.38 GiB` |
| `590-600s` | `1703.01 Mops/s` | `0` | `0` | `0` | `0` | `2,097,158` | `3,796,170` | `15.62/48.38 GiB` |

## Interpretation

With 4096 MiB scan size, HSS32 forms substantially more candidates than the earlier 256 MiB diagnostic, but the run does not keep promoting throughout the full 600 seconds. Promotion reaches about `8.00 GiB` by the early measured window and then plateaus; the last several minutes are steady around `1.70 Gops/s` with essentially no additional migration.

The limiting point is still headroom, not the hot-threshold rate path: `debug_promote_rate_limited=0`, while over-high failures account for about `4.94 GiB`.

Artifacts:

- raw run: `/Serverless/iccd/experiments/20260508-friendly-hss32-scan4096-600s-cgroup/qemu-logs/phase_candidate_microbench/friendly_hss32_scan4096_600s_cgroup_on_20260508T050606Z`
- case dir: `/Serverless/iccd/experiments/20260508-friendly-hss32-scan4096-600s-cgroup/qemu-logs/phase_candidate_microbench/friendly_hss32_scan4096_600s_cgroup_on_20260508T050606Z/guest-artifacts/friendly_hss32_scan4096_600s_cgroup_on_20260508T050606Z/skew_lf_hotremote_32g_fixed_rss16g_mulshift_persistent__on__rep1`
