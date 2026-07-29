# Same-Window CDF-Gap Controller

## Policy Contract

The controller implements one diagnostic two-tier NUMA policy named
`window-cdf-gap`. START compares the local and remote latency CDFs from one
completed kernel sampling window. STOP independently compares the remote
resident page mass estimated to be at or below local P75 with the local
resident page mass estimated to be above local P75. The controller state gates which signal can cause a
transition: while migration is ON, post-START retention is checked before
STOP; while migration is OFF, only START is consumed. The raw signals remain
in the CSV as telemetry, but none can override the signal selected by the
prior controller state. Both transitions require one fresh, valid window and
have no multi-window confirmation.

The controller initially enables migration. A transition changes
`migration_enabled` only; NUMA scanning and fault sampling remain active so an
off state can still produce the next decision.

## Kernel Snapshot

The required `fault_latency_quantiles` ABI is `quantile_snapshot_v5` with:

```text
schema quantile_snapshot_v5
algorithm kll_weighted_ms_v1
value_source sketch_latency_ms_to_ns
window_seq
local_protected_pages
local_cancelled_pages
local_dropped_fault_pages
remote_protected_pages
remote_cancelled_pages
remote_dropped_fault_pages
local_total
remote_total
local_q75_ns
local_cdf_lt_local_q75_ppm
local_cdf_le_local_q75_ppm
remote_cdf_lt_local_q75_ppm
remote_cdf_le_local_q75_ppm
```

`local_total` and `remote_total` include only faults whose active probe tier
matches the fault tier and whose install sequence equals the fault-time
window. Consequently, protection counts, fault totals, P75, and CDF values in
one snapshot describe the same window. Dropped-fault counts are logged for
audit but are not added to the policy numerator or denominator.

The v5 controller probe ABI accounts only order-0 folios. A large folio cannot
retain one physical probe identity across PMD splitting, so mixing THP pages
into the RSS projection would violate the sampled-population assumption. The
production runner therefore sets and verifies both transparent-hugepage mode
and defragmentation mode as `never`; these values are recorded in
`config.meta`.

## Same-Window Latency Boundaries

The common latency boundary is the current window's local P75. START uses the
strict CDF on both tiers:

```text
local_strict_share_ppm  = local_cdf_lt_local_q75_ppm
remote_strict_share_ppm = remote_cdf_lt_local_q75_ppm
```

The strict `< local_q75_ns` comparison excludes the tie mass at the quantized
P75 boundary from both sides of the START comparison. START uses the reported
local strict CDF rather than assuming it is exactly 75%.

STOP uses the inclusive CDF on both tiers:

```text
local_inclusive_share_ppm  = local_cdf_le_local_q75_ppm
remote_inclusive_share_ppm = remote_cdf_le_local_q75_ppm
```

The inclusive `<= local_q75_ns` STOP boundary is deliberate. KLL quantization
and ties can make each inclusive share differ from its strict share, so the
fields are not interchangeable.

Local P75 is sufficient here as a relative hotness boundary, not as an
absolute latency objective. A run that needs an absolute service-latency
guarantee requires a separate policy signal.

## Valid Window

For each tier:

```text
eligible_protected_pages = protected_pages - cancelled_pages
```

A window is valid only when:

- the schema, algorithm, and value source match the required ABI;
- the sequence and all required counts are present and coherent;
- each tier has at least 256 eligible protected pages;
- the local tier has at least 16 matching faults;
- each fault total is no greater than its eligible protection count;
- the local P75 and both tiers' strict and inclusive CDF values are present,
  in range, and each strict CDF is no greater than its inclusive CDF.

There is no minimum remote-fault count. Protection and fault counts gate window
validity and are direct inputs to STOP, but neither a fault count nor a
fault/protection rate enters START or its retention guard. Missing RSS never
invalidates a policy window; it only leaves the RSS projection fields
unavailable. An invalid window requests HOLD.

## Residency, Capacity, And Diagnostic Projections

Each decision attempts to reread the PID in `--workload-pid-file`, walks its
process tree, and sums `N<node>=` pages from `/proc/<pid>/numa_maps`:

```text
L = current local resident pages
R = current remote resident pages
```

`L` and `R` are diagnostic inputs only. They are not inputs to START, its
retention guard, STOP, or arbitration.

The physical local capacity `C` is the local node's `MemTotal` converted to
base pages. `--local-capacity-pages` can override it for an experiment. The
runner also records the former 75% target:

```text
T = floor(C * 75 / 100)
```

`LOCAL_TARGET_PCT` defaults to 75. `C`, `T`, and the capacity source are retained
for diagnostics and compatibility only; none affects START, STOP, or
arbitration.

RSS-scaled STOP mass uses current process residency:

```text
local_p75_slow_pages =
    L * (1 - local_cdf_le_local_q75_ppm / 1,000,000)

remote_p75_fast_pages =
    R * remote_cdf_le_local_q75_ppm / 1,000,000
```

These projected masses feed STOP. START still does not use residency, except
for the explicit `hot-coverage` START mode.

## START gap and post-START retention guard

The raw START signal is the strict-CDF gap at the same window's local P75:

```text
start_cdf_gap_ppm = remote_cdf_lt_local_q75_ppm
                    - local_cdf_lt_local_q75_ppm

START_GAP_RAW = start_cdf_gap_ppm >= 100,000
START_RAW = START_GAP_RAW
```

When the prior controller state is OFF, a fresh, valid gap of at least 10
percentage points enables migration immediately. The transition latches that
window's gap as `start_cdf_gap_baseline_ppm`. START has no trend prerequisite.
This integer comparison has no RSS, physical capacity, fault/protection rate,
or projected-page input.

After a controller-issued START, every fresh, valid ON-state window computes:

```text
start_cdf_gap_reduction_ppm = start_cdf_gap_baseline_ppm
                              - start_cdf_gap_ppm

START_RETENTION_RAW = start_cdf_gap_reduction_ppm >= 50,000
```

If the gap has fallen by at least 5 percentage points from the fixed START
baseline, migration is demonstrating the requested improvement and remains
ON even when `STOP_RAW` is true. The baseline stays fixed until STOP; it is not
replaced by each adjacent window. Initial ON has no START baseline and uses
STOP directly. Invalid and duplicate rows are HOLD and do not discard an
active baseline.

## RSS-Mass STOP And Arbitration

Let `L` and `R` be the current local and remote resident base-page counts for
the tracked workload:

```text
local_p75_slow_pages =
    L * (1 - local_cdf_le_local_q75_ppm / 1,000,000)

remote_p75_fast_pages =
    R * remote_cdf_le_local_q75_ppm / 1,000,000

stop_ratio = remote_p75_fast_pages / local_p75_slow_pages

STOP_RAW = stop_ratio > 0.9
```

Thus STOP asks whether the remote resident mass estimated to be faster than
local P75 is larger than the local resident mass estimated to be slower than
local P75. The comparison is strict: equality at 0.9 is not STOP. With CDFs in
ppm, the default comparison is evaluated exactly as:

```text
10 * R * remote_cdf_le_local_q75_ppm
    > 9 * L * (1,000,000 - local_cdf_le_local_q75_ppm)
```

Both inclusive CDFs come from the same kernel snapshot, while `L` and `R` are
read from the tracked process residency for the same controller decision.

STOP is immediate and has no confirmation counter. A post-START gap reduction
can suppress it while the controller is ON. State-gated arbitration is
recorded exactly as:

```text
state_gated(on:retain_if_start_reduced_else_raw_stop;off:raw_start;else:hold)
```

For every fresh, valid window:

```text
prior state ON after START:
    START_RETENTION_RAW -> HOLD ON
    otherwise STOP_RAW  -> OFF
    otherwise HOLD

prior state ON without a START baseline:
    STOP_RAW -> OFF, otherwise HOLD

prior state OFF:
    START_RAW -> ON and latch the START gap, otherwise HOLD
```

The two raw signals may overlap. An OFF window consumes START and latches its
gap. On the next fresh ON window, retention is checked before STOP. A
transition does not reevaluate the other signal in the same window. An invalid
or duplicate window is HOLD.

## Window Lifecycle

The controller polls every `--window-sec`, waits at least five seconds, and
opens a decision window at the earlier of a `remote_scan_cycles` advance and
the 20-second cap. A cycle-boundary row uses
`cycle_window_reason=cycle`. If no cycle boundary has arrived by the cap, the
current snapshot is still evaluated with
`cycle_window_reason=max_timeout`. The latter is a capped policy window, not a
diagnostic-only timeout.

A cycle-boundary snapshot covers a full remote scan cycle only when the prior
sampling boundary was also cycle-aligned. A capped boundary can split a remote
scan, so both that capped snapshot and the following cycle-boundary snapshot
may cover sequential subranges rather than the whole tier. Their installed-page
coverage and latency distributions therefore need not represent the whole
tier. Within each decision, however, the STOP numerator and denominator remain
internally same-window: all local and remote fault, CDF, and eligible-page terms
come from that one snapshot.

Startup first advances the kernel window to discard stale pre-run samples. The
first subsequently observed cycle establishes alignment and is also discarded:

```text
cycle_window_reason=cycle
window_reason=cycle_alignment_warmup
window_valid=0
arbitration=HOLD
```

If the first gate is a completed cycle, the controller logs that warmup
snapshot for audit, advances `local_fault_window`, and begins policy evaluation
at the next gate. If the first gate is instead the 20-second cap, that capped
snapshot is evaluated and establishes the sampling boundary; a later completed
cycle is not discarded as another warmup.

The normal read, decision, and advance order at every non-warmup gate is:

1. Read the current `quantile_snapshot_v5` window.
2. Read current workload residency for diagnostic projection and evaluate the
   policy from the snapshot's installed-page rates.
3. Apply the signal selected by the prior controller state and write
   one CSV row.
4. Write `1` to `local_fault_window` to advance the kernel window.

The production defaults are a one-second poll, a five-second minimum, and a
20-second cap. At the cap, the controller follows the same evaluation,
transition, logging, and kernel-window advance path:

```text
cycle_window_reason=max_timeout
evaluate current snapshot
apply START / retention / STOP arbitration
write controller row
advance local_fault_window
```

The cap does not force HOLD and does not clear alignment. If a cycle advance is
visible on the poll at exactly 20 seconds, the row is recorded as `cycle`;
otherwise it is the capped `max_timeout` policy row. STOP and its optional
START-baseline retention guard use the current ON-state window; START uses only
the current OFF-state gap.

## Runtime Interface

The production runner is `run_guest.sh`. Its final policy settings are:

```text
LOCAL_CAPACITY_PAGES             optional; default local-node MemTotal
LOCAL_TARGET_PCT                 default 75; diagnostic only
START_CDF_GAP_PPM                default 100000
START_CDF_GAP_REDUCTION_PPM      default 50000
STOP_CAPACITY_RATIO_THRESHOLD    default 0.9
CYCLE_WINDOW_MIN_SEC             default 5
CYCLE_WINDOW_MAX_SEC             default 20
WINDOW_MIN_PROTECTED_PAGES       default 256 per tier
WINDOW_MIN_LOCAL_FAULT_PAGES     default 16
WINDOW_CONSECUTIVE               fixed default 1
THP_MODE                         fixed default never
THP_DEFRAG                       fixed default never
```

The matching controller options are:

```text
--local-capacity-pages
--local-target-pct
--start-cdf-gap-ppm
--start-cdf-gap-reduction-ppm
--stop-capacity-ratio-threshold
--window-min-protected-pages
--window-min-local-fault-pages
--window-consecutive
```

The runner supports `POLICY_ACTIVATION_FENCE=1` for a workload that prefaults
and waits on ready/start files. It launches with balancing, migration, and
sampling disabled; finds the actual workload PID after the ready marker;
records its residency; activates the knobs and controller; waits for the
controller-ready marker; then releases the workload.

## Output

`controller.csv` records the exact snapshot inputs, the current strict START
CDF gap, the latched START baseline, reduction from that baseline, retention
flag and thresholds, eligible protection counts, current residency,
RSS-projected P75 fast/slow masses and STOP ratio, the raw signals,
state-gated arbitration result, and migration transition. For
CSV compatibility, `start_consecutive=1` and `start_confirmed=1` mean that a
fresh valid raw START was consumed while the prior state was OFF; both are zero
otherwise. Transition rows use `event=on` or `event=off`; ordinary observations
use `event=sample`.

`config.meta` records the strict START boundary, gap and reduction thresholds,
retention precedence, inclusive installed-page STOP rates and threshold,
resolved diagnostic capacity and projection formula, sampling configuration,
and workload command. Its cap and startup-boundary contract is explicit:

```text
cycle_window_timeout_decisions=capped_policy_evaluation
cycle_window_timeout_action=evaluate_then_advance
cycle_window_alignment=first_cycle_warmup_unless_capped_window_establishes_boundary
```

Plotting is performed after the measured run from the CSV rather than inside
the timed workload.

## Interpretation Limits

- The P75 and CDF are weighted-KLL estimates with millisecond source values;
  ties and approximation error remain visible in the reported strict and
  inclusive CDFs.
- The START CDF gap is a relative latency-distribution signal. Without RSS or
  capacity it does not estimate the number of hot remote pages or prove that
  they fit locally.
- The retained RSS projection assumes sampled protection opportunities
  represent the process tree's current resident pages, but it is diagnostic
  only.
- The STOP rates describe inclusive-CDF-weighted matching faults per eligible
  installed page in one decision window. They are window activity ratios, not
  estimates of resident working-set capacity. A 20-second capped window may
  have incomplete or spatially uneven scan coverage even though every term in
  the ratio comes from the same snapshot.
- The production contract requires THP mode and defragmentation mode `never`
  because the kernel controller-probe ABI samples order-0 folios only.
- The recorded 75% capacity target is not a decision boundary in this policy.
- The 100,000 ppm START threshold is a diagnostic microbenchmark candidate and
  must not be interpreted as a calibrated general-workload threshold.
- The runs in `fine_tuning/runs/20260713T170648Z-*` and
  `20260713T171356Z-*` used the superseded `STOP_RAW = not START_RAW`
  implementation. They do not validate the independent STOP contract above.
