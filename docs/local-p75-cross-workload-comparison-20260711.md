# Local P75 Cross-Workload Comparison

Date: 2026-07-11

## Conclusion

PR has an unusually long and unusually stable local P75 during its measured
trial phase:

```text
PR local16: 6.696 s mean
PR local32: 6.618 s mean
PR local48: 6.528 s mean
```

The pooled PR main-phase mean is 6.608 seconds and the median is 6.568
seconds. This is longer than BC, Silo, BTree, and GUPS. A final-phase Graph500
comparison has too few valid windows to support a strong ranking.

This does not mean local DRAM takes seconds to serve an access.
`local_p75_ns` is the interval from installation of a sampled `PROT_NONE` PTE
to its later refault. It is a page reuse interval after sampling, not physical
memory service latency.

## Data

The comparison uses all 18 completed inverse-capacity runs:

```text
motivation/3_realworld/VM/results/20260711T-inverse-capacity-baseline-nosilo-local16-32-48
motivation/3_realworld/VM/results/20260711T-inverse-capacity-silo-local16-32-48
```

The workloads are PR, BC, GUPS, BTree, Graph500, and Silo at 16, 32, and 48
GiB of configured local memory.

Each observation is one valid controller window with:

```text
capacity_start_valid = 1
local_p75_ns > 0
event in {sample, off, restart}
```

The reported mean is an unweighted arithmetic mean of the per-window P75
values. It is not a quantile obtained by merging all underlying samples.

## Main-Phase Comparison

The offline phase-qualified comparison uses the following boundaries:

- PR and BC: reconstruct trial onset from process wall time and the sum of the
  eight reported trial times.
- GUPS, BTree, and Graph500: use the first residency observation reaching 99%
  of the final or peak measured working-set footprint.
- Silo: use the recorded main-phase gate.

A row is rejected when its P75 exceeds the time elapsed since the selected
phase boundary. Such a sample must have been armed before the phase boundary
and is therefore provable cross-phase carry-over.

| Workload | Windows | Mean local P75 | Median local P75 | IQR |
| --- | ---: | ---: | ---: | ---: |
| PR | 65 | 6.608 s | 6.568 s | 6.304-6.976 s |
| BC | 42 | 3.975 s | 2.922 s | 0.736-6.536 s |
| Silo | 30 | 1.722 s | 1.832 s | 0.960-2.380 s |
| BTree | 74 | 0.564 s | 0.592 s | 0.444-0.612 s |
| GUPS | 95 | 0.251 s | 0.224 s | 0.208-0.300 s |
| Graph500 | 5 | 0.097 s | 0.080 s | low-confidence final-phase sample |

PR is stable across local-memory configurations:

| Local memory | Mean local P75 |
| ---: | ---: |
| 16 GiB | 6.696 s |
| 32 GiB | 6.618 s |
| 48 GiB | 6.528 s |

Local16 has individual 11.95-12.96 second values during its anomalously long
third trial, but those rows do not create the central result. The median and
IQR remain centered near 6.5 seconds.

## Workload-Independent Cross-Check

A second sensitivity uses no workload phase marker:

1. Select valid rows in the 50%-98% interval of controller runtime.
2. Treat the 50% point as a new observation epoch.
3. Reject a row if its P75 is longer than time elapsed since that epoch.

This prevents a latency armed before the tail epoch from being labeled as a
tail observation.

| Workload | Windows | Tail mean | Tail median |
| --- | ---: | ---: | ---: |
| PR | 67 | 7.004 s | 6.592 s |
| BC | 60 | 4.042 s | 1.892 s |
| Silo | 28 | 1.773 s | 1.926 s |
| BTree | 50 | 0.527 s | 0.588 s |
| GUPS | 48 | 0.248 s | 0.222 s |
| Graph500 | 22 | 12.032 s | 1.550 s |

The independent filter reproduces PR's approximately 6.5-7.0 second central
value. Graph500's tail mean is dominated by a few 26-72 second construction or
root-selection carry-over observations; its 1.550 second median shows that the
arithmetic mean is not representative.

## Why Raw Means Are Misleading

The all-valid-window means include setup and cross-phase probe lifetime:

| Workload | Windows | Raw mean | Raw median | Maximum |
| --- | ---: | ---: | ---: | ---: |
| PR | 135 | 12.778 s | 6.568 s | 76.280 s |
| BC | 117 | 14.451 s | 3.092 s | 89.960 s |
| GUPS | 98 | 0.672 s | 0.226 s | 16.496 s |
| BTree | 85 | 10.646 s | 0.596 s | 126.776 s |
| Graph500 | 51 | 22.979 s | 19.100 s | 71.612 s |
| Silo | 39 | 42.980 s | 2.176 s | 290.796 s |

Examples make the distortion explicit:

- Silo's first gate-open rows report 226-291 second P75 values even though the
  main phase has been open for only about one millisecond. Local48 retains a
  269 second value at 21 seconds after gate opening.
- BTree reports 100-127 seconds around build-to-lookup transition and then
  settles at approximately 0.4-0.6 seconds.
- GUPS has initial 12-16 second observations and then settles at approximately
  0.2-0.3 seconds.
- PR reports 60-76 seconds during graph construction and then centers near
  6-7 seconds during trials.

These values are possible because outstanding probes cross controller windows
and workload boundaries. A controller window does not contain only probes
installed during that same window.

## Interpretation For PR START

PR runs approximately 45-47 seconds per trial and performs 20 PageRank
iterations. One graph traversal therefore takes roughly 2.3 seconds. A local
P75 near 6.6 seconds is consistent with a page being revisited after roughly
three traversal periods.

The latency-form START rule is:

```text
B = (0.75 * L) / R
C = remote P_B reuse latency
START when C < local P75 reuse latency
```

After the PR16 refill, `B` rises to approximately P20, but local P75 remains
about 5.7-6.4 seconds. Recorded remote P20 values remain below that threshold,
so START continues to evaluate true.

The direct observation is therefore:

> PR's local P75 is high because PR has a long page-reuse cadence, not because
> local memory hardware is slow. Using that reuse interval as the START
> latency threshold makes the START comparison easy to satisfy.

The deeper policy assumption remains that a percentile of observed refault
events represents the same percentile of remote resident capacity. This
comparison does not identify or deduplicate resident pages and does not prove
that the inferred capacity can still produce useful placement gain after the
local tier has been refilled.
