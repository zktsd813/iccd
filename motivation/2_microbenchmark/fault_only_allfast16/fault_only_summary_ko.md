# Fault-only NUMA balancing control 결과

## 설정

- Workload: shared-window microbenchmark, 32 threads, hotset 32G, fixed ops `43686414250`.
- VM memory: fast/local memory 16G, slow memory 64G.
- Baseline 비교 대상: `motivation/2_microbenchmark/varying_local/raw/local-16G/summaries/summary.csv`.
- Fault-only 결과: `motivation/2_microbenchmark/fault_only_allfast16/raw/local-16G/summaries/summary.csv`.
- 적용 패치: `motivation/2_microbenchmark/patches/0001-iccd-numa-fault-only-skip-migration.patch`.

패치는 `do_numa_page()`와 `do_huge_pmd_numa_page()`에서 NUMA hint fault accounting 및 PTE remap 경로는 유지하고,
`migrate_misplaced_folio_prepare()` / `migrate_misplaced_folio()` 호출 전에 `out_map`으로 빠지게 만든다.
따라서 remote NUMA hint fault는 발생하지만 automatic page migration은 발생하지 않아야 한다.

## 결과

| variant | elapsed (s) | ratio vs baseline off | Mops/s | user CPU (s) | system CPU (s) | hint faults | migrated pages | pgpromote success | demoted GiB | pgfault |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline off | 261.023 | 1.000x | 168.400 | 8986.14 | 30.44 | 0 | 0 | 0 | 1.189 | 9449725 |
| baseline migration on | 699.074 | 2.678x | 62.974 | 18500.58 | 4189.66 | 63077572 | 2740008 | 2740008 | 11.361 | 478585176 |
| fault-only off | 265.279 | 1.016x | 165.699 | 9096.22 | 31.38 | 0 | 0 | 0 | 0.925 | 9440780 |
| fault-only on | 302.211 | 1.158x | 145.449 | 8294.94 | 2033.35 | 36398651 | 0 | 0 | 0.925 | 271320994 |

## 해석

- 패치 동작은 확인됐다. `fault-only on`에서 `numa_hint_faults=36398651`로 remote NUMA hint fault는 발생했지만,
  `numa_pages_migrated=0` 및 `pgpromote_success=0`으로 promotion/migration은 막혔다.
- 기존 migration-on은 baseline off 대비 `2.678x` 느렸고, fault-only on은 baseline off 대비 `1.158x` 느렸다.
  즉 이 workload의 큰 slowdown은 hint fault 자체보다 실제 migration/promotion/demotion 경로에서 주로 발생한다.
- fault-only on에서도 system CPU는 `2033.35s`로 off의 약 `31s`보다 매우 크다.
  남은 비용은 NUMA hint fault 처리, PTE/PMD 재설정, fault handling, mm bookkeeping 계열로 보는 것이 타당하다.
- 원래 migration-on의 demotion은 `11.361 GiB`였지만 fault-only on은 `0.925 GiB`로 off와 같은 수준이다.
  promotion을 막으면서 fast memory pressure와 그에 따른 demotion도 크게 줄었다.

## 재현 및 제거

현재 커널 소스에는 fault-only patch가 적용된 상태다.

```bash
git apply -R motivation/2_microbenchmark/patches/0001-iccd-numa-fault-only-skip-migration.patch
make -C linux O=linux-global-build -j$(nproc) bzImage
```
