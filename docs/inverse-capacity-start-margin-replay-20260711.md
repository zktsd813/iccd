# Inverse-Capacity START Margin Replay

- Date: 2026-07-11
- Input: completed local16/local32/local48 inverse-capacity sweep
- Primary scenario: 10% relative conservative START margin

## Question

Test whether making START slightly harder can prevent the slow PR/GUPS policy
branches without unnecessarily turning migration off for Silo.

The requested 10% error is defined as a relative capacity guard:

```text
current START:
remote_fast_pages >= 0.75 * local_pages

relative-10% START:
remote_fast_pages >= 1.10 * (0.75 * local_pages)
```

With the logged integer operands, the replay evaluates:

```text
10 * remote_strict_cdf_ppm * remote_pages
    >= 11 * 750000 * local_pages
```

STOP, two-window confirmation, the main-phase gate, and arbitration remain
unchanged:

```text
confirmed START > STOP > HOLD
```

## Replay Validation

The replay first runs with a zero margin. It reproduces every recorded START
raw value, consecutive count, confirmation, STOP request, arbitration,
migration transition, final state, and ON/OFF duration in all 18 cases.

```text
status                   PASS
replayed cases           18 / 18
zero-margin mismatches   0
```

STOP is recomputed from the recorded resident-capacity ratio and its strict
`> 0.9` threshold rather than copied as an opaque decision bit.

## Relative-10% Result

The table lists the nine traces whose external migration trajectory changes.
The other nine traces are exactly unchanged through exit.

| Case | Current ON | Replay ON | Current -> replay final | First divergence |
| --- | ---: | ---: | --- | ---: |
| local16 Graph500 | 313.534 s | 272.113 s | OFF -> OFF | W4, 66.426 s |
| local32 PR | 505.643 s | 464.211 s | OFF -> OFF | W25, 401.151 s |
| local32 BC | 430.615 s | 375.104 s | ON -> ON | W10, 157.793 s |
| local32 GUPS | 695.176 s | 55.036 s | ON -> OFF | W3, 54.981 s |
| local32 BTree | 155.433 s | 124.585 s | OFF -> OFF | W14, 176.527 s |
| local32 Graph500 | 221.631 s | 180.829 s | OFF -> OFF | W20, 261.535 s |
| local48 BC | 239.073 s | 216.920 s | OFF -> OFF | W33, 504.295 s |
| local48 Graph500 | 202.843 s | 171.963 s | OFF -> OFF | W10, 178.201 s |
| local48 Silo | 635.763 s | 595.999 s | ON -> OFF | W31, 507.478 s |

Unchanged traces:

```text
local16: PR, BC, GUPS, BTree, Silo
local32: Silo
local48: PR, GUPS, BTree
```

Only two final states change: local32 GUPS and local48 Silo change from ON to
OFF. Other changed cases keep their recorded final state.

## PR

The margin does not change local16 or local48 PR at all. Local32 PR remains
final-OFF and loses 41.432 seconds of trace-driven ON time, but its first
external divergence occurs late at 401.151 seconds.

This replay therefore gives no evidence that a relative 10% START margin will
solve PR performance. PR requires an actual rerun or a different condition;
its local16/local48 decision traces are too far from this margin boundary.

## GUPS

The strongest effect is local32 GUPS.

```text
current:
  OFF W2 34.114 s
  START W3 54.981 s
  final ON, total ON 695.176 s

relative 10% replay:
  OFF W2 34.114 s
  no immediate W3 restart
  trace-only START W22 327.625 s
  trace-only OFF W23 348.547 s
  final OFF, trace-driven ON 55.036 s
```

At W3, the current strict remote CDF exceeds `B` by only 0.432 percentage
points:

```text
B                     69.158%
strict remote CDF     69.590%
relative-10 threshold 76.074%
```

The proposed predicate therefore rejects the marginal immediate restart that
selected the slow ON feedback branch.

Local16 GUPS is unchanged because its remote-fast fraction is far above the
capacity requirement. Local48 GUPS is also unchanged because `B > 100%`
already makes START impossible. The relative 10% guard specifically addresses
the observed local32 boundary, not GUPS at every capacity.

## Silo Tradeoff

Local16 and local32 Silo are exactly unchanged. This is desirable because
their current controller behavior remains close to migration ON.

Local48 Silo changes. Its first restart is delayed by one window, and the
replay ends OFF after a cleanup-tail decision:

```text
current:    OFF W30 -> START W31 -> OFF W38 -> START W40, final ON
relative10: OFF W30 -> START W32 -> OFF W38 -> START W40 -> OFF W41
```

The final W41 row occurs after the timed 200-second transaction output, during
process cleanup. The more relevant possible transaction cost is the delayed
first restart. A real run is required to measure that cost.

## Absolute-10pp Sensitivity

An alternative interpretation is to require the remote strict CDF to exceed
`B` by 10 absolute percentage points. This is substantially stronger than the
relative guard:

```text
relative 10%: changes 9 / 18 traces; changes 2 final states
absolute 10pp: changes 12 / 18 traces; changes 3 final states
```

Absolute 10pp suppresses all local32 GUPS restarts, but also changes local16
BC to final OFF and introduces more unrelated Silo transitions. The relative
10% interpretation is the safer first candidate.

## Counterfactual Limit

This is an open-loop trace replay, not a runtime simulation. Rows are exact
only until the first migration transition differs. At the first mismatch the
event CSV marks `divergence`; every later row is permanently marked
`trace_only` because those samples were collected under the original
migration state.

Consequently:

- The replay proves that relative 10% rejects local32 GUPS W3.
- The later 55.036-second ON total is useful trace sensitivity, not a causal
  prediction of a new run.
- No new elapsed time can be inferred from these recorded samples.
- Kernel/controller modification and real reruns are required for performance
  validation.

## Conclusion

A relative 10% capacity guard is promising for local32 GUPS and has little PR
effect. It preserves local16/local32 Silo exactly but delays local48 Silo's
first restart. The next efficient experiment is a targeted same-kernel matrix
for PR, GUPS, and Silo using the relative guard, rather than immediately
adopting the stricter absolute-10pp rule.

Artifacts:

- [Relative-10% summary](../motivation/3_realworld/VM/results/20260711T-inverse-capacity-start-margin-replay/relative10/start_margin_replay_summary.csv)
- [Relative-10% per-window replay](../motivation/3_realworld/VM/results/20260711T-inverse-capacity-start-margin-replay/relative10/start_margin_replay_events.csv)
- [Zero-margin audit](../motivation/3_realworld/VM/results/20260711T-inverse-capacity-start-margin-replay/zero/start_margin_replay_audit.txt)
- [Absolute-10pp sensitivity](../motivation/3_realworld/VM/results/20260711T-inverse-capacity-start-margin-replay/absolute10pp/start_margin_replay_summary.csv)
- [Replay implementation](../motivation/3_realworld/VM/scripts/replay_inverse_capacity_start_margin.py)
- [Replay tests](../motivation/3_realworld/VM/scripts/test_replay_inverse_capacity_start_margin.py)
