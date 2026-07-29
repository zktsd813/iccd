# PR Inverse-Capacity ON Decision Audit

Date: 2026-07-11

## Scope

This audit explains why the inverse-capacity controller turns migration ON
for GAPBS PR at local16, local32, and local48. It uses the completed generated
`-g 29`, 8-trial sweep and the corresponding kernel and controller source.

The short conclusion is:

- The recorded ON decisions are arithmetically correct under the implemented
  policy.
- Every confirmed PR START also satisfies STOP. ON is selected only because
  the explicit arbitration order gives confirmed START precedence.
- The signal is a scan-to-refault reuse-time distribution, not a physical
  memory access-latency distribution.
- START extrapolates an access-conditioned remote fault-event CDF to all
  remote resident pages. Those are different populations.
- `L` is current local resident occupancy, not the configured 16/32/48 GiB
  local-tier capacity. PR's local occupancy can fall to about 4-5 GiB near
  trial startup, making the START requirement very small.
- PR has no main-phase gate. Restarts occur on both sides of the printed build
  boundary, but the GAPBS output does not timestamp the later edge-list cleanup
  and graph squishing, so it cannot provide an exact builder/trial split.

The main problem is therefore not a missing sample or a percentile arithmetic
bug. It is that the policy interprets a reuse-time sample as relocatable
resident capacity without modeling sampling coverage, phase, migration cost,
or reuse benefit.

## Exact Decision

For a valid window, define:

- `L`: current workload pages resident on the local node.
- `R`: current workload pages resident on the remote node.
- `q`: local P75 scan-to-refault latency.
- `S`: strict remote fault CDF, `F_R(<q)`.
- `I`: inclusive remote fault CDF, `F_R(<=q)`.

START is:

```text
H = 0.75 * L
B = H / R
START_RAW = S * R >= 0.75 * L
```

Two consecutive raw START windows produce `START_CONFIRMED`.

The unchanged STOP condition is:

```text
T = 0.25 * L
STOP_RAW = (I * R) / T > 0.9
```

Because `I >= S`, START structurally implies STOP:

```text
START_RAW
=> S * R >= 0.75 * L
=> I * R >= 0.75 * L
=> (I * R) / (0.25 * L) >= 3.0
=> STOP_RAW
```

The STOP threshold is only `0.9`. Therefore this overlap is not an occasional
edge case. It follows directly from the two formulas. The implementation then
uses:

```text
START_CONFIRMED > STOP_RAW > HOLD
```

Across PR, all 63 confirmed START windows also requested STOP. All 16 actual
migration-start transitions were `START` overriding `STOP`. The first raw
START window commonly stops migration, and the second consecutive window
restarts it.

## What The Samples Measure

The remote kernel path computes:

```text
hint fault latency = hint fault time - page-table scan time
```

The local path similarly measures from installation of a sampled `PROT_NONE`
PTE to the later local refault. These values are page reuse intervals after a
sampling scan. They are not DRAM or CXL load service times.

The weighted KLL sketch receives one item for each observed hint-fault or
local-refault event, weighted by `folio_nr_pages()`. It does not store a page
identity or deduplicate resident pages. Consequently:

- A scanned page that is not accessed again contributes no latency sample.
- A page can contribute again after a later re-protection cycle.
- The CDF is conditional on observed fault events, not uniform over resident
  pages and not proportional to raw load/store accesses.
- START nevertheless computes `S * R`, applying the event CDF to all remote
  resident pages from `/proc/<pid>/numa_maps`.

There is also temporal carry-over. The sketch selects its window sequence at
fault time, not when the probe is armed. A probe installed in an earlier
window or phase can therefore refault into a later window. For example,
local16 W5 recorded about 151 thousand local KLL samples and 151 thousand
current-window refaults, but only about 81 thousand current-window PTE probe
installs. Its local P75 was 57.924 seconds. This is consistent with outstanding
probes crossing controller-window boundaries.

## PR Phase Timeline

The native PR output gives graph-generation time and the time spent in
`MakeGraphFromEL()`. A later source audit found that the printed `Build Time`
does not include destruction of the generated edge list or the subsequent
`SquishGraph()` call. The cumulative printed boundary is therefore an
approximate builder milestone, not the exact first-trial start.

The earlier transition counts below use that printed boundary and must be
read as an approximate timeline. They are retained to document how the audit
was computed; they do not prove that a transition happened in a PR trial.

| Local | Generation end | Printed build boundary | START transitions by the earlier approximate partition |
| ---: | ---: | ---: | ---: |
| 16 GiB | 110.280 s | 438.011 s | 1 / 2 / 3 |
| 32 GiB | 106.313 s | 392.502 s | 1 / 3 / 4 |
| 48 GiB | 100.889 s | 360.935 s | 0 / 1 / 1 |

At least the transitions before the printed boundary occur during graph
generation/build. Transitions shortly after it can still belong to edge-list
cleanup or graph squishing, so the previous statement that exactly eight of
16 restarts occur before PR trials was too strong. The controller's main-phase
gate is disabled for PR, so all of these builder samples can directly change
migration state.

The measured ON time by the same earlier approximate partition was:

| Local | Generation ON | To printed build boundary ON | After printed build boundary ON |
| ---: | ---: | ---: | ---: |
| 16 GiB | 99.742 / 110.280 s (90.4%) | 267.003 / 327.732 s (81.5%) | 343.033 / 449.069 s (76.4%) |
| 32 GiB | 96.545 / 106.313 s (90.8%) | 162.700 / 286.189 s (56.9%) | 246.398 / 428.643 s (57.5%) |
| 48 GiB | 86.504 / 100.889 s (85.7%) | 126.412 / 260.046 s (48.6%) | 43.268 / 430.859 s (10.0%) |

The builder cleanup is visible shortly after the printed build boundary as a
process-residency drop:

| Local | Last pre-drop residency | First post-drop residency |
| ---: | ---: | ---: |
| 16 GiB | about 138.0 GiB at W26 / 427 s | about 68.3 GiB at W27 / 446 s |
| 32 GiB | about 137.8 GiB at W24 / 378 s | about 68.3 GiB at W25 / 401 s |
| 48 GiB | about 138.0 GiB at W22 / 354 s | about 68.2 GiB at W23 / 370 s |

This release of generation/build memory changes both `L` and `R`. Subsequent
placement changes can reduce current local occupancy even further.

## Concrete START Evidence

The first confirmed START at each capacity was not close to the KLL rank-error
boundary:

| Local | Window / time | Phase | Local P75 | `B` required | Strict remote CDF | Margin |
| ---: | ---: | --- | ---: | ---: | ---: | ---: |
| 16 GiB | W5 / 92.408 s | generation | 57.924 s | 22.233% | 89.845% | +67.612 pp |
| 32 GiB | W6 / 90.864 s | generation | 55.916 s | 64.889% | 83.812% | +18.923 pp |
| 48 GiB | W13 / 187.808 s | build | 53.304 s | 51.973% | 93.704% | +41.731 pp |

The first confirmed START well after the printed build boundary shows the
effect of current resident `L`. It falls after the observed large builder
cleanup, although the un-timestamped GAPBS output does not provide an exact
first-trial marker:

| Local | Window / time | Current `L / R` | `0.75L` | `B` required | Strict remote CDF | Local P75 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 16 GiB | W32 / 523.257 s | 4.015 / 67.273 GiB | 3.011 GiB | 4.476% | 52.055% | 3.560 s |
| 32 GiB | W30 / 475.111 s | 5.145 / 66.143 GiB | 3.859 GiB | 5.834% | 62.745% | 4.332 s |
| 48 GiB | W28 / 449.156 s | 5.172 / 66.116 GiB | 3.879 GiB | 5.867% | 57.528% | 6.664 s |

At these rows, the controller is not asking whether 75% of the configured
16/32/48 GiB local tier can be replaced by faster remote pages. It asks whether
75% of the workload's current 4-5 GiB local occupancy can be represented by
the extrapolated remote CDF. That is a much easier condition.

If the original `A` meant configured physical local-tier capacity, the current
implementation does not implement that meaning. An open-loop replay replacing
only START's `L` with fixed 16/32/48 GiB leaves local16 unchanged, reduces
local32 ON time from 505.643 to 464.211 seconds, and makes local48 stop one
window earlier. It does not by itself solve PR, but it confirms that the
capacity definition materially affects some decisions.

## Why A 10% START Margin Does Little

A relative 10% guard requires:

```text
S * R >= 1.10 * 0.75 * L
```

Fifteen of the 16 recorded PR migration-start rows still satisfy this
condition. Local16 and local48 replay exactly the same trajectory. Only a late
local32 restart is removed, reducing replayed ON time by 41.432 seconds while
leaving the final state OFF.

This is expected: most PR START margins are tens of percentage points, while
a relative 10% guard adds only `0.1B` percentage points to the required CDF.
The primary PR behavior is not a 10% measurement-boundary problem.

## Performance Cross-Check

The fixed OFF/ON baselines use kernel build 23, while the inverse-capacity run
uses build 27. The following values are directional, not a controlled
same-kernel comparison. They still show an important phase pattern.

| Local | Fixed OFF generation / build / average trial | Fixed ON generation / build / average trial |
| ---: | ---: | ---: |
| 16 GiB | 96.531 / 294.363 / 43.720 s | 106.269 / 311.427 / 50.835 s |
| 32 GiB | 103.369 / 292.212 / 44.170 s | 103.907 / 289.445 / 45.027 s |
| 48 GiB | 99.391 / 287.538 / 44.552 s | 76.888 / 234.664 / 45.854 s |

Fixed ON does not improve the reported PR trial average at any capacity. At
local48 it improves total elapsed time because generation and build become
much faster, even though the trial average becomes slower. This supports the
user's phase-level intuition: initial migration can help construct and place
the graph, while continued or restarted migration during repeated PR trials
can add fault, copy, and demotion cost without enough benefit.

The inverse controller also retains high movement volume despite spending time
OFF. Its promotion plus demotion volume is about 101%, 88%, and 84% of fixed
ON at local16, local32, and local48, respectively. Much of the movement occurs
during generation and build, before the reported trials.

## Assessment

The direct reason for each ON decision is:

1. PR produces a large local P75 reuse interval.
2. A large fraction of observed remote refault events occur before that local
   P75.
3. Multiplying that fraction by all current remote resident pages exceeds
   `0.75 * current_local_resident_pages` for two windows.
4. Confirmed START overrides the simultaneous STOP request.

The deeper policy problems are:

1. **Population mismatch:** fault-event CDF multiplied by resident capacity.
2. **Capacity ambiguity:** current local occupancy used where configured local
   capacity may have been intended.
3. **Phase blindness:** graph generation, graph build, and PR trials share one
   policy despite different migration benefit.
4. **No benefit-cost guard:** fast refault does not imply that page-copy and
   demotion cost will be amortized, especially for PR's high-MLP graph stream.
5. **Structural START/STOP overlap:** the formulas cannot express an
   unambiguous state; arbitration alone selects ON.

## Recommended Next Experiment

Before changing the generic controller, run a same-kernel, fresh-VM PR
ablation with the existing generated `-g 29` command:

1. Current inverse-capacity policy.
2. START using configured local-tier capacity instead of current local
   occupancy.
3. Initial migration enabled, restart disabled after the PR trial boundary.
4. A coverage-aware START estimate based on scanned pages and unique/observed
   refaulted pages, rather than `remote_fault_CDF * remote_resident_pages`.

Record generation time, build time, every trial time, phase-specific movement,
resident placement, and hint-fault counts. The present evidence most strongly
predicts that PR needs phase-aware initial migration followed by a stable OFF
state during trials, not a slightly larger global START margin.
