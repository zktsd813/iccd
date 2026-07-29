# Session Handoff - 2026-07-01

이 문서는 2026-06-26부터 2026-07-01까지 진행한 VM/CXL, mbench,
GAPBS PR, MLP proxy, scan-size audit, 논문/artifact 교차검증 내용을 새
세션에서 바로 이어받기 위한 handoff이다.

새 세션 시작 시 먼저 읽을 것:

- `/home/ijkim/.codex/skills/iccd-experiments/SKILL.md`
- `docs/session-handoff-20260608.md`
- 이 파일

## Current Stop State

현재 작업 디렉토리:

- `/Serverless/iccd-git`

현재 host kernel:

```text
Linux ubuntu 6.18.0modified #12 SMP PREEMPT_DYNAMIC Wed Jun 24 06:35:46 UTC 2026 x86_64
```

현재 `pgrep` 기준으로 PR/GAPBS/mbench workload runner는 보이지 않았다. 다만
이전 mbench CXL 검증용 QEMU VM 3개가 계속 떠 있다.

| VM | PID | SSH port | guest node0 | guest node1 | mapping |
|---|---:|---:|---|---|---|
| `mbench-cxl-local16-rerun` | 3697 | 10025 | 16G, CPUs 0-31 | 16G memory-only | host node0 -> guest node0, host node2 -> guest node1 |
| `mbench-cxl-local12-rerun` | 4939 | 10026 | 12G, CPUs 0-31 | 20G memory-only | host node0 -> guest node0, host node2 -> guest node1 |
| `mbench-cxl-local24-on` | 5450 | 10027 | 24G, CPUs 0-31 | 16G memory-only | host node0 -> guest node0, host node2 -> guest node1 |

현재 `tmux ls`에는 세션 `0` 하나가 남아 있다. 새 실험이라고 판단하기 전
실제 프로세스와 progress file을 확인해야 한다.

현재 host knob 일부는 다음처럼 보였다:

- `/proc/sys/kernel/numa_balancing=0`
- `/sys/kernel/mm/numa/demotion_enabled=false`
- `/sys/kernel/mm/numa_balancing/local_fault_rate=0`
- `/sys/kernel/mm/numa_balancing/local_fault_scan_size_mb=256`

## Hard Rules For Next Session

- ICCD/CXL/VM/PR 작업에는 반드시 `iccd-experiments` skill을 먼저 읽는다.
- GAPBS PR/BC는 기본적으로 generated graph mode만 사용한다.
- `-f /root/gapbs_graphs/...`, `GAPBS_GRAPH_MODE=prebuilt`,
  `GAPBS_GRAPH_HOST`, `GAPBS_GRAPH_GUEST`, `GRAPH=/root/gapbs_graphs/...`는
  사용하지 않는다. 사용하려면 현재 turn에서 사용자가 명시적으로 요청해야 한다.
- migration-off baseline은 `numa_balancing=0`만으로 부족하다.
  `DEMOTION_ENABLED=false`도 같이 설정한다.
- scan size 기본값은 `scan_size_mb=256`, `local_fault_scan_size_mb=256`으로
  고정한다. 다른 값은 사용자가 현재 turn에서 명시적으로 요청할 때만 쓴다.
- 결과 그래프는 `/tmp`에 두지 않는다. 현재 디렉토리나 repo 내 artifact
  디렉토리에 둔다.
- 이전 `previous ours` 비교는 잘못된 실험으로 제외한다. 현재 비교 축은
  사용자가 요청한 대로 `off`, `on`, `ours`만 유지한다.

## Script And Policy Changes

다음 변경이 중요하다.

- `motivation/pr_graph_test/scripts/run_pr_graph_host.sh`
  - `VMCTL_SUDO` 지원을 추가했다.
  - generated graph mode에서 `GAPBS_GRAPH_NAME`, `GAPBS_GRAPH_HOST`,
    `GAPBS_GRAPH_GUEST`, `GRAPH`를 비운다.
- `scripts/stage_workloads_to_vm.sh`
  - `STAGE_GAPBS_GRAPH != 1`이면 VM 안의 `/root/gapbs_graphs`를 삭제하고
    빈 디렉토리로 다시 만든다. 새 PR/BC 실험이 prebuilt graph를 실수로
    재사용하지 않도록 하기 위한 변경이다.
- `/home/ijkim/.codex/skills/iccd-experiments/SKILL.md`
  - generated graph hard rule, migration-off demotion disable rule,
    scan-size 256MB default rule을 명시했다.

## Invalid Or Caveated Results

현재 정책상 무효로 취급할 PR 결과:

- `motivation/pr_graph_test/results/20260630T060641Z-pr-g28-vm-local16-32-48-off`
- `motivation/pr_graph_test/results/20260630T063020Z-pr-g28-vm-local16-32-48-off-nodemote`

이 둘은 `gapbs_graph_mode=prebuilt`이고 command가
`-f /root/gapbs_graphs/kron_g28.sg`를 사용했다. 현재 PR/BC 정책과 맞지
않으므로 plot이나 주장에 쓰지 않는다.

주의해서만 볼 mbench 결과:

- `experiments/20260626-mbench-friendly16g-halfsplit-onoff/summary.md`
  - 이 run은 workload RSS가 16G이고 초기 배치가 8G/8G였지만, VM 자체는
    local16이 아니라 `node0=64G`, `node1=64G`, total 128G였다.
  - 초기 배치 동작 확인용으로만 유효하고, 16G local-capacity 실험으로는
    무효다.

## PR Generated Graph Results

현재 유효한 PR g28 generated graph run:

- migration off:
  `motivation/pr_graph_test/results/20260630T072006Z-pr-g28-vm-local8-16-32-off-generated`
- migration on:
  `motivation/pr_graph_test/results/20260630T080313Z-pr-g28-vm-local8-16-32-migration-on-generated`
- combined summary:
  `pr-g28-generated-local8-16-32-on-off-summary.csv`

공통 설정:

- workload: GAPBS PR
- graph mode: generated
- command core: `/root/benchmark/gapbs/pr -g 28 -i 5 -t 1e-4 -n 1`
- graph file: 사용 안 함
- controls:
  - all-fast: `numactl --cpunodebind=0 --membind=0`
  - all-slow: `numactl --cpunodebind=0 --membind=1`
- mixed on/off:
  - `numactl --cpunodebind=0`
  - explicit `--membind`, cgroup memory cap, interleave는 없다.

핵심 결과:

| local GiB | off trial s | on trial s | on/off | on promoted GiB | on demoted GiB |
|---:|---:|---:|---:|---:|---:|
| 8 | 18.79662 | 19.08056 | 1.0151 | 14.38 | 23.27 |
| 16 | 18.95695 | 19.49818 | 1.0286 | 20.72 | 24.02 |
| 32 | 19.36582 | 19.80144 | 1.0225 | 25.81 | 26.56 |

Controls from the same generated run:

- all-fast trial: `18.55044s`
- all-slow trial: `110.11915s`

해석:

- all-slow가 매우 느리므로 CXL/slow tier 차이는 분명히 존재한다.
- 그러나 mixed migration-on은 off보다 `1.5%`에서 `2.9%` 느린 정도에
  그쳤다.
- 이것은 "CXL이 빠르다"가 아니라, 현재 PR run에서 migration이 PR trial을
  실질적으로 개선하지 못하고 migration/fault/demotion overhead를 추가한
  결과로 보는 편이 맞다.

## PR Low-Free Sweep

사용자 요청: VM에서 workload 시작 직전 node0 free memory 기준으로 1G, 2G,
3G, 4G에 가깝게 맞춰 migration on/off 비교.

실제 구현:

- guest/node0 baseline 사용량 때문에 fast memory를 `3/4/5/6 GiB`로 잡아
  pre-workload free를 대략 `1/2/3/4 GiB`로 맞췄다.
- 이 free target은 전체 PR process 시작 전 기준이다. PageRank trial 직전
  기준은 아니다.

Run roots:

- off:
  `motivation/pr_graph_test/results/20260630T084217Z-pr-g28-vm-free1-4-off-generated`
- on:
  `motivation/pr_graph_test/results/20260630T085822Z-pr-g28-vm-free1-4-on-generated`
- combined summary:
  `pr-g28-generated-free1-4-on-off-summary.csv`

핵심 결과:

| target free GiB | fast mem GiB | off pre-free GiB | on pre-free GiB | off trial s | on trial s | on/off | promoted GiB | demoted GiB |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 3 | 1.4006 | 1.3701 | 18.86918 | 18.92029 | 1.0027 | 6.15 | 13.65 |
| 2 | 4 | 2.3557 | 2.3520 | 18.70696 | 18.95846 | 1.0134 | 7.86 | 15.26 |
| 3 | 5 | 3.2926 | 3.3003 | 18.64844 | 18.87279 | 1.0120 | 8.43 | 17.52 |
| 4 | 6 | 4.2627 | 4.2530 | 18.74880 | 18.94413 | 1.0104 | 11.50 | 18.73 |

해석:

- 극단적으로 node0 free를 낮춰도 on은 off보다 `0.3%`에서 `1.3%` 정도만
  느렸다.
- 이전 가정인 "작은 hot set이 local에 들어가서 on/off가 비슷하다"만으로는
  이 결과를 충분히 설명하지 못한다.
- 더 설득력 있는 설명은 PR의 주요 graph neighbor stream이 재사용성이 낮고,
  migration이 옮긴 페이지가 migration 비용을 amortize할 만큼 반복적으로
  쓰이지 않는다는 것이다.

## PR Memory Footprint

GAPBS PR g28 generated run에서 관찰/계산한 크기:

- graph: `268,435,455` nodes
- undirected edges: `4,236,159,892`
- degree: 15
- `scores`: 약 `1.00 GiB`
- `outgoing_contrib`: 약 `1.00 GiB`
- CSR pointer/index array: 약 `2.00 GiB`
- neighbor array: 약 `31.56 GiB`
- steady graph footprint: 약 `33.56 GiB`
- steady graph + PR vectors: 약 `35.56 GiB`
- max RSS: 약 `70 GiB`

중요한 caveat:

- GAPBS `Trial Time`은 graph build 이후 PageRank trial 시간을 의미한다.
- 하지만 generated mode에서는 graph generation/build가 같은 process에서
  먼저 일어나므로 page placement와 RSS peak에는 graph build의 영향이 남는다.
- `max_process_N0_GiB`, `max_process_N1_GiB`는 build-inclusive peak로 봐야
  한다.
- `memory_samples.csv`는 phase marker가 없으므로 graph build, PR trial,
  teardown을 명확히 분리하지 못한다.

## PR Runner Analysis

분석한 파일:

- `motivation/pr_graph_test/scripts/run_pr_graph_host.sh`
- `motivation/pr_graph_test/scripts/run_pr_graph_guest.sh`
- `motivation/pr_graph_test/scripts/run_workload_case_guest.sh`
- `scripts/stage_workloads_to_vm.sh`
- `/Serverless/benchmark/gapbs/src/pr.cc`
- `/Serverless/benchmark/gapbs/src/builder.h`
- `/Serverless/benchmark/gapbs/src/benchmark.h`

중요 결론:

- `migration_on`은 guest에서 `numa_balancing=2`, demotion enabled로 돈다.
- `migration_off`는 `numa_balancing=0`, demotion disabled가 되어야 한다.
- all-fast/all-slow는 `--membind`가 있지만 mixed on/off는
  `--cpunodebind=0`만 있다.
- 따라서 mixed on/off는 명시적 memory cap 실험이라기보다, VM fast/slow
  node 크기와 Linux default allocation/fallback에 의존한 실험이다.
- run script의 "before free" snapshot은 PR trial 직전이 아니라 전체 PR
  process 실행 전이다.
- generated mode에서 graph build가 process 내에서 발생하므로, trial 이전
  page placement를 바꿀 수 있다.

다음 PR 검증을 하려면:

- PR source에 phase marker 또는 snapshot hook을 넣어서
  `PageRankPullGS()` 시작/끝의 placement를 따로 잡아야 한다.
- 가능하면 local/remote memory access counter를 같이 잡아야 한다.
  예: `mem_load_l3_miss_retired.local_dram`,
  `mem_load_l3_miss_retired.remote_dram` 사용 가능 여부 확인.
- 현재 짧은 `-g28 -i5 -n1` run과 논문 artifact의 long steady-state run을
  별도 카테고리로 분리해야 한다.

## VM CXL Mapping And MLC

중요하게 고친 설정:

- CPU 32개는 host node0 CPUs `0-31`에 pin.
- guest node0 memory는 host node0 DRAM.
- guest node1 memory는 host node2 CXL.
- VM kernel append에는
  `systemd.mask=systemd-networkd-wait-online.service`가 포함된다.

대표 CXL local16 rerun:

- summary:
  `experiments/20260629-cxl-local16-rerun/summary.md`
- VM: `mbench-cxl-local16-rerun`
- guest node0: 16G, CPUs 0-31
- guest node1: 16G memory-only
- mapping 확인:
  - guest node0 -> host node0
  - guest node1 -> host node2

MLC 결과:

| metric | node0 -> node0 | node0 -> node1 |
|---|---:|---:|
| latency mean ns | 155.0 | 267.3 |
| read BW MB/s | 139009.7 | 23582.5 |

해석:

- CXL/remote latency는 local 대비 약 `1.73x` 느리다.
- CXL/remote bandwidth는 local 대비 약 `0.17x`이다.
- 따라서 PR 결과가 이상해 보이는 원인은 CXL이 충분히 느리지 않아서가 아니다.

## Mbench Results

### High-MLP Skewed Hotset

local16 CXL rerun:

- summary:
  `experiments/20260629-cxl-local16-rerun/summary.md`
- workload: 16G RSS, initial 8G local + 8G CXL, 32 threads, mulshift read
- off: `106102.97 MiB/s`
- on: `89017.27 MiB/s`
- on/off: `0.839x`
- migration-on promoted 약 `2,023,338` pages, demotion도 발생.

local12 same workload:

- summary:
  `experiments/20260629-cxl-local12-rerun/summary.md`
- off: `106243.7 MiB/s`
- on: `64377.5 MiB/s`
- on/off: `0.606x`
- node0 capacity pressure가 심해지고 kswapd scan/steal/demotion이 커졌다.

local24 migration-on:

- summary:
  `experiments/20260629-cxl-local24-on/summary.md`
- on: `84948.1 MiB/s`
- 8G CXL half가 완전히 node0로 migrate.
- demotion/reclaim은 0.
- 그래도 off baseline보다 느리다. high-MLP workload에서는 half-local off가
  DRAM과 CXL을 parallel backend처럼 쓰는 효과가 있고, migration-on은 모든
  traffic을 node0 DRAM에 집중시킨다.

### Low/Mid-MLP Pointer-Chase

low-MLP single-chain pointer-chase:

- summary:
  `experiments/20260629-cxl-pc-local24/summary.md`
- workload: 4G arena, initial 2G local + 2G CXL, 1 thread, 1 random chain
- off: `4.87 Mops/s`
- on: `7.36 Mops/s`
- on/off: `1.51x`
- on은 2G CXL half를 warmup 중 node0로 모두 migrate.

mid-MLP 4-chain pointer-chase:

- summary:
  `experiments/20260629-cxl-pc-local24-chains4/summary.md`
- workload: 4G arena, initial 2G local + 2G CXL, 1 thread, 4 random chains
- off: `19.12 Mops/s`
- on: `29.75 Mops/s`
- on/off: `1.56x`

해석:

- single-chain과 4-chain pointer-chase는 migration-on이 명확히 유리하다.
- 4 chains는 MLP가 늘었지만 CXL latency penalty를 숨길 정도는 아니다.
- 32-thread skewed-hotset은 high-MLP/bandwidth-parallel 성격이라 migration이
  오히려 손해가 났다.

## Host All-Local MLP Proxy

Host all-local MLP proxy run:

- summary:
  `experiments/20260630-host-alllocal-mlp/results-20260630T0445Z/summary.md`
- plot copies:
  - `host-alllocal-mlp-summary.png`
  - `host-alllocal-mlp-ipc-scatter.png`

방법:

- host, VM 아님.
- CPU bind: physical CPUs `0-31`.
- memory bind: NUMA node0.
- PMU source:
  `/Serverless/Migration-friendly/linux/tools/perf/perf stat -a -C 0-31`
- proxies:
  - `l1d_mlp_proxy = l1d_pend_miss.pending / l1d_pend_miss.pending_cycles`
  - `offcore_mlp_proxy = offcore_requests_outstanding.data_rd / offcore_requests_outstanding.cycles_with_data_rd`

주요 결과:

| workload | status | l1d MLP proxy | offcore MLP proxy | IPC | RSS GiB |
|---|---|---:|---:|---:|---:|
| `pr_g28` | ok | 11.93 | 23.42 | 0.160 | 35.57 |
| `xsbench_g65k_l20m` | ok | 6.90 | 9.90 | 0.952 | 31.72 |
| `bc_g28` | ok | 6.16 | 9.63 | 0.307 | 38.99 |
| `graph500_s27` | ok | 4.70 | 6.72 | 1.061 | 55.26 |
| `dlrm_synth` | ok | 4.44 | 7.69 | 2.715 | 34.58 |
| `btree_32g` | ok | 2.06 | 7.45 | 0.081 | 65.88 |
| `faster_ycsb_a` | ok | 1.05 | 1.51 | 0.583 | 58.76 |

해석:

- PR g28은 proxy상 high-MLP workload이다.
- 따라서 PR에서 migration이 이득을 못 본 것은 "MLP가 낮아서"가 아니다.
- high MLP와 streaming/cold graph page 특성 때문에 slow memory latency가
  덜 직접적으로 드러나고, migration copy/fault/scan cost가 이득을 상쇄했을
  가능성이 더 크다.

## Scan Size Audit

scan size audit:

- `hostnative-scan-size-audit/hostnative_scan_size_report.md`
- `hostnative-scan-size-audit/hostnative_scan_size_cases.csv`
- `hostnative-scan-size-audit/hostnative_scan_size_runs.csv`

결론:

- 과거 host-native ours run에서 256MB가 아닌 값이 나온 이유는 사용자가
  명시한 값이 아니라, 예전 default `LOCAL_FAULT_SCAN_SIZE_MB=auto` 때문이었다.
- direct host-native path는 node0 MemTotal의 10%를 local scan size로 계산했다.
  예: 2175, 3788, 5602 MiB.
- controller wrapper path는 configured capacity의 10%를 계산했다.
  예: 1639, 3277, 4916 MiB.
- 현재 source/skill 정책은 future run에서 256MB 고정이다. 단, 실제 실행 전
  final command와 snapshot에서 반드시 확인한다.

## Literature And Artifact Cross-Check

다른 논문/아티팩트 조사 결과, PR에서 migration이 항상 좋아야 한다는
근거는 약하다. 오히려 PR은 migration이 불리하거나 필요 없는 workload로
분류되는 사례가 있다.

확인한 자료:

- Nomad OSDI 2024:
  - paper: `https://arxiv.org/html/2401.13154v2`
  - repo: `https://github.com/lingfenghsiang/Nomad`
  - README는 PageRank script를 언급하지만 해당 experiment script/raw result
    path는 repo tree에서 직접 확인되지 않았다.
  - paper는 RSS가 크지 않거나 PageRank가 latency-sensitive하지 않은 경우
    no migration/TPP/Nomad 차이가 작을 수 있다고 설명한다.
- Parameter Tuning in Memory Tiering:
  - paper: `https://arxiv.org/html/2504.18714v1`
  - GapBS-PR은 relatively small hot page set과 many cold streaming accesses를
    가진다고 설명한다.
  - default migration이 cold page를 계속 옮겨 bandwidth와 write stall을
    늘릴 수 있고, best configuration은 migration을 피하는 쪽이라고 설명한다.
  - 현재 PR g28 결과와 가장 직접적으로 맞는다.
- M5 ASPLOS 2025:
  - paper: `https://tianyin.github.io/pub/m5.pdf`
  - repo: `https://github.com/ece-fast-lab/ASPLOS-2025-M5`
  - PageRank에서 hotness skew가 충분하지 않으면 migration cost가 benefit을
    넘을 수 있다는 방향과 맞는다.
- DSA-2LM ATC 2025:
  - paper: `https://ranger.uta.edu/~jrao/papers/atc25.pdf`
  - PageRank Twitter RSS는 약 12.3GB로 보고되며, local tier가 RSS보다 큰
    경우 pressure workload가 아니므로 해석에서 제외된 사례가 있다.
- HybridTier ASPLOS 2025 artifact:
  - repo: `https://github.com/kevins981/hybridtier-asplos25-artifact`
  - PR command 예:
    `pr -g 31 -k 4 -i1000 -t1e-4 -n16`
  - Memtis script는 AutoNUMA를 끄고 memcg/cap, perf local/remote counter를
    사용한다.

현재 실험과 literature artifact의 차이:

- 현재 PR run: `-g 28 -i 5 -n 1`, 짧은 run.
- HybridTier style: `-g 31 -k 4 -i1000 -n16`, 훨씬 긴 steady-state run.
- 현재 VM mixed run은 explicit memory cap 없이 `--cpunodebind=0`만 사용한다.
- 논문 artifact들은 memcg/cap 또는 tracing/counter 기반으로 placement와
  access를 더 명시적으로 통제한다.

## Recovery Notes

host boot가 memory cmdline 때문에 실패하면 GRUB에서 해당 memory 관련
kernel argument, 특히 잘못된 `memmap` 설정을 제거하고 부팅하는 것이
응급 복구 절차로 맞다.

복구 후에는 다음을 확인한다.

- `/etc/default/grub` 또는 custom grub snippet에 잘못된 `memmap`이 남아
  있지 않은지 확인.
- `crontab`, systemd service/timer, tmux resume script가 자동으로 실험을
  다시 시작하지 않는지 확인.
- 재실험을 넣을 때는 부팅 후 최소 60초 이상 아무 것도 하지 않는 safe delay를
  둔다. 그래야 부팅 직후 사용자가 crontab 또는 boot 설정을 수정할 수 있다.
- VM boot에서는 현재 `systemd.mask=systemd-networkd-wait-online.service`를
  사용해 wait-online 지연을 피하고 있다.

## Recommended Next Steps

다음 세션에서 PR 의문을 계속 파고들려면 순서는 다음이 좋다.

1. 현재 살아 있는 mbench VM이 필요한지 확인하고, 필요 없으면 정리한다.
2. PR runner에서 final command dry-run을 먼저 확인한다.
   command에 `-g <scale>`가 있어야 하고 `-f /root/gapbs_graphs/...`가
   없어야 한다.
3. GAPBS PR source에 phase marker를 넣거나 wrapper를 고쳐서
   graph build 종료, PR trial 시작, PR trial 종료의 placement/RSS/counter를
   분리한다.
4. `-g28 -i5 -n1` short run과 literature-style long run을 분리해서 비교한다.
   long run 후보는 HybridTier와 맞춘 `-g31 -k4 -i1000 -n16`이지만, 메모리와
   소요 시간이 커질 수 있으므로 capacity estimate부터 한다.
5. 가능하면 perf local/remote DRAM/CXL counter를 붙인다. counter가 host PMU에서
   CXL까지 의미 있게 분리되는지 먼저 sanity check가 필요하다.
6. PR 결과를 주장할 때는 "migration off보다 on이 약간 느림"과
   "PR은 high MLP이고 cold streaming page가 많아 migration이 불리할 수 있음"을
   같이 써야 한다.

## Worktree Notes

worktree는 의도적으로 dirty하다. 관련 없는 변경이나 generated artifact를
임의로 reset/delete하지 않는다.

현재 특히 중요한 untracked/modified artifact:

- `motivation/pr_graph_test/`
- `experiments/20260629-cxl-local16-rerun/`
- `experiments/20260629-cxl-local12-rerun/`
- `experiments/20260629-cxl-local24-on/`
- `experiments/20260629-cxl-pc-local24/`
- `experiments/20260629-cxl-pc-local24-chains4/`
- `experiments/20260630-host-alllocal-mlp/`
- `hostnative-scan-size-audit/`
- `pr-g28-generated-local8-16-32-on-off-summary.csv`
- `pr-g28-generated-free1-4-on-off-summary.csv`

새 세션에서 결과를 정리하거나 plot을 다시 만들 때 위 두 CSV와 각 summary
파일을 우선 source of truth로 삼는다.
