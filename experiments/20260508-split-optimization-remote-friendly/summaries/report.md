# Remote-friendly split optimization report

Date: 2026-05-08

Goal:
Find the intended local-memory split for the phase workload where:

- friendly phase: 4G moving hotset, remote-only offsets
- unfriendly phase: 32G streaming read, 4KB stride
- adaptive policy: `oracle_cgroup_global0`

The practical goal is to choose a local split that lets adaptive behavior keep
friendly performance close to migration-on while keeping unfriendly performance
close to migration-off.

## Workload Fix

The previous moving-friendly phase was not clean for off/on comparison because
its hotset could move into the local prefix. I added a remote-only phase preset:

- preset: `move15s4g-remote-split32`
- candidate family: `phase_move15s4g_remote_split32_stream4k_local<N>g`
- friendly hotset offsets observed: `16G`, `20G`, `44G`, `60G`
- local prefix being swept: `<N>G`
- unfriendly active window remains fixed: `0..32G`

The candidate names use intended local split. For example,
`local6g` means the phase-prefault placement targets `0..6G` local and the rest
remote. The cgroup local capacity remains `16G`.

## Experiments

Artifacts:

- 16G baseline:
  `/Serverless/iccd/experiments/20260508-phase-move15s4g-remote-split32-onoff-adaptive`
- coarse sweep, 4/8/12/14G:
  `/Serverless/iccd/experiments/20260508-split-sweep-coarse-remote-friendly`
- refinement sweep, 2/3/5/6G:
  `/Serverless/iccd/experiments/20260508-split-sweep-refine-low-remote-friendly`
- final check, 6G repeat and 7G:
  `/Serverless/iccd/experiments/20260508-split-sweep-final-6g7g-remote-friendly`

Common settings:

- `MEMORY=96G`
- guest node0: `32G`, host node0
- guest node1: `64G`, host node2
- `CAPACITY_PAGES=4194304`
- `NUMA_SCAN_SIZE_MB=4096`
- `SCAN_PERIOD_SCALE=100`
- `HOT_THRESHOLD_MS=0`
- `PHASE_MS=60000`
- `PHASE_REPEAT=3`
- `SAMPLE_MS=500`
- `THREADS=32`
- MGLRU: `0x0007`

## Score

For each split, I measured `off`, `on`, and `oracle_cgroup_global0`.

The balanced absolute score is:

```text
friendly_norm = min(adaptive_friendly_mean / max(on_friendly_mean), 1)
unfriendly_norm = min(adaptive_unfriendly_mean / max(off_unfriendly_mean), 1)
score = sqrt(friendly_norm * unfriendly_norm)
```

Friendly uses Mops/s. Unfriendly uses MiB/s. This avoids mixing raw units.

## Mean Results

| split | n adaptive | off friendly | on friendly | adaptive friendly | off unfriendly | on unfriendly | adaptive unfriendly | friendly norm | unfriendly norm | score | adaptive promote GiB | adaptive demote GiB |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2G | 1 | 228.5 | 1091.7 | 1382.3 | 824.3 | 3667.4 | 2907.5 | 1.000 | 0.647 | 0.804 | 15.50 | 2.86 |
| 3G | 1 | 228.5 | 1102.1 | 1342.1 | 1016.5 | 3652.8 | 3545.9 | 1.000 | 0.789 | 0.888 | 13.29 | 1.30 |
| 4G | 1 | 228.5 | 1084.1 | 1317.8 | 1234.5 | 3793.7 | 2818.2 | 1.000 | 0.627 | 0.792 | 13.69 | 3.04 |
| 5G | 1 | 228.5 | 1011.1 | 1192.1 | 1465.7 | 3772.3 | 3358.1 | 1.000 | 0.747 | 0.864 | 12.42 | 2.90 |
| 6G | 2 | 228.4 | 990.6 | 1051.6 | 1712.6 | 3806.7 | 3572.8 | 0.954 | 0.795 | 0.871 | 14.03 | 5.39 |
| 7G | 1 | 228.5 | 977.9 | 1002.1 | 1969.8 | 3769.7 | 3909.9 | 0.909 | 0.870 | 0.889 | 12.63 | 4.73 |
| 8G | 1 | 228.2 | 856.7 | 989.7 | 2250.1 | 3349.7 | 2565.1 | 0.898 | 0.571 | 0.716 | 16.10 | 9.48 |
| 12G | 1 | 228.5 | 980.9 | 681.8 | 4046.4 | 3355.5 | 3238.9 | 0.619 | 0.720 | 0.668 | 14.24 | 11.32 |
| 14G | 1 | 228.6 | 434.2 | 423.2 | 4451.7 | 2825.6 | 3299.7 | 0.384 | 0.734 | 0.531 | 13.81 | 13.03 |
| 16G | 1 | 228.4 | 635.0 | 404.9 | 4495.5 | 3004.5 | 3349.8 | 0.367 | 0.745 | 0.523 | 15.14 | 14.94 |

Mean-score ranking:

1. `7G`: `0.889`
2. `3G`: `0.888`
3. `6G`: `0.871`
4. `5G`: `0.864`

## Median Cross-check

| split | off friendly | on friendly | adaptive friendly | off unfriendly | on unfriendly | adaptive unfriendly | friendly norm | unfriendly norm | score |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2G | 228.3 | 912.4 | 1801.7 | 824.9 | 3443.9 | 2926.2 | 1.000 | 0.651 | 0.807 |
| 3G | 228.4 | 1001.8 | 1800.0 | 1016.5 | 3581.1 | 3544.2 | 1.000 | 0.788 | 0.888 |
| 4G | 228.3 | 986.8 | 1797.1 | 1235.9 | 3542.8 | 2803.2 | 1.000 | 0.623 | 0.790 |
| 5G | 228.4 | 621.4 | 1345.4 | 1465.2 | 3612.7 | 3349.9 | 1.000 | 0.745 | 0.863 |
| 6G | 228.2 | 374.9 | 947.5 | 1712.8 | 3658.5 | 3601.2 | 0.946 | 0.801 | 0.870 |
| 7G | 228.4 | 352.0 | 391.9 | 1968.5 | 3572.9 | 3908.0 | 0.391 | 0.869 | 0.583 |
| 8G | 228.1 | 499.4 | 612.8 | 2235.7 | 3196.5 | 2558.5 | 0.612 | 0.569 | 0.590 |
| 12G | 228.3 | 824.6 | 313.3 | 4044.7 | 3189.1 | 3235.2 | 0.313 | 0.720 | 0.474 |
| 14G | 228.5 | 315.8 | 301.0 | 4451.6 | 2719.3 | 3294.8 | 0.300 | 0.733 | 0.469 |
| 16G | 228.2 | 449.4 | 302.1 | 4496.3 | 2753.0 | 3363.8 | 0.302 | 0.748 | 0.475 |

Median-score ranking:

1. `3G`: `0.888`
2. `6G`: `0.870`
3. `5G`: `0.863`
4. `2G`: `0.807`

## Interpretation

The high-local splits, especially `12G..16G`, are not optimal for adaptive
phase switching. They preserve the unfriendly off baseline, but they consume
too much of the 16G local capacity before friendly promotion has a chance to
help. Adaptive friendly performance collapses at these splits.

Very low splits, especially `2G`, leave enough headroom for promotion and make
friendly fast, but the unfriendly baseline is too low.

The useful region is `3G..6G`:

- `3G` has the best median score and nearly the best mean score.
- `6G` gives a more unfriendly-biased tradeoff, but repeat behavior varied.
- `7G` had the best mean score by a tiny margin, but its friendly median was
  very weak, so I do not treat it as robust.

## Recommendation

Use `3G` intended local split as the balanced target.

In practical terms:

- Keep only about `3G` of the streaming/unfriendly prefix resident on local
  memory before phases begin.
- Leave most of the 16G local capacity available for dynamic friendly hotset
  promotion.
- Avoid the previous `16G local + 16G remote` split for this adaptive phase
  pair. It is good for the unfriendly off baseline, but it blocks the useful
  adaptive behavior.

If the objective becomes more unfriendly-biased, use `6G` as the safer
alternative. It gives higher unfriendly adaptive throughput than `3G`, but it
does not preserve friendly median as well.

## Feedback Rule

A simple controller rule from this sweep:

1. Start the phase pair at `3G` intended local split.
2. If unfriendly adaptive throughput is below the required floor, increase the
   local split toward `5G` or `6G`.
3. If friendly median drops below the target, decrease the local split toward
   `3G`.
4. Do not increase beyond `8G` unless the workload objective explicitly values
   unfriendly throughput over friendly responsiveness.

This reaches the observed balanced optimum while still allowing a controlled
shift toward unfriendly protection when needed.

