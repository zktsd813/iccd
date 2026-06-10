# 64G RSS / 32G active NUMA scan-cost 실험

## 설정

- VM: fast/local memory 36G, slow memory 64G.
- Workload: `mbench --mode bw --bw-kernel read`, 32 threads, shared active window.
- Arena/RSS: `--arena-size 64G`, prefault enabled, max RSS 약 64.0GiB.
- Measured active window: `--window-size 32G`, `--move-policy fixed`, offset 0.
- Cold tail: arena 뒤쪽 32G는 RSS를 만들기 위한 prefault 이후 measured loop에서 접근하지 않음.
- Placement: persistent `mbind` 없이 default first-touch/fallback 사용.
  앞쪽 active 32G는 CPU node0 first-touch로 local fast memory에 들어가고, fast 36G를 초과하는 cold tail 대부분은 slow node1로 fallback된다.
- NUMA balancing: off=`0`, on=`2` memory-tiering mode.
- Kernel knobs: Linux 기본 scan 설정 유지, observed `scan_size_mb=256`, `scan_period_min_ms=1000`, MGLRU `0x0007`.
- Kernel state: 현재 fault-only patch가 적용된 커널로 실행했지만, 이 실험에서는 `numa_pages_migrated=0`이라 migration path는 결과에 개입하지 않았다.

## 결과

| case | elapsed (s) | Mops/s | user CPU (s) | system CPU (s) | max RSS | PTE updates | hint faults | migrated | promoted |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| off | 229.644 | 762.1 | 7968.19 | 44.52 | 64.0GiB | 0 | 0 | 0 | 0 |
| on | 212.716 | 822.8 | 7409.20 | 52.37 | 64.0GiB | 7754907 | 665 | 0 | 0 |

## 해석

- on에서 `numa_pte_updates=7754907`이 발생했다. 4KiB page 기준 약 `29.6GiB`에 해당하므로, cold resident tail 대부분이 NUMA scan/PTE marking 대상이 된 것으로 볼 수 있다.
- 하지만 measured loop가 뒤쪽 32G를 접근하지 않았기 때문에 `numa_hint_faults=665`로 매우 작고, `numa_pages_migrated=0`, `pgpromote_success=0`이다.
- scan 자체의 kernel CPU 증가는 `system CPU 44.52s -> 52.37s`, 즉 약 `+7.85 CPU-s`이다.
  775만 PTE update 기준으로는 대략 `1.0us / updated PTE` 수준의 order다.
- wall-clock elapsed는 on이 더 빠르게 나왔다 (`229.6s -> 212.7s`). 따라서 이 단일 run에서 elapsed 차이를 scan overhead로 해석하면 안 된다.
  scan 비용은 wall time에는 noise보다 작게 보이고, system CPU 증가분으로 보는 것이 더 직접적이다.
- 결론적으로 이 구성에서는 NUMA balancing scan만 켰을 때 실제 migration 없이도 cold RSS 약 29.6GiB를 PTE marking하지만,
  measured execution time slowdown은 관찰되지 않았고 kernel CPU로 약 8초 수준의 작은 비용만 보였다.

## 보조 run

- `motivation/2_microbenchmark/scan_cost_64rss_32active`: `split:0,1` persistent `mbind` 배치. `numa_pte_updates=0`이라 scan-cost 대표 결과에서 제외.
- `motivation/2_microbenchmark/scan_cost_64rss_32active_normal`: `split:0,1` + `numa_balancing=3` diagnostic. `numa_pte_updates=1535`로 너무 작아 대표 결과에서 제외.
