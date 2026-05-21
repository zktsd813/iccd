# PR g28 load-only local8: off/on/ours window sweep

Ours run ID base: `20260519T050410Z-prg28-load-local8-ours-w5w10`

Artifacts: `/Serverless/iccd/experiments/20260519-pr-g28-local8-load-firsttouch-onoff/qemu-logs/pr_g28_local8_load_firsttouch_onoff/20260519T050410Z-prg28-load-local8-ours-w5w10`

## Runtime

| policy | Read s | Trial avg s | Trial times s | elapsed s | trigger | off time | hint faults | PTE updates | promoted GiB | demoted GiB | local fault PTE/refault/hit |
| --- | ---: | ---: | --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | --- |
| off | 30.91569 | 19.11743 | 19.53829, 18.89169, 18.92230 | 90 | no |  | 0 | 0 | 0.00 | 38.82 | 0/0/0 |
| on | 26.26831 | 55.99104 | 53.45255, 49.50145, 65.01911 | 197 | no |  | 29702070 | 29898160 | 49.98 | 88.57 | 0/0/0 |
| ours-w5 | 29.86348 | 22.22330 | 28.52415, 19.20773, 18.93802 | 99 | yes | 41.333s | 4818231 | 5164018 | 7.22 | 44.19 | 212165/212165/125242 |
| ours-w10 | 34.35984 | 24.13258 | 34.03271, 19.48902, 18.87601 | 109 | yes | 61.042s | 8095423 | 9029166 | 12.43 | 54.62 | 383969/383969/240962 |

## Ratios

- on / off trial-time ratio: `2.929x`; throughput ratio: `0.341x`
- ours-w5 / off trial-time ratio: `1.162x`; throughput ratio: `0.860x`
- ours-w10 / off trial-time ratio: `1.262x`; throughput ratio: `0.792x`

## Controller Samples

### ours-w5
```csv
event,timestamp,elapsed_ms,window,window_seq,window_sec,threshold_pct,min_pte_updates,pte_delta,hit_delta,refault_delta,lost_delta,access_pct,fast_pct,consecutive,node_balancing
start,2026-05-19T05:04:47Z,0,0,1,5,80,1000,0,0,0,0,0.00,0.00,0,2
sample,2026-05-19T05:04:53Z,5191,1,1,5,80,1000,0,0,0,0,0.00,0.00,0,2
sample,2026-05-19T05:04:58Z,10352,2,2,5,80,1000,6588,0,0,0,0.00,0.00,0,2
sample,2026-05-19T05:05:03Z,15508,3,3,5,80,1000,19661,0,0,0,0.00,0.00,0,2
sample,2026-05-19T05:05:08Z,20662,4,4,5,80,1000,19659,0,0,0,0.00,0.00,0,2
sample,2026-05-19T05:05:13Z,25818,5,5,5,80,1000,15678,0,0,0,0.00,0.00,0,2
sample,2026-05-19T05:05:18Z,30981,6,6,5,80,1000,15543,0,15543,0,100.00,0.00,1,2
sample,2026-05-19T05:05:23Z,36152,7,7,5,80,1000,51274,41480,51274,0,100.00,80.89,2,2
sample,2026-05-19T05:05:29Z,41299,8,8,5,80,1000,40868,40868,40868,0,100.00,100.00,3,2
off,2026-05-19T05:05:29Z,41333,8,8,5,80,1000,40868,40868,40868,0,100.00,100.00,3,0
```

### ours-w10
```csv
event,timestamp,elapsed_ms,window,window_seq,window_sec,threshold_pct,min_pte_updates,pte_delta,hit_delta,refault_delta,lost_delta,access_pct,fast_pct,consecutive,node_balancing
start,2026-05-19T05:06:39Z,0,0,1,10,80,1000,0,0,0,0,0.00,0.00,0,2
sample,2026-05-19T05:06:50Z,10195,1,1,10,80,1000,0,0,0,0,0.00,0.00,0,2
sample,2026-05-19T05:07:00Z,20374,2,2,10,80,1000,32802,0,0,0,0.00,0.00,0,2
sample,2026-05-19T05:07:10Z,30554,3,3,10,80,1000,23418,0,0,0,0.00,0.00,0,2
sample,2026-05-19T05:07:20Z,40724,4,4,10,80,1000,26658,0,26658,0,100.00,0.00,1,2
sample,2026-05-19T05:07:30Z,50851,5,5,10,80,1000,78729,73279,78729,0,100.00,93.07,2,2
sample,2026-05-19T05:07:40Z,60994,6,6,10,80,1000,50352,50352,50352,0,100.00,100.00,3,2
off,2026-05-19T05:07:41Z,61042,6,6,10,80,1000,50352,50352,50352,0,100.00,100.00,3,0
```
