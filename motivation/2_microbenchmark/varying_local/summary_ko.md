# Shared 32-thread local memory sweep 결과 요약

설정: hotset 32G, shared-window, 32 threads, fixed target ops.
공통 target ops: `43686414250`.
32G point는 remote split이 없으므로 `bind:0` placement를 사용한다.

| local GiB | off elapsed (s) | on elapsed (s) | time ratio | off Mops/s | on Mops/s | migrated GiB | demoted GiB | hint faults | system CPU (s) |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 8 | 395.294 | 648.367 | 1.640x | 111.2 | 67.8 | 67.45 | 68.15 | 84795776 | 5557.26 |
| 12 | 325.105 | 671.888 | 2.067x | 135.2 | 65.5 | 10.51 | 11.24 | 71173046 | 4752.87 |
| 16 | 261.023 | 699.074 | 2.678x | 168.4 | 63.0 | 10.45 | 11.36 | 63077572 | 4189.66 |
| 20 | 194.145 | 685.115 | 3.529x | 226.4 | 64.2 | 35.94 | 36.93 | 50301031 | 3436.28 |
| 24 | 128.670 | 572.967 | 4.453x | 341.6 | 76.9 | 22.59 | 23.72 | 35018152 | 2325.54 |
| 28 | 76.037 | 408.974 | 5.379x | 578.1 | 107.5 | 20.34 | 21.59 | 17949367 | 1140.55 |
| 32 | 60.883 | 57.208 | 0.940x | 722.3 | 768.9 | 0.00 | 1.35 | 113 | 15.78 |

## 해석 포인트

- 가장 큰 on/off time ratio는 local 28G의 `5.379x`이다.
- migration on 처리량이 가장 높은 조건은 local 32G의 `768.9 Mops/s`이다.
- scan period/scan size 계열 knob은 쓰지 않고 kernel 기본값을 기록만 한다.
- migration stat은 vmstat delta 기준이며 demotion은 `pgdemote_direct + pgdemote_kswapd`이다.
