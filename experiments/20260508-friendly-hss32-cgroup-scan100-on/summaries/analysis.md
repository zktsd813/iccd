# HSS32 Cgroup On With Scan Period Scale 100

Date: 2026-05-08

## Goal

Rerun the HSS32 cgroup-cap migration-on workload with the same setup as the
previous HSS32 run, changing only the per-memcg NUMA scan period scale from
`1` to `100`.

## Setup

| item | value |
| --- | --- |
| kernel image | `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage` |
| initrd | `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260508T003500Z-nostop-noping.img` |
| VM topology | `MEMORY=96G`, `CPUS=32`, node0 `32G`, node1 `64G` |
| host binding | node0 on host node0, node1 on host node2 CXL, `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1` |
| cgroup cap | `CAPACITY_PAGES=4194304` (`16 GiB`) |
| policy | `on`, `node_balancing=2`, `GLOBAL_NUMA_ON=0` |
| demotion | `kswapd_demotion_enabled=1` |
| scan tuning | `NUMA_SCAN_SIZE_MB=256`, `SCAN_PERIOD_SCALE=100`, `HOT_THRESHOLD_MS=0` |
| diagnostic knobs | `NUMA_MIGRATION_STOP_ENABLED=0`, `NUMA_PINGPONG_STAT_ENABLED=0`, `NUMA_PROMOTE_SAMPLE_STAT_ENABLED=0` |
| placement | local-first-touch arena, hotset-only remote first-touch |

Workload:

```text
skew_lf_hotremote_32g_fixed_rss16g_mulshift_persistent
--mode skewed-hotset --window-size 32G --window-offset 0 --move-policy fixed
--hotset-pages 8388608 --hot-prob-pct 100 --hotset-read-pct 100
--hotset-write-pct 0 --hotset-rmw-pct 0 --hotset-index-mode mulshift
--hotset-prefault-node 1 --threads 32 --duration-ms 60000
```

## Result

| run | mean | median | first10 | last10 | promoted | demoted | hint faults | candidates | failures |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| cgroup scan1 on | `255.19 Mops/s` | `225.51 Mops/s` | `225.54 Mops/s` | `394.72 Mops/s` | `887,008` | `1,013,852` | `4,252,330` | `1,957,996` | `1,070,997` |
| cgroup scan100 on | `648.26 Mops/s` | `672.20 Mops/s` | `514.26 Mops/s` | `712.72 Mops/s` | `1,031,451` | `1,119,617` | `2,200,313` | `1,054,149` | `22,714` |
| physical node16 no-cg on | `471.13 Mops/s` | `483.20 Mops/s` | `359.05 Mops/s` | `541.28 Mops/s` | `783,279` | `782,745` | `2,097,874` | `984,611` | `149` |

Important cgroup scan100 counters:

| counter | value |
| --- | ---: |
| `debug_promote_enter` | `2,097,164` |
| `debug_promote_latency_pass` | `1,054,149` |
| `debug_promote_latency_fail` | `1,043,003` |
| `debug_promote_rate_limited` | `0` |
| `debug_promote_wmark_bypass` | `12` |
| `debug_promote_wmark_no_bypass` | `2,097,152` |
| `numa_migrate_fail_promotion_over_high` | `22,710` |
| `pgpromote_success` | `1,031,451` |
| `pgdemote_direct` | `1,119,617` |
| `reclaimd.run_count` | `4` |
| `reclaimd.wake_count` | `4` |

## Interpretation

This run confirms that the previous cgroup HSS32 result was strongly affected
by `SCAN_PERIOD_SCALE=1`, not just by the cgroup capacity gate. With scan scale
restored to `100`, promotion starts in the first seconds, throughput ramps
throughout the measurement, and over-high failures fall from about `1.07M` to
about `22.7K`.

The cgroup path still uses the memcg high/reserve gate, and the hot-threshold
bypass remains effectively disabled for this workload (`debug_promote_wmark_bypass=12`
versus `debug_promote_wmark_no_bypass=2,097,152`). But the candidate timing is
much healthier: fewer total hint faults are needed, about half become
candidates, and most candidates promote successfully.

Live checkpoints from scan100:

| time | node0 | node1 | hint+ | candidate+ | promoted+ | demoted+ | fail+ |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `1.1s` | `15.37 GiB` | `48.63 GiB` | `891,363` | `34,745` | `34,745` | `80,832` | `0` |
| `10.5s` | `15.40 GiB` | `48.60 GiB` | `1,056,275` | `184,691` | `184,691` | `221,760` | `0` |
| `20.8s` | `14.97 GiB` | `49.03 GiB` | `1,239,123` | `351,164` | `349,063` | `499,841` | `2,101` |
| `41.2s` | `15.34 GiB` | `48.66 GiB` | `1,589,357` | `669,689` | `666,307` | `718,721` | `3,384` |
| `59.7s` | `15.54 GiB` | `48.46 GiB` | `1,911,829` | `964,601` | `941,891` | `941,889` | `22,714` |

Artifact:

- `/Serverless/iccd/experiments/20260508-friendly-hss32-cgroup-scan100-on/qemu-logs/phase_candidate_microbench/friendly_hss32_cgroup_scan100_on_20260508T031942Z`
