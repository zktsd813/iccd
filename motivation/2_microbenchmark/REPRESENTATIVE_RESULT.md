# Representative Microbenchmark Result

대표 결과는 shared-window thread sweep의 가장 긴 run인
`20260603-microbenchmark-shared-thread-sweep-t960-cal120`이다.

선택 이유:
- `TARGET_SECONDS=960`, `CALIBRATE_MS=120000`으로 가장 긴 fixed-op run이다.
- 짧은 run에서 보이던 ratio noise가 줄어들어 on/off slowdown이 안정화됐다.
- 32-thread shared-window baseline collapse가 긴 run에서도 재현됐다.

설정:
- workload: `stream_read_32g_split16_4kstride`
- VM memory: fast 16G, slow 64G, `host-cxl`
- address window: 32G, local first-touch split: 16G
- mode: `--bw-shared-window=1`
- policy: `off` = `numa_balancing=0`, `on` = `numa_balancing=2`
- guest state: `lru_gen_enabled=0x0007`, demotion enabled, node0/node1 memory tiers split

## Result

| threads | off elapsed (s) | on elapsed (s) | on/off time | off Mops/s | on Mops/s | on migrated GiB | on demoted GiB |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 937.734 | 1222.908 | 1.304x | 56.3 | 43.2 | 6.48 | 8.22 |
| 4 | 978.467 | 1347.122 | 1.377x | 269.4 | 195.7 | 8.32 | 9.18 |
| 8 | 951.788 | 1291.236 | 1.357x | 545.3 | 402.0 | 12.18 | 13.02 |
| 16 | 955.548 | 1238.457 | 1.296x | 934.2 | 720.8 | 12.96 | 13.81 |
| 32 | 997.667 | 1276.681 | 1.280x | 172.5 | 134.8 | 9.03 | 9.86 |

## Interpretation

- Migration on slowdown is stable at about `1.28x-1.38x` in the long run.
- The earlier large 16-thread ratio was partly measurement noise.
- The 32-thread shared-window off baseline remains low: `16 threads off = 934.2 Mops/s`, but `32 threads off = 172.5 Mops/s`. This points to shared-window contention/collapse, not short-run noise.
- `perf stat` was unavailable in the guest, so the result uses mbench output, `/usr/bin/time`, vmstat, and PSI.

## Artifacts

- result root: `motivation/2_microbenchmark/results/20260603-microbenchmark-shared-thread-sweep-t960-cal120`
- detailed Korean summary: `summaries/summary_ko.md`
- CSV summary: `summaries/summary.csv`
- figures: `figures/shared_window_thread_sweep_execution_time.svg`, `figures/shared_window_thread_sweep_ratio.svg`
- common figure copy: `motivation/2_microbenchmark/figure`
