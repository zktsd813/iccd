# ICCD final submission status, 2026-07-22

이 문서는 2026-07-22 기준으로 정리한 최종 controller 설계, 제출용 평가 패키지,
그리고 마지막 microbenchmark case study 결과를 요약한다. 대용량 raw VM 결과는 로컬
worktree에 남기고, GitHub에는 README, summary CSV, figure 중심의 선별 산출물만
추가한다.

## Final policy

최종 ours 정책은 `capacity_rank_latency_local_remote_restart_v3`이다. VM 실험은
공유 controller runner인 `design/fault_bucket_controller/run_guest.sh`를 guest의
`/root/design/fault_bucket_controller/run_guest.sh`로 staging해서 수행했다.

핵심 arbitration은 상태 기반이다.

- Migration ON 상태에서는 STOP 계열 판단을 소비한다. 단, controller-issued START
  직후에는 START gap 감소가 충분하면 retention guard가 STOP을 잠시 suppress한다.
- Migration OFF 상태에서는 START 판단만 소비한다.
- 최근 확정한 microbenchmark에서는 시작 상태를 ON으로 둔 case도 별도로 검증했다.

정책 discussion 과정에서 폐기한 방향:

- START에 RSS/density를 직접 넣는 방식은 제외했다.
- STOP은 local/remote latency CDF와 current residency mass를 같이 쓰는 방향으로
  유지했다.
- low-sample window와 KLL P75 신뢰도 문제는 별도 telemetry로 확인했고, 최종
  제출 패키지에서는 policy CSV와 controller event를 보존한다.

## Final submission package

GitHub에 추가한 제출용 요약 산출물은 `final_submission/` 아래에 있다. Raw VM logs와
큰 script snapshot은 이 커밋에 포함하지 않는다.

### `final_submission/evaluation_1_microbench`

GUPS-like two-phase microbenchmark 결과와 migration volume을 정리한 evaluation이다.
기존 phase별 elapsed/migration figure에 더해, 마지막에 수행한 RSS 64 GiB / hotset
48 GiB case study의 time-series throughput 비교를 추가했다.

추가 case study 조건:

- VM fast/local memory: 34 GiB
- slow memory: 80 GiB
- benchmark RSS: 64 GiB
- hotset: 48 GiB
- all-remote initial placement: mbench `--prefault-node 1`로 전체 arena를 remote에서
  first-touch한 뒤 default policy로 reset
- 비교 정책: `on`, `tpp`, `ours`

해당 mbench는 fixed-duration이므로 elapsed time이 아니라 stdout의
`ops_delta / sample_interval`에서 throughput을 계산해야 한다. 새 그래프와 CSV:

- `final_submission/evaluation_1_microbench/figure/throughput_timeseries_compare_on_tpp_ours.{png,pdf,svg}`
- `final_submission/evaluation_1_microbench/throughput_timeseries_compare_on_tpp_ours.csv`
- `final_submission/evaluation_1_microbench/throughput_summary_on_tpp_ours.csv`

요약 throughput:

| policy | completed ops | avg throughput | last 1 s | last 30 s mean |
|---|---:|---:|---:|---:|
| on | 28,368,764,928 | 141.84 Mops/s | 124.90 Mops/s | 116.60 Mops/s |
| tpp | 28,713,156,608 | 143.57 Mops/s | 112.20 Mops/s | 118.19 Mops/s |
| ours | 40,167,342,080 | 200.84 Mops/s | 229.05 Mops/s | 227.56 Mops/s |

추가로 sanity check용 off variants도 로컬에서 돌렸다.

- `off-all-remote`: 106.35 Mops/s, process memory stays at N0 ~= 0 GiB / N1 = 64 GiB.
- `off-32G-local`: 307.86 Mops/s, initial placement N0 = 32.006 GiB / N1 = 32.000 GiB.

이 off-32G-local 결과는 동적 정책의 성능 비교 대상이라기보다, 좋은 초기 배치가
주어졌을 때의 upper-bound reference로 해석한다.

### `final_submission/evaluation_2_realworld`

Real-world workload sweep은 16/32/48 GiB local memory에서 `off`, `on`, `tpp`,
`ours`를 비교한다. workload set은 PR, BC, GUPS, BTree, Graph500, Silo이다.
GAPBS PR/BC는 generated graph mode를 사용한다.

주요 aggregate:

- 전체 18 cases 기준, ours는 migration-on 대비 geomean speedup 1.208x
  (+20.84%).
- arithmetic speedup 기준 +28.03%.
- total elapsed reduction 기준 +16.95%.
- PR/GUPS/BTree subset 기준 geomean speedup 1.304x (+30.41%).

### `final_submission/evaluation_3_bc`

BC case study는 controller-only로 16/32/48 GiB local memory를 한 번씩 실행해
controller transition과 phase 위치를 확인한 결과이다.

Elapsed time:

| local memory | elapsed |
|---:|---:|
| 16 GiB | 678.10 s |
| 32 GiB | 656.97 s |
| 48 GiB | 585.52 s |

주요 관찰:

- main trials는 중간에 끊긴 것이 아니라 모두 완료됐다.
- migration transition은 generate/build phase에서 발생했고, measured trial 구간은
  off 상태로 들어갔다.
- 16 GiB case 예: generate 0--109.638 s, build 109.638--415.558 s,
  trials start 415.558 s. Transitions: STOP 76.320 s, START 87.020 s,
  STOP 251.743 s, START 298.505 s, STOP 307.190 s.

### `final_submission/evaluation_4_fault_overhead`

Local sampling과 memory-tiering protected 상태를 유지하되 migration은 off로 두어
fault sampling overhead를 측정한 evaluation이다.

요약:

- arithmetic mean overhead: 1.1295%
- median overhead: 1.1615%
- elapsed-weighted overhead: 1.1313%

Per-workload summary:

| workload | overhead |
|---|---:|
| PR | +1.703% |
| BC | -0.115% |
| GUPS | +1.958% |
| BTree | +0.620% |
| Graph500 | -0.063% |
| Silo | +2.674% |

### Motivation packages

- `final_submission/motivation_1`: ours를 제외한 real-world baseline/motivation
  comparison.
- `final_submission/motivation_2`: ours를 제외한 microbenchmark motivation package.

## Local raw result references

대용량 raw 결과는 GitHub 커밋에서 제외했다. 필요한 경우 아래 local paths에서 확인한다.

- Final real-world/package inputs: `final_submission/evaluation_2_realworld`
- BC case study raw run:
  `final_submission/evaluation_3_bc/raw/20260714T221803Z-eval3-bc-case-v3-v4abi-matched`
- RSS64/hotset48 ours run:
  `submission_socc/final_experiments/runs/20260715T073843Z-mbench-rss64-hot48-allremote-prefaultnode-ours-starton-local34-slow80`
- RSS64/hotset48 on/off/tpp run:
  `submission_socc/final_experiments/runs/20260715T075041Z-mbench-rss64-hot48-allremote-prefaultnode-off-on-tpp-local34-slow80`
- RSS64/hotset48 off-32G-local run:
  `submission_socc/final_experiments/runs/20260715T083430Z-mbench-rss64-hot48-off-hot32local-local34-slow80`

## Notes for future reruns

- Use generated graph mode for GAPBS PR/BC unless explicitly testing prebuilt graphs.
- Keep normal NUMA scan size at 256 MiB.
- Keep local fault scan size at 64 MiB and period at 1000 ms unless explicitly changing
  the policy experiment.
- For all-remote initial placement microbenchmarks, do not use `--placement bind:1`
  for the measured arena. It leaves the VMA policy bound to remote and prevents normal
  NUMA scanner migration. Use `--prefault-node 1` to first-touch remotely and then reset
  the thread policy to default.
