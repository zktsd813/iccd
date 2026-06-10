# Shared 32-thread local memory sweep 결과 요약

설정: hotset 32G, shared-window, 32 threads, fixed target ops.
공통 target ops: `43686414250`.
32G point는 remote split이 없으므로 `bind:0` placement를 사용한다.

| local GiB | off elapsed (s) | on elapsed (s) | time ratio | off Mops/s | on Mops/s | migrated GiB | demoted GiB | hint faults | system CPU (s) |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 16 | 265.279 | 302.211 | 1.139x | 165.7 | 145.4 | 0.00 | 0.92 | 36398651 | 2033.35 |

## 해석 포인트

- 가장 큰 on/off time ratio는 local 16G의 `1.139x`이다.
- migration on 처리량이 가장 높은 조건은 local 16G의 `145.4 Mops/s`이다.
- scan period/scan size 계열 knob은 쓰지 않고 kernel 기본값을 기록만 한다.
- migration stat은 vmstat delta 기준이며 demotion은 `pgdemote_direct + pgdemote_kswapd`이다.
