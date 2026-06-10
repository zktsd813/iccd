# Interleave initial placement sweep 결과 요약

설정: hotset/window 32G, shared-window, 32 threads, fixed target ops.
공통 target ops: `43686414250`.
`all_slow`는 32G 전체를 node1 slow에 first-touch하고 시작한다.
`half_local`은 local memory size의 절반만 node0 local에 first-touch하고 시작한다.
Linux MPOL_INTERLEAVE 정책은 사용하지 않는다.

| mode | local GiB | initial local GiB | off elapsed (s) | on elapsed (s) | time ratio | off Mops/s | on Mops/s | migrated GiB | demoted GiB | hint faults | system CPU (s) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| all_slow | 8 | 0.0 | 500.626 | 879.518 | 1.757x | 87.8 | 50.0 | 164.34 | 157.30 | 135637492 | 8919.13 |
| all_slow | 12 | 0.0 | 503.538 | 750.365 | 1.490x | 87.3 | 58.7 | 46.06 | 35.10 | 86883465 | 5852.45 |
| all_slow | 16 | 0.0 | 499.373 | 845.946 | 1.694x | 88.0 | 52.2 | 41.38 | 26.48 | 88297885 | 5927.81 |
| all_slow | 20 | 0.0 | 497.980 | 797.515 | 1.601x | 88.3 | 55.2 | 45.20 | 26.37 | 76035661 | 5141.12 |
| all_slow | 24 | 0.0 | 500.959 | 773.933 | 1.545x | 87.7 | 57.0 | 43.46 | 20.86 | 66788325 | 4422.47 |
| all_slow | 28 | 0.0 | 497.927 | 342.122 | 0.687x | 88.3 | 128.7 | 33.99 | 7.41 | 31037323 | 1940.67 |
| all_slow | 32 | 0.0 | 499.363 | 237.659 | 0.476x | 88.0 | 185.3 | 31.70 | 1.25 | 16915913 | 969.21 |
| half_local | 8 | 4.0 | 431.809 | 745.872 | 1.727x | 101.8 | 59.0 | 108.20 | 105.17 | 103978446 | 6850.36 |
| half_local | 12 | 6.0 | 407.828 | 669.506 | 1.642x | 107.8 | 65.7 | 25.10 | 20.11 | 69945212 | 4602.27 |
| half_local | 16 | 8.0 | 377.248 | 725.132 | 1.922x | 116.5 | 60.7 | 25.27 | 18.35 | 72887153 | 4820.41 |
| half_local | 20 | 10.0 | 347.964 | 653.466 | 1.878x | 126.3 | 67.3 | 25.17 | 16.38 | 51946328 | 3419.97 |
| half_local | 24 | 12.0 | 311.890 | 621.760 | 1.994x | 140.9 | 70.7 | 35.88 | 25.21 | 43696802 | 2761.10 |
| half_local | 28 | 14.0 | 278.204 | 329.596 | 1.185x | 158.0 | 133.4 | 20.86 | 8.32 | 20401421 | 1263.20 |
| half_local | 32 | 16.0 | 244.358 | 170.969 | 0.700x | 179.9 | 257.2 | 15.48 | 1.05 | 8980227 | 506.76 |

## 해석 포인트

- 가장 큰 on/off time ratio는 `half_local` local 24G의 `1.994x`이다.
- migration on에서 가장 많이 migrate된 조건은 `all_slow` local 8G의 `164.34 GiB`이다.
- migration stat은 vmstat delta 기준이며 demotion은 `pgdemote_direct + pgdemote_kswapd`이다.
