# 2026-07-10 세션 인계 문서: VM 컨트롤러 튜닝과 샘플링 이상 분석

최종 업데이트: 2026-07-10 UTC

이 문서는 이번 세션에서 진행한 VM 기반 CXL/NUMA memory tiering 실험,
Silo/GUPS 컨트롤러 튜닝, quantile/CDF 정책 변경, 커널 샘플링 이상 분석,
그리고 마지막 perf 기반 memory access 검증 결과를 정리한다.

## 0. 중요 정정: Silo main phase 오분류

이 문서의 초기 분석은 Silo의 `timed region dataloading` 종료 시점을 main
phase 시작으로 사용했지만, 이는 잘못됐다. 확정된 원인과 정정된 수치는
`docs/silo-sampling-root-cause-20260710.md`에 정리했다.

- Silo는 `starting benchmark...`를 출력한 뒤 32개 worker를 직렬 생성한다.
- 각 worker는 8억 항목 Zipf `zeta()`를 다시 계산한다.
- low-sample 구간 약 186-470초는 transaction main이 아니라 이 초기화 단계다.
- perf로 확인한 실제 main은 약 470.7-735.9초다.
- 실제 main과 겹치는 W31-W53은 23개 모두 valid이며 local/remote sample이
  지속적으로 수집된다.
- Silo 진단에서 `starting benchmark`를 phase marker로 쓰지 않고, log gate를
  명시적으로 켠 경우 첫 throughput 출력을 사용한다.

따라서 아래 8.4절과 11절의 "main-phase low-sample" 해석은 폐기한다. 문제의
원인은 kernel sampler가 아니라 phase marker와 perf 의미를 잘못 해석한 것이다.

## 1. 계속 진행할 때 지켜야 할 규칙

- 사용자가 명시적으로 요청하기 전에는 절대 재부팅하지 않는다.
- 사용자가 VM 실험을 요청한 경우 host에서 workload를 돌리지 않는다.
- VM 실험 스크립트와 host-native 실험 스크립트는 분리해서 운용한다.
- 다만 controller 정책 자체는 VM/host가 공유해야 한다. 현재 공유 경로는
  `design/fault_bucket_controller/run_guest.sh`와
  `design/fault_bucket_controller/bucket_latency_controller.py`이다.
- 이번 계열의 VM 실험은 기본적으로 SMT off로 진행한다.
  - `DISABLE_SMT=1`
  - `RESTORE_SMT=0`
- VM local memory는 `LOCAL_SIZES_GIB`로 조절한다.
- remote memory는 VM node1로 노출되며, 일반적으로 host node2에 bind된
  `MIGRATION_SLOW_MEM=192G`를 사용한다.
- VM rootfs overlay는 page cache 영향을 줄이기 위해 `cache=none,aio=native`
  조합을 사용한다.
- 비교 실험에서는 host page cache를 VM boot 전과 guest run 전에 drop한다.
- guest 내부에서도 workload 사이에 cache drop과 memory compaction을 수행한다.
- Silo는 사용자가 명시적으로 바꾸라고 하기 전까지 다음 설정으로 고정한다.
  - jemalloc build 사용
  - tail hotset 사용
  - `--bench ycsb`
  - `--num-threads 32`
  - `--scale-factor 800000`
  - `--ops-per-worker=100000000`
  - `--bench-opts=--zipf-reverse`
- Silo allocator, hotset 방향, workload scale, VM placement, GAPBS graph mode를
  사용자 허락 없이 바꾸지 않는다.
- GAPBS PR/BC는 generated graph mode만 사용한다.
  - `-g 29`
  - graph build time 포함
  - prebuilt `.sg` graph 사용 금지

## 2. 현재 baseline 위치

이번 세션 중 baseline 결과를 별도 디렉터리로 복사했다.

- baseline root: `baseline/`
- baseline 설명 문서: `baseline/EXPERIMENT_BASELINE.md`
- baseline README: `baseline/README.md`
- frozen baseline run:
  `baseline/20260710T-local32-48-onoff-controller-tail-jemalloc`
- 원본 run:
  `motivation/3_realworld/VM/results/20260710T-local32-48-onoff-controller-tail-jemalloc`
- summary CSV:
  `baseline/20260710T-local32-48-onoff-controller-tail-jemalloc/summaries/summary.csv`
- 고정 on/off reference:
  `baseline/fixed-onoff-reference.csv`

앞으로 on/off 비교는 사용자가 새 baseline을 요구하지 않는 한 아래 값을 고정
reference로 사용한다.

| Local GiB | Workload | off elapsed s | on elapsed s | Source |
| ---: | --- | ---: | ---: | --- |
| 16 | silo | 886 | 714 | `motivation/3_realworld/VM/results/20260709T-local16-onoff-tail-jemalloc-rerun/summaries/summary.csv` |
| 48 | gups | 288 | 872 | `baseline/20260710T-local32-48-onoff-controller-tail-jemalloc/summaries/summary.csv` |

주의:

- 16 GiB Silo reference는 32/48 GiB frozen baseline run 안에는 없다.
- 하지만 tail-hotset jemalloc Silo 설정으로 재실험한 고정값이므로 현재
  Silo 16 GiB 비교의 기준으로 사용한다.

## 3. 세션 전체 흐름

### 3.1 시작 목표

처음 목표는 다음과 같았다.

- SMT를 끈 VM에서 실험한다.
- local memory 16 GiB 기준으로 시작한다.
- Silo와 Liblinear에 대해 quantile 분석을 진행한다.
- migration이 꺼져도 histogram/quantile이 계속 켜져 있는 새 knob의 overhead도
  함께 확인한다.
- VM image page cache 영향이 결과에 섞이지 않도록 한다.

### 3.2 초반 교정 사항

세션 초반에는 host에서 돌아간 듯한 흔적과 VM/host 정책 혼동이 있었다. 이후
다음 방향으로 정리했다.

- VM 실험은 VM에서만 진행한다.
- host 설정은 VM 실행에 필요한 리소스만 제공하고, workload는 guest 안에서 실행한다.
- 재부팅은 사용자가 명령하기 전까지 하지 않는다.
- controller 정책은 VM/host에서 통일하되, 실험 실행 스크립트는 따로 둔다.
- host memory/cpu 제한은 원복하고 VM 설정으로 자원 제한을 적용한다.

### 3.3 Liblinear 제외

Liblinear는 RSS가 약 13 GiB 수준으로 확인되었다. 16 GiB local memory 기준의
압박 실험으로 보기 애매하므로 이번 정책 분석에서는 Liblinear를 제외하고
Silo 중심으로 전환했다.

## 4. Silo hotset과 friendly/unfriendly 구분

Silo 코드와 parameter를 확인한 뒤, hotset이 앞쪽 key에 몰리는 경우와 뒤쪽
key에 몰리는 경우를 나누어 보았다.

- tail hotset은 `--zipf-reverse`로 설정한다.
- 이후 Silo는 tail hotset으로 통일했다.
- allocator는 jemalloc으로 통일했다.
- 사용자가 허락하지 않은 allocator 변경은 하지 않는 것으로 정리했다.

핵심 관찰:

- 16 GiB tail-hotset Silo에서는 migration-on이 off보다 빠르다.
- fixed reference:
  - off: 886s
  - on: 714s
- 따라서 Silo tail-hotset은 migration-friendly 쪽으로 볼 수 있다.
- 하지만 migration-friendly라고 해서 migration을 끝까지 켜야 한다는 뜻은 아니다.
- 충분히 좋은 page movement가 끝난 뒤에는 migration을 끄는 편이 더 나을 수 있다는
  방향으로 controller tuning을 진행했다.

## 5. Controller 정책 변화

### 5.1 초기 quantile 기반 접근

초기에는 local/remote quantile을 보고 migration stop/restart를 판단했다.
논의 중 다음 기준으로 정리되었다.

- local은 P75를 본다.
- remote는 tail이 아니라 head 쪽을 봐야 한다.
- 따라서 remote는 P25를 본다.
- 핵심 비교는 `local P75`와 `remote P25`이다.

의미:

- `local P75 > remote P25`이면 local tail보다 빠른 remote candidate가 존재한다.
- 이 경우 migration이 유효할 수 있다.
- 반대로 gap이 좁아지지 않거나 candidate capacity가 충분하지 않으면 stop 후보가 된다.

### 5.2 stdout main-phase gating

한때 Silo stdout의 throughput 출력을 보고 main phase 시작 후 10초 또는 60초 뒤부터
stop 판단을 시작하는 방식을 테스트했다.

그러나 사용자가 지적한 대로 controller는 다른 workload에도 적용되어야 하므로,
stdout 기반 main-phase gating은 default 정책에서 제외했다.

정리:

- stdout gating은 workload-specific diagnostic으로만 사용한다.
- default controller policy는 stdout 의존성을 가지면 안 된다.

### 5.3 window 정의 변경

사용자가 요구한 window 정의:

- 단순 1초 timer window가 아니라 remote memory tiering scan이 한 바퀴 돈 것을
  기준으로 window를 전진해야 한다.

현재 방향:

- `WINDOW_MODE=remote-cycle`
- `CYCLE_WINDOW_STAT=remote_scan_cycles`
- `ADVANCE_WINDOW=0`
- `local_fault_window_auto_advance=0`
- window duration clamp:
  - min 5s
  - max 20s

GUPS에서 remote scan cycle 기반 window가 너무 느려지는 문제가 있었기 때문에
5초-20초 clamp를 추가했다.

### 5.4 현재 controller 설정

현재 controller baseline 설정은 다음과 같다.

```text
WINDOW_SEC=1
WINDOW_MODE=remote-cycle
CYCLE_WINDOW_STAT=remote_scan_cycles
CYCLE_WINDOW_MIN_SEC=5
CYCLE_WINDOW_MAX_SEC=20
INPUT_MODE=quantile
STOP_POLICY=selected-gap
RESTART_POLICY=selected-gap-immediate
LOCAL_RATE=5
LOCAL_FAULT_SCAN_PERIOD_MS=1000
LOCAL_FAULT_SCAN_SIZE_MB=64
MIN_LOCAL_PAGES=1024
MIN_REMOTE_PAGES=1024
LOCAL_QUANTILE_PERCENTILE=75
REMOTE_QUANTILE_PERCENTILE=25
BASELINE_SKIP_WINDOWS=0
CONSECUTIVE_EFFECTIVE=3  # score policy only
CONSECUTIVE_NO_IMPROVE=2  # score policy only
EFFECTIVE_SCORE_THRESHOLD=0.75  # score policy only
SCORE_EPSILON=0.05  # score policy only
EWMA_ALPHA=1.0
RESTART_CAPACITY_GUARD_THRESHOLD=0.9
RESTART_CAPACITY_GUARD_SOURCE=resident
INITIAL_STOP_ONLY=0
MONITOR_AFTER_STOP=0
STOP_FAULT_SAMPLING_ON_STOP=0
STOP_ACTION=observe
NUMA_BALANCING_ON=2
NUMA_BALANCING_OFF=0
```

## 6. CDF/capacity 기반 정책

사용자가 제안한 핵심 문제는 point quantile만 보면 memory capacity 정보가 빠진다는
것이었다. 이 제안을 controller에 반영했다.

정책 직관:

1. local P75 latency를 A로 둔다.
2. remote에서 latency A 이하인 page 비율을 CDF로 구한다.
3. local P75 기준 local tail은 local resident memory의 25%이다.
4. remote candidate는 remote resident memory 곱하기 `remote_cdf(A)`이다.
5. local tail 후보량과 remote candidate 후보량을 비교한다.
6. 최종 판단에는 오차를 감안해 10% room을 둔다.

중요한 정정:

- A는 latency 값이다.
- A에 75가 들어가는 것이 아니다.
- local P75 latency 값을 query latency로 사용한다.
- local CDF는 P75라는 사실 때문에 이미 75%로 고정되어 있으므로 별도로 구할 필요가 없다.

관련 sysfs:

- `/sys/kernel/mm/numa_balancing/fault_latency_cdf_query_ns`

controller CSV에는 다음 류의 값이 기록된다.

- `cdf_query_ns`
- `local_cdf_le_query_ppm`
- `remote_cdf_le_query_ppm`
- `restart_capacity_guard_*`
- `restart_capacity_ratio`
- `restart_capacity_suppressed`

## 7. Kernel/controller 계측 변경

### 7.1 remote sampler 제거 방향

사용자가 remote sampler 관련 코드를 모두 제거하고 더 이상 언급하지 말라고 요청했다.
현재 방향은 다음과 같다.

- 별도 remote sampler를 controller 정책 근거로 쓰지 않는다.
- window 기준은 일반 memory tiering의 remote scan cycle이다.
- local sampler는 local fault/refault 관찰용으로 유지한다.

### 7.2 PTE skip counter 추가

샘플이 사라지는 이유를 추적하기 위해 PTE-level skip counter를 추가했다.

관련 파일:

- `linux/include/linux/memcontrol.h`
- `linux/mm/mprotect.c`
- `linux/mm/huge_memory.c`
- `linux/mm/numa_balancing.c`
- `design/fault_bucket_controller/bucket_latency_controller.py`

추가된 remote scan skip reason:

- `remote_scan_skip_total`
- `remote_scan_skip_protnone`
- `remote_scan_skip_no_folio`
- `remote_scan_skip_zone_device_ksm`
- `remote_scan_skip_cow_shared`
- `remote_scan_skip_dirty_file`
- `remote_scan_skip_balancing_disabled`
- `remote_scan_skip_same_node`
- `remote_scan_skip_top_tier_disabled`
- `remote_scan_skip_unknown`

추가된 local sampler 관련 counter:

- `local_fault_pfn_scanned`
- `local_fault_skip_no_page_or_wrong_node`
- `local_fault_skip_not_lru`
- `local_fault_skip_large`
- `local_fault_skip_unmapped`
- `local_fault_skip_already_sampled`
- `local_fault_skip_seen_window`
- `local_fault_skip_not_selected`
- `local_fault_install_failed`

controller는 이 raw counter들과 delta를 CSV로 기록한다.

### 7.3 pid-inactive VMA skip 가설

한때 `vma_is_accessed()`가 false라서 VMA scan이 skip되는 것이 원인일 가능성을
확인했다.

관련 코드:

```c
if (!vma_pids_forced && !vma_is_accessed(mm, vma)) {
```

테스트:

- 해당 조건을 임시로 우회해서 Silo를 돌렸다.
- 하지만 이것만으로 샘플 부족 현상이 설명되지 않았다.
- 이후 코드는 원래 조건으로 복구했다.

현재 상태:

- `pid_inactive` bypass diagnostic patch는 되돌려져 있다.
- `vma_is_accessed()` 조건은 원본 구조로 남아 있다.

### 7.4 perf attach diagnostic 추가

마지막에 VM 안에서 실제 memory access가 있는지 확인하기 위해 optional perf attach를
추가했다.

관련 파일:

- `design/fault_bucket_controller/run_guest.sh`
- `motivation/3_realworld/VM/scripts/run_workload_case_guest.sh`
- `motivation/3_realworld/VM/scripts/run_vm_sweep_guest.sh`
- `motivation/3_realworld/VM/scripts/run_vm_sweep_host.sh`

새 환경 변수:

- `PERF_ATTACH_EVENTS`
- `PERF_ATTACH_INTERVAL_MS`
- `PERF_ATTACH_OUTPUT`
- `PERF_ATTACH_EXTRA_ARGS`
- `PERF_ATTACH_FILTER_UNSUPPORTED`
- `PERF_ATTACH_BIN`

주의:

- 첫 perf run은 `/usr/bin/time` wrapper PID에 attach되어 invalid였다.
- 이후 leaf child PID를 찾아 실제 `dbtest` PID에 attach하도록 수정했다.
- perf attach run은 diagnostic 전용이다.
- perf attach run의 elapsed time은 성능 비교에 사용하지 않는다.

검증한 문법:

```bash
bash -n design/fault_bucket_controller/run_guest.sh
bash -n motivation/3_realworld/VM/scripts/run_workload_case_guest.sh
bash -n motivation/3_realworld/VM/scripts/run_vm_sweep_guest.sh
bash -n motivation/3_realworld/VM/scripts/run_vm_sweep_host.sh
```

## 8. 핵심 실험 결과

### 8.1 16 GiB Silo on/off 고정 reference

Run:

`motivation/3_realworld/VM/results/20260709T-local16-onoff-tail-jemalloc-rerun`

| Local GiB | Workload | Config | elapsed s | N0 GiB | N1 GiB | promoted GiB | demoted GiB | hint faults |
| ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 16 | silo | off | 886 | 15.146702 | 100.542686 | 0.000000 | 0.000000 | 0 |
| 16 | silo | on | 714 | 15.554367 | 101.265865 | 55.007324 | 88.360107 | 109,934,595 |

결론:

- 16 GiB tail-hotset Silo에서는 migration-on이 off보다 빠르다.
- 현재 Silo friendly case의 고정 on/off 비교값으로 사용한다.

### 8.2 16 GiB Silo controller reference

Run:

`motivation/3_realworld/VM/results/20260710T-local16-controller-tail-jemalloc-rerun`

| Local GiB | Workload | Config | elapsed s | promoted GiB | demoted GiB | hint faults | first stop | final state | restarts |
| ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | --- | ---: |
| 16 | silo | controller_0x2 | 698 | 58.343300 | 84.259727 | 119,471,149 | 663.423s W15 | off | 0 |

결론:

- 이 run에서는 controller가 698s로 migration-on reference 714s보다 조금 빠르다.
- 여기서는 early stop 문제가 강하게 나타나지 않았다.

### 8.3 PTE skip counter Silo diagnostic

Run:

`motivation/3_realworld/VM/results/20260710T-silo-local16-pte-skip-counters`

요약:

- elapsed: 734s
- dataloading: 196.682s
- benchmark runtime: 240.335s
- first stop: W12, 206.268s
- final state: off
- promoted: 0.115 GiB
- demoted: 32.658 GiB
- hint faults: 126,980,531
- migration disabled reject pages: 117,370,059

대표 window:

| Window | remote pte updates delta | protnone skip delta | hint faults delta | local refault delta | 해석 |
| ---: | ---: | ---: | ---: | ---: | --- |
| W18 | 10,908 | 10,426,308 | 24 | 1 | protected remote set이 거의 hit되지 않음 |
| W19 | 24 | 17,054,342 | 1 | 0 | 동일 |
| W20 | 0 | 10,998,131 | 27 | 1 | 동일 |
| W23 | 0 | 15,595,277 | 26 | 2 | 동일 |
| W27 | 0 | 14,310,431 | 22 | 2 | 동일 |
| W28 | 5,201,765 | 7,113,112 | 32,448,099 | 3,242,626 | 실제 transaction 시작과 겹친 첫 window |

정정된 해석:

- W18-W27은 main이 아니라 worker/Zipf 초기화 구간이다.
- W28부터 실제 transaction이 시작되어 fault/sample이 지속적으로 발생한다.
- 따라서 이 표는 장시간 공간적 불일치의 증거가 아니다.

### 8.4 perf access check

유효한 run:

`motivation/3_realworld/VM/results/20260710T-silo-local16-perf-access-check-v2`

무효 run:

`motivation/3_realworld/VM/results/20260710T-silo-local16-perf-access-check`

무효 이유:

- perf가 실제 `dbtest`가 아니라 wrapper PID에 attach되었다.
- perf 결과가 `<not counted>`로 나왔다.

유효 run 설정:

```bash
RUN_ID=20260710T-silo-local16-perf-access-check-v2
LOCAL_SIZES_GIB='16'
CONFIGS='controller_0x2'
WORKLOADS='silo'
DISABLE_SMT=1
RESTORE_SMT=0
ROOTFS_VIRTUAL_SIZE=120G
MIGRATION_SLOW_MEM=192G
FORBID_HOST_NODE1=1
NUMA_SCAN_SIZE_MB=256
NUMA_SCAN_PERIOD_MIN_MS=1000
DROP_HOST_CACHES_BEFORE_VM_BOOT=1
DROP_HOST_CACHES_BEFORE_GUEST_RUN=1
DROP_GUEST_CACHES=1
COMPACT_GUEST_MEMORY=1
CONTROLLER_STOP_POLICY=selected-gap
CONTROLLER_RESTART_POLICY=selected-gap-immediate
CONTROLLER_RESTART_CAPACITY_GUARD_THRESHOLD=0.9
CONTROLLER_RESTART_CAPACITY_GUARD_SOURCE=resident
CONTROLLER_CYCLE_WINDOW_MIN_SEC=5
CONTROLLER_CYCLE_WINDOW_MAX_SEC=20
SILO_ZIPF_REVERSE=1
PERF_BIN_HOST=/Serverless/iccd-git/linux-perf-min-build/perf
PERF_ATTACH_INTERVAL_MS=1000
PERF_ATTACH_FILTER_UNSUPPORTED=1
```

perf events:

```text
cycles
instructions
cache-references
cache-misses
branches
branch-misses
page-faults
minor-faults
major-faults
L1-dcache-loads
L1-dcache-load-misses
dTLB-loads
dTLB-load-misses
mem_inst_retired.all_loads
mem_inst_retired.all_stores
```

run 요약:

- elapsed: 753s
- 이 elapsed는 perf overhead 때문에 성능 비교용으로 쓰면 안 된다.
- Silo dataloading: 186.142s
- Silo benchmark runtime: 265.26s
- worker/Zipf 초기화: 약 186.142s부터 470.7s까지
- 실제 transaction main: 약 470.7s부터 735.9s까지
- Silo aggregate throughput: `1.20224e+07 ops/sec`
- first stop: W12, 205.567s
- final state: off
- restart events: 0
- promoted: 0.229855 GiB
- demoted: 23.178268 GiB
- hint faults: 140,488,989
- migration disabled reject pages: 129,574,934

핵심 결론:

**실제 transaction main에서는 sample이 정상적으로 수집됐다.**

기존에 main으로 잘못 분류한 worker 초기화 window:

| Window | elapsed s | hint faults delta | local refault delta | remote pte updates delta | protnone skip delta | perf loads/s | perf stores/s | throughput |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| W18 | 311.6 | 2 | 1 | 0 | 15,295,563 | 3.36G/s | 0.36G/s | 해당 없음 |
| W19 | 316.6 | 4 | 0 | 33 | 3,029,292 | 3.37G/s | 0.36G/s | 해당 없음 |
| W24 | 393.7 | 4 | 2 | 2 | 2,632,521 | 3.39G/s | 0.36G/s | 해당 없음 |

이 표에 이전에 붙인 throughput 값은 Silo 내부 timer와 workload wall time을
혼합한 잘못된 매칭이었다. `time: N throughput`의 timer는 worker 초기화가 끝난
뒤 시작하므로 W18/W19/W24와 같은 wall-time window에 대응하지 않는다.

실제 main과 겹치는 W31-W53:

- 23개 window 모두 valid
- local sample 합계: 6,913,640
- remote sample 합계: 110,268,674
- NUMA hint fault 합계: 136,890,360
- local/window 최소 70,679, 중앙값 83,426
- remote/window 최소 1,616,495, 중앙값 2,189,192

low-sample 구간의 perf load/store는 DB hot-set access가 아니라 직렬 Zipf
`zeta()/pow()` 계산이었다. data loading 중 보호된 DB PTE를 이 계산이 접근하지
않았기 때문에 fault가 없었던 것이 정상이다.

## 9. 32 GiB / 48 GiB baseline snapshot

Run:

`baseline/20260710T-local32-48-onoff-controller-tail-jemalloc`

elapsed time:

| Local GiB | Workload | off | on | controller_0x2 |
| ---: | --- | ---: | ---: | ---: |
| 32 | pr | 803 | 809 | 819 |
| 32 | bc | 1074 | 873 | 929 |
| 32 | gups | 307 | 815 | 659 |
| 32 | btree | 547 | 650 | 664 |
| 32 | graph500 | 378 | 383 | 381 |
| 32 | silo | 856 | 662 | 685 |
| 48 | pr | 796 | 732 | 780 |
| 48 | bc | 1046 | 670 | 605 |
| 48 | gups | 288 | 872 | 882 |
| 48 | btree | 486 | 651 | 597 |
| 48 | graph500 | 342 | 336 | 373 |
| 48 | silo | 806 | 678 | 676 |

주요 해석:

- 32 GiB Silo: controller 685s, on 662s와 가깝고 off 856s보다 좋다.
- 48 GiB Silo: controller 676s, on 678s와 거의 같고 off 806s보다 좋다.
- 48 GiB GUPS: off 288s, on 872s, controller 882s. migration이 명확히 해로운
  unfriendly case이다.
- 48 GiB BC: controller 605s로 on 670s와 off 1046s보다 좋다.

## 10. GUPS와 unfriendly case

GUPS는 현재 대표적인 migration-unfriendly workload이다.

중요 run:

- `motivation/3_realworld/VM/results/20260710T-capacity-policy-verify-silo16-gups48`
- `motivation/3_realworld/VM/results/20260710T-gups48-window-clamp-5-20`
- `motivation/3_realworld/VM/results/20260710T-gups48-window-clamp-5-20-th09`

요약:

| Run | Local GiB | Workload | elapsed s | first stop | final state | restarts | promoted GiB | demoted GiB |
| --- | ---: | --- | ---: | ---: | --- | ---: | ---: | ---: |
| capacity verify | 48 | gups | 576 | 119.028s W3 | off | 2 | 2.579 | 3.526 |
| clamp 5-20 th09 | 48 | gups | 311 | 40.540s W2 | off | 0 | 0.348 | 0.566 |
| frozen baseline | 48 | gups | 882 | 159.093s W3 | off | 2 | 2.659 | 2.702 |

고정 on/off 기준:

- off: 288s
- on: 872s

따라서 GUPS는 controller가 매우 빨리 migration을 꺼야 하는 case이다.

## 11. 샘플링 이상에 대한 최종 해석

원인은 sampling/protected-set representativeness가 아니라 phase 오분류였다.

1. `starting benchmark...`는 실제 transaction 시작 전에 출력된다.
2. 이후 메인 스레드가 32개 worker를 직렬 생성한다.
3. 각 worker는 8억 항목 Zipf `zeta()`를 계산하므로 이 단계가 약 285초 걸린다.
4. W18/W19/W24의 수십억 perf load/store는 이 계산의 retired instruction이다.
5. worker가 실제로 실행된 약 470.7초부터 CPU concurrency와 NUMA fault가 동시에
   급증했다.
6. 실제 main의 W31-W53은 모두 local/remote sample validity 기준을 만족했다.

`remote_scan_skip_protnone`이 큰 이유도 설명된다. data loading 중 보호한 DB
page를 Zipf 초기화가 접근하지 않았으므로 해당 PTE가 PROT_NONE으로 남았다. 실제
transaction worker가 시작되자 fault가 즉시 대량 발생했다.

한 문장 결론:

> Silo main sample은 정상이다. low-sample로 보인 구간은 main phase가 아니라
> 직렬 worker/Zipf 초기화 단계였다.

## 12. 현재 코드 상태

현재 worktree는 dirty 상태이다. 사용자 변경과 이전 작업이 섞여 있으므로 관련 없는
변경을 되돌리면 안 된다.

이번 controller/sampling 흐름에서 중요한 파일:

- Kernel:
  - `linux/include/linux/memcontrol.h`
  - `linux/kernel/sched/fair.c`
  - `linux/mm/memory.c`
  - `linux/mm/mprotect.c`
  - `linux/mm/huge_memory.c`
  - `linux/mm/numa_balancing.c`
- Controller:
  - `design/fault_bucket_controller/bucket_latency_controller.py`
  - `design/fault_bucket_controller/run_guest.sh`
  - `design/fault_bucket_controller/test_bucket_latency_controller.py`
  - `design/fault_bucket_controller/plot_controller.py`
- VM scripts:
  - `motivation/3_realworld/VM/scripts/run_vm_sweep_host.sh`
  - `motivation/3_realworld/VM/scripts/run_vm_sweep_guest.sh`
  - `motivation/3_realworld/VM/scripts/run_workload_case_guest.sh`
  - `motivation/3_realworld/VM/scripts/summarize_vm_results.py`

주의할 점:

- perf attach는 optional이다. `PERF_ATTACH_EVENTS`가 없으면 동작하지 않는다.
- perf attach run은 performance baseline이 아니다.
- PTE skip counter는 현재 controller CSV 분석에 유용하다.
- `pid_inactive` bypass는 되돌렸다.
- remote sampler 별도 경로는 controller 정책 근거로 사용하지 않는다.

## 13. 무효 또는 비교 금지 run

성능 baseline으로 쓰면 안 되는 run:

- `20260710T-silo-local16-perf-access-check`
  - perf target이 wrapper PID라 invalid.
- `20260710T-silo-local16-perf-access-check-v2`
  - perf target은 유효하지만 perf overhead가 있으므로 성능 비교 금지.
  - access/sampling 진단용으로만 사용.
- allocator가 jemalloc으로 통일되지 않은 Silo run.
- stdout main-phase gating을 사용한 workload-specific diagnostic run.

## 14. 남은 질문

1. workload-independent controller가 setup과 실제 main을 어떻게 구분할 것인가?
   - Silo 전용 진단에서는 첫 throughput marker를 사용할 수 있다.
   - 기본 controller는 workload stdout에 의존하지 않으므로 별도 일반 신호가 필요하다.

2. main 이전의 loading sample로 stop하는 것을 어떻게 막을 것인가?
   - perf run의 첫 stop 205.567s는 실제 main보다 약 266초 빠르다.
   - phase gating과 policy 자체의 문제를 분리해 평가해야 한다.

3. GUPS는 어떻게 빨리 off로 수렴시킬 것인가?
   - 48 GiB GUPS는 off 288s, on 872s이다.
   - controller는 가능한 빨리 끄는 것이 목표다.
   - window clamp와 threshold 0.9는 개선 방향이었다.

4. Silo는 언제까지 켜고 언제 끌 것인가?
   - 16 GiB tail-hotset Silo는 migration-on이 유리하다.
   - 하지만 충분히 migration이 발생한 뒤 끄는 전략이 더 좋을 수 있다.
   - 실제 main sample만 사용해 판단해야 한다.

## 15. 다음 진행 권장안

정책 튜닝을 이어갈 경우:

- on/off는 `baseline/fixed-onoff-reference.csv` 값을 사용한다.
- controller variant만 새로 돌린다.
- friendly 대표: Silo 16 GiB tail-hotset.
- unfriendly 대표: GUPS 48 GiB.
- perf attach는 끄고 성능을 측정한다.

Silo phase를 더 검증할 경우:

- `starting benchmark`를 phase marker로 쓰지 않는다.
- 첫 `time: ... throughput:` 또는 worker start 뒤의 명시적 marker를 사용한다.
- `replay_main_phase_stop_gate.py`의 perf concurrency 검출 결과를 함께 확인한다.

논문화/그림화를 할 경우:

- performance figure에는 perf diagnostic run을 넣지 않는다.
- on/off는 frozen baseline 또는 fixed reference만 사용한다.
- worker initialization과 actual main을 분리해 표시한다.
- W18/W19/W24를 main-phase sample 결손 증거로 사용하지 않는다.

## 16. 최종 상태

- 마지막 완료 run:
  `motivation/3_realworld/VM/results/20260710T-silo-local16-perf-access-check-v2`
- baseline은 `baseline/` 아래에 복사되어 있다.
- 현재 QEMU/VM workload는 남아 있지 않은 것으로 확인했다.
- 이번 세션의 최종 결론:

> Silo의 실제 transaction main에서는 NUMA local/remote sample이 정상적으로
> 수집된다. 기존 low-sample 결론은 직렬 Zipf 초기화 구간을 main으로 잘못 분류하고,
> 그 계산의 perf load/store를 DB access로 해석해서 발생했다.
