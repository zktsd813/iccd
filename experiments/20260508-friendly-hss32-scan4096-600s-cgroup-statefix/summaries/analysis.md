# HSS32 Scan4096 Cgroup 600s On, Persistent-State Fix

Date: 2026-05-08

## Setup

| item | value |
| --- | --- |
| project commit | `e97c4d418` |
| kernel image | `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage` |
| initrd | `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260508T003500Z-nostop-noping.img` |
| guest kernel | `Linux kernel 6.18.0modified #122 SMP PREEMPT_DYNAMIC Thu May  7 23:30:15 UTC 2026 x86_64 x86_64 x86_64 GNU/Linux` |
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
| mbench command | `timeout --signal=TERM 900 /root/mbench --csv --quiet --sample-ms 10000 --ops-per-pass 65536 --pause-ns 100000 --arena-size 64G --mode skewed-hotset --window-size 32G --window-offset 0 --move-policy fixed --hotset-pages 8388608 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --hotset-index-mode mulshift --hotset-prefault-node 1 --threads 32 --duration-ms 600000` |

Initial cgroup residency after prefault:

| node | anon bytes | GiB |
| --- | ---: | ---: |
| node0 | `16,403,914,752` | `15.28` |
| node1 | `52,315,631,616` | `48.72` |

## Result

| metric | value |
| --- | ---: |
| total ops | `270,317,453,312` |
| 600s average | `450.53 Mops/s` |
| steady mean | `460.62 Mops/s` |
| steady median | `475.61 Mops/s` |
| first 10s | `246.84 Mops/s` |
| last 10s | `475.10 Mops/s` |
| HSS | `8,388,608` pages (`32 GiB`) |
| promotion candidates | `62,078,509` |
| candidate/HSS | `740.03%` event volume |
| promoted | `4,165,175` pages (`15.89 GiB`) |
| promoted/HSS | `49.65%` |
| promoted/candidate | `6.71%` |
| demoted | `4,107,082` pages (`15.67 GiB`) |
| over-high failures | `57,912,073` pages/events (`220.92 GiB event volume`) |
| latency pass/fail | `62,078,509` / `17,958,617` |
| rate-limited | `0` |
| hint faults | `80,453,658` |
| `pgmigrate_fail` | `57,913,036` |
| reclaimd run/wake | `6` / `6` |

## 10s Timeline

Full live counter timeline: `/Serverless/iccd/experiments/20260508-friendly-hss32-scan4096-600s-cgroup-statefix/summaries/timeline_10s_live.csv`
Combined measurement timeline: `/Serverless/iccd/experiments/20260508-friendly-hss32-scan4096-600s-cgroup-statefix/summaries/timeline_10s_combined.csv`

The combined table aligns mbench measured time with live counters after the fixed 20s warmup. Candidate/HSS is event volume, not unique page coverage.

| measured interval | ops/s | promote delta | demote delta | candidate delta | over-high delta | promote total | candidate total | anon N0/N1 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `0-10s` | `246.84 Mops/s` | `441,344` | `441,344` | `1,276,785` | `835,390` | `1,308,644` | `3,411,573` | `15.68/48.32 GiB` |
| `10-20s` | `261.89 Mops/s` | `135,529` | `319,616` | `536,990` | `401,269` | `1,444,173` | `3,948,563` | `14.98/49.02 GiB` |
| `20-30s` | `267.58 Mops/s` | `369,046` | `204,544` | `667,213` | `298,168` | `1,813,219` | `4,615,776` | `15.61/48.40 GiB` |
| `30-40s` | `285.28 Mops/s` | `425,285` | `456,320` | `814,645` | `389,506` | `2,238,504` | `5,430,421` | `15.49/48.51 GiB` |
| `40-50s` | `306.47 Mops/s` | `470,906` | `468,480` | `958,700` | `487,645` | `2,709,410` | `6,389,121` | `15.50/48.50 GiB` |
| `50-60s` | `331.29 Mops/s` | `202,762` | `444,352` | `342,380` | `139,618` | `2,912,172` | `6,731,501` | `14.57/49.43 GiB` |
| `60-70s` | `337.63 Mops/s` | `0` | `0` | `0` | `0` | `2,912,172` | `6,731,501` | `14.57/49.43 GiB` |
| `70-80s` | `348.08 Mops/s` | `465,032` | `191,296` | `755,345` | `290,311` | `3,377,204` | `7,486,846` | `15.62/48.38 GiB` |
| `80-90s` | `386.20 Mops/s` | `332,143` | `389,184` | `1,000,556` | `668,405` | `3,709,347` | `8,487,402` | `15.40/48.60 GiB` |
| `90-100s` | `431.53 Mops/s` | `412,612` | `339,524` | `1,489,298` | `1,076,790` | `4,121,959` | `9,976,700` | `15.68/48.32 GiB` |
| `100-110s` | `484.92 Mops/s` | `326` | `1,720` | `733,171` | `732,741` | `4,122,285` | `10,709,871` | `15.67/48.33 GiB` |
| `110-120s` | `477.36 Mops/s` | `5` | `572` | `5` | `0` | `4,122,290` | `10,709,876` | `15.67/48.33 GiB` |
| `540-550s` | `469.66 Mops/s` | `565` | `537` | `1,416,729` | `1,416,156` | `4,162,025` | `57,151,748` | `15.68/48.32 GiB` |
| `550-560s` | `478.81 Mops/s` | `10` | `681` | `646,584` | `646,574` | `4,162,035` | `57,798,332` | `15.68/48.32 GiB` |
| `560-570s` | `469.66 Mops/s` | `945` | `334` | `1,011,609` | `1,010,664` | `4,162,980` | `58,809,941` | `15.68/48.32 GiB` |
| `570-580s` | `477.69 Mops/s` | `866` | `806` | `1,391,123` | `1,390,442` | `4,163,846` | `60,201,064` | `15.68/48.32 GiB` |
| `580-590s` | `473.96 Mops/s` | `1,012` | `1,011` | `1,230,432` | `1,229,177` | `4,164,858` | `61,431,496` | `15.68/48.32 GiB` |
| `590-600s` | `475.10 Mops/s` | `304` | `12,658` | `647,013` | `646,709` | `4,165,162` | `62,078,509` | `9.82/42.04 GiB` |

## Interpretation

The previous 8 GiB promotion plateau was a microbenchmark artifact from resetting the mulshift index state every pass. With persistent state, the run now generates `62.08M` promotion-candidate events and promotes `15.89 GiB`, essentially up to the 16 GiB local capacity window rather than stopping at the old per-pass 8 GiB footprint.

The workload is now actually traversing the 32 GiB hotset over time, which also explains the much lower throughput: the old run repeatedly hit only about 8 GiB of the hotset and reported about `1.66 Gops/s`; this corrected run averages `450.53 Mops/s` and ends around `475.10 Mops/s`. Promotion still does not reach the full 32 GiB HSS because the cgroup local cap/headroom path rejects most repeated promotion attempts once node0 is full: over-high failures are `57,912,073`, while rate-limit blocks remain zero.

Artifacts:

- raw run: `/Serverless/iccd/experiments/20260508-friendly-hss32-scan4096-600s-cgroup-statefix/qemu-logs/phase_candidate_microbench/friendly_hss32_scan4096_600s_cgroup_on_statefix_20260508T055000Z`
- case dir: `/Serverless/iccd/experiments/20260508-friendly-hss32-scan4096-600s-cgroup-statefix/qemu-logs/phase_candidate_microbench/friendly_hss32_scan4096_600s_cgroup_on_statefix_20260508T055000Z/guest-artifacts/friendly_hss32_scan4096_600s_cgroup_on_statefix_20260508T055000Z/skew_lf_hotremote_32g_fixed_rss16g_mulshift_persistent__on__rep1`
