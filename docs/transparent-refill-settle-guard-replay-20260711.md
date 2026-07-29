# Transparent REFILL/SETTLED Guard Replay

Date: 2026-07-11

## Objective

Improve the inverse-capacity behavior observed for PR without using workload
names, workload output, phase markers, or a workload-specific schedule. The
decision may use only controller-visible placement and latency-distribution
signals.

The analysis covers the completed 18-case sweep:

```text
local capacity: 16, 32, 48 GiB
workloads:      PR, BC, GUPS, BTree, Graph500, Silo
```

## Why Simple Changes Are Insufficient

PR and BC are nearly indistinguishable during generated graph construction.
Their early resident placement and latency quantiles overlap, so an absolute
P75 or CDF threshold cannot reliably select PR without also changing BC.

Several generic counterfactuals had broad collateral effects:

- configured-capacity `L` changed 11 cases, including 9 non-PR cases;
- prefix-max `L` changed 6 cases, including 4 non-PR cases;
- resetting START on every transition changed 12 cases;
- a three- or five-window cooldown changed 12 cases;
- counting START only while OFF changed 16 cases.

Using configured local capacity only for START is specifically the wrong
minimal fix for the low-placement events:

| Case | Recorded `B` | Configured-capacity `B` | Strict remote CDF | Result |
| --- | ---: | ---: | ---: | --- |
| PR16 refill | 4.48% | 17.84% | 52.06% | PR still STARTs |
| PR32 refill | 5.83% | 36.28% | 62.74% | PR still STARTs |
| PR48 refill | 5.87% | 54.45% | 57.53% | PR still STARTs |
| BC32 low-placement START | 12.27% | 35.74% | 12.67% | useful BC START is removed |
| BC48 low-placement START | 13.18% | 54.19% | 15.15% | useful BC START is removed |

The useful distinction is not low local occupancy by itself. It is low local
occupancy combined with a grossly excessive inferred remote candidate set.

## Signals

For each valid controller window, define:

- `A`: configured physical local capacity in pages.
- `L`: current workload pages resident on the local node.
- `R`: current workload pages resident on the remote node.
- `F`: strict remote CDF below local P75.
- `H = 0.75L`: the existing inverse-capacity requirement.

The guard derives two dimensionless values:

```text
local occupancy = L / A
START excess    = (F * R) / H
                = F / B
```

`START excess=1` is the current START boundary. A value of 10 means that the
controller estimates ten times as much short-reuse remote capacity as the
normal START requirement.

## Guard State Machine

The guard does not reject the initial low-placement migration. It treats that
transition as a bounded refill episode.

### NORMAL

Run the existing inverse-capacity policy unchanged. When an actual confirmed
OFF-to-ON transition satisfies both conditions below, enter `REFILL`:

```text
L / A < 0.50
(F * R) / (0.75L) >= 4.0
```

### REFILL

Allow migration to repopulate the local tier. Existing natural STOP decisions
remain active. If local occupancy reaches 85% while confirmed START and STOP
overlap, give STOP priority for that window.

Any migration STOP during REFILL enters `SETTLED`, including a natural STOP
that occurs before the 85% ceiling.

### SETTLED

Suppress and reset START while local occupancy remains at least 50%. Continue
recording the raw CDF and capacity diagnostics.

If occupancy later falls below 50%, re-arm `NORMAL` and require the normal two
valid START windows again. This is an occupancy-epoch latch, not a permanent
migration disable.

No branch uses a workload identifier or phase signal.

## Trigger Separation

Exactly three of the recorded 41 OFF-to-ON transitions entered REFILL. They
were the low-placement PR transitions:

| Case | Window / elapsed | `L/A` | START excess |
| --- | ---: | ---: | ---: |
| PR16 | W32 / 523.257 s | 25.095% | 11.629x |
| PR32 | W30 / 475.111 s | 16.078% | 10.755x |
| PR48 | W28 / 449.156 s | 10.775% | 9.805x |

The closest low-occupancy non-PR transitions were:

| Case | `L/A` | START excess |
| --- | ---: | ---: |
| BC32 | 34.318% | 1.033x |
| BC48 | 24.316% | 1.150x |

The closest non-PR transition with excess at least 4x was BC16, but its local
occupancy was 70.793%, so it was not a refill event.

A sensitivity replay used trigger occupancies of 40%, 50%, and 60%, crossed
with excess thresholds of 2x, 4x, and 8x. All nine combinations classified
the same three PR refill events and no non-PR event. The defaults, 50% and 4x,
sit well inside the observed gap rather than directly on one trace value.

## Why REFILL Is Preserved

The first low-placement ON interval produced real placement progress:

| Case | First refill movement | Local resident gain |
| --- | ---: | ---: |
| PR16 | 10.619 GiB promoted | +10.619 GiB |
| PR32 | 17.007 GiB promoted | +17.587 GiB |
| PR48 | 38.028 GiB promoted | +38.028 GiB |

This evidence does not show that Linux failed to promote during refill. The
problem appears after placement saturation:

- PR16 W34-W40 moved about 3.49 GiB while local residency gained only
  0.28 GiB. Later restarts moved about 13.26 GiB while residency gained about
  0.10 GiB.
- PR32's later full-placement W39-W50 interval moved about 4.38 GiB while
  local residency decreased slightly.
- PR48 already behaved like the proposed state machine: it refilled, reached
  about 90% local occupancy, and naturally stopped at W30.

The guard therefore preserves the useful refill and suppresses repeated
migration after its placement benefit has saturated.

## Canonical Replay Result

The zero-guard replay reproduced every recorded raw START, counter,
arbitration, state, and external transition in all 18 cases.

```text
status                         PASS
cases                          18
policy window events           688
zero-baseline mismatches       0
refill-trigger cases           3
cases with state divergence    2
non-PR state divergences       0
```

| Case | Current ON | Guarded ON | Current starts/stops | Guarded starts/stops | Final state |
| --- | ---: | ---: | ---: | ---: | --- |
| PR16 | 709.777 s | 383.893 s | 6 / 6 | 4 / 5 | ON -> OFF |
| PR32 | 505.643 s | 307.113 s | 8 / 9 | 5 / 6 | OFF -> OFF |
| PR48 | 256.184 s | 256.184 s | 2 / 3 | 2 / 3 | OFF -> OFF |

PR48 is detected as a refill case but its external trajectory is already the
desired one, so it remains exactly unchanged.

All 15 non-PR workload/capacity cases retain every recorded state, external
action, transition count, final state, and ON duration in the open-loop
replay.

## Artifacts

Replay implementation:

```text
motivation/3_realworld/VM/scripts/replay_refill_settle_guard.py
```

Focused tests:

```text
motivation/3_realworld/VM/scripts/test_replay_refill_settle_guard.py
```

Canonical output:

```text
motivation/3_realworld/VM/results/20260711T-refill-settle-guard-replay/
  refill_settle_guard_summary.csv
  refill_settle_guard_events.csv
  refill_settle_guard_audit.txt
```

Verification completed:

- Python compilation: PASS.
- Unit tests: 8 / 8 PASS.
- Canonical replay: PASS.
- Summary/event schema and count audit: PASS.

## Limitations And Next Step

The replay is open-loop. After PR16 diverges at W33, later rows still contain
samples produced by the original ON trajectory. PR ON-time reductions are
trace-driven state estimates, not elapsed-time predictions.

This guard also does not remove the structural `START => STOP` overlap from
NORMAL mode. It bounds the empirically problematic refill episode while
preserving the existing policy elsewhere; a full semantic redesign remains a
separate question.

The non-PR preservation result is stronger because none of their actions ever
diverge; their full recorded traces remain on the original path.

The next safe step is to implement this guard behind an opt-in controller
option, leaving the default disabled. Then run fresh-VM PR and the nearest
collision cases, BC32 and BC48, followed by GUPS and Silo. A complete 18-case
rerun is required before making the guard the default.
