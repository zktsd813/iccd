# PR Hot-Page Selection Proof Plan

Date: 2026-07-11

## Question

The hypothesis is:

> PR performs poorly with continued memory tiering because Linux fails to
> place the pages with the greatest future access benefit in the local tier.

The completed aggregate traces do not prove this hypothesis. They show that
the initial refill makes real placement progress and that later migration
continues with little net local-residency gain. They do not retain page
identity or future access counts, so they cannot say whether the pages being
swapped are correct or incorrect.

## What Must Be Proven

A strong causal claim requires all three results below.

### 1. A Useful And Predictable Hot Set Exists

For a fixed future horizon, page access intensity must be sufficiently
concentrated that an oracle local set captures materially more accesses than a
random set of the same size. Past hotness must also predict future hotness.

Measure:

```text
past-top-K versus future-top-K Jaccard similarity
past versus future rank correlation
oracle-top-K access capture versus random-K access capture
hotness concentration or Gini coefficient
```

If the future distribution is flat or its top-K changes every window, Linux
cannot be blamed for failing to find a stable set that does not exist.

### 2. Linux Misses That Hot Set

At checkpoint `t`, let:

- `U` be all resident workload pages or measured regions.
- `K` be the number of pages actually resident in the local tier.
- `S_linux` be Linux's local-tier set at `t`.
- `A_p(H)` be page `p`'s independently measured accesses during future
  horizon `H`.
- `O_K(H)` be the `K` pages with the largest future `A_p(H)`.

Define:

```text
capture(S, H) = sum(A_p(H), p in S) / sum(A_p(H), p in U)

normalized regret =
    (capture(O_K, H) - capture(S_linux, H)) / capture(O_K, H)
```

Also measure precision/recall at K, remote missed-hot pages, local cold pages,
and whether promoted pages are hotter in the future than demoted or rejected
pages.

Low Linux capture, repeated local/remote rank inversions, and high oracle
regret support a selection failure. Placement volume or low net residency gain
alone does not.

### 3. The Misselection Causes Runtime Loss

Freeze automatic migration and compare equal-capacity placements:

```text
Linux-frozen placement
random-K placement
past-hot-K placement learned from an earlier interval or trial
offline future-oracle-K placement
```

The future oracle is an upper bound, not an online policy. The past-hot arm is
the realizable predictor. Both must use the same `K`, and placement success
must be verified with `move_pages()` before timing.

If past-hot or oracle placement captures more accesses but does not improve PR
runtime, incorrect ranking is not the demonstrated performance cause. High
memory-level parallelism or bandwidth saturation may hide the placement
difference.

## Why PR Is An Important Test

The approximately 71.29 GiB PR trial footprint contains:

| Region | Approximate size | Dominant access form |
| --- | ---: | --- |
| CSR neighbor IDs | 63.28 GiB | Every entry is streamed once per PR iteration. |
| CSR vertex index | 4.00 GiB | Sequential vertex-range lookup each iteration. |
| `outgoing_contrib` | 2.00 GiB | Indexed by every traversed edge, with degree-dependent reuse. |
| `scores` | 2.00 GiB | Sequential read/write each iteration. |

`outgoing_contrib` is a plausible stable high-intensity region because a
single page can be referenced by many edges. Most CSR neighbor pages,
however, belong to a broad streaming set that is revisited each iteration.

Linux NUMA tiering observes the time from PTE protection to the first later
access. It does not observe all subsequent accesses to that page during the
scan epoch. A stream that reaches a protected page soon after the scanner can
therefore look favorable even if a different page receives many more total
future accesses.

There is also a serious alternative hypothesis: PR may have only a small
high-intensity region plus a large, nearly uniform streaming set, leaving
little stable ordering among most pages. Continued migration would then chase
scan phase rather than reveal a general Linux ranking defect.

## Current Instrumentation Limits

The current kernel exports aggregate reuse-time histograms, KLL quantiles,
CDFs, vmstat counters, and resident capacity. It does not retain a stable page
identity in those outputs.

- Local `page_ext` stores only the sampling-window sequence.
- The folio state stores a timestamp used to calculate scan-to-refault time.
- Migration can clear the local sampling state and account the probe as lost.
- `migrate:set_migration_pte` records VA, encoded source PTE, and order.
- `migrate:remove_migration_pte` records VA, destination PTE, and order.
- Aggregate migration events record counts and reason but not page decisions.

The existing migration events omit target process/MM identity, source and
destination node, the reuse threshold, accept/reject decision, and rejection
reason. They cannot be joined unambiguously to a future per-page oracle under
concurrent migration and demotion.

## Independent Future-Access Oracle

### Preferred: Host-Native PEBS

The current host is an Intel Xeon with PEBS support. The local perf build
exposes precise load and store events, and the host kernel supports the
required perf infrastructure. Host-native precise data-address sampling is
therefore the strongest available oracle.

Record future virtual addresses in the same clock domain as the migration
trace. Use an all-retired-load profile for reference frequency:

```bash
sudo linux-perf-min-build/perf record -d -T --phys-data --sample-cpu \
  -e cpu/mem_inst_retired.all_loads/pp \
  -e migrate:set_migration_pte \
  -e migrate:remove_migration_pte \
  -e migrate:mm_migrate_pages \
  -- <workload command>
```

Event syntax must be smoke-tested on the installed PMU before the full run.
Use `perf script` to aggregate sampled data addresses by stable virtual page
or region. Run a separate `cpu/mem-loads,ldlat=30/Pu` profile as a
memory-relevant sensitivity: it intentionally excludes short-latency loads
and answers a different question from total reference frequency. Separate
profiles avoid PMU multiplexing when possible.

Use 2 MiB regions as the primary ranking unit because a 71 GiB working set can
make 4 KiB PEBS coverage sparse. Report 64 KiB and 4 KiB sensitivities and use
bootstrap confidence intervals across samples and repeated runs.

### VM Limitation

Historical guest logs expose PEBS format 0. Format 0 lacks the data-address
field needed for page ranking; the field appears in later PEBS formats. QEMU
uses a host CPU model, but guest precise data-address capture has not been
validated and should not be assumed.

A fresh guest must pass a small `perf record -d --phys-data` test before VM
PEBS can be used. Otherwise use the page-idle fallback below or perform the
proof host-native and separately validate the controller behavior in the VM.

### VM Fallback: Idle-Page Epochs

The installed kernel has:

```text
CONFIG_IDLE_PAGE_TRACKING=y
CONFIG_PROC_PAGE_MONITOR=y
# CONFIG_DAMON is not set
```

For a deterministic, stratified cohort of virtual pages:

1. Read `/proc/<pid>/pagemap` to translate VA to PFN.
2. Query the current NUMA node with `move_pages(..., nodes=NULL, ...)`.
3. Mark the PFN idle through `/sys/kernel/mm/page_idle/bitmap`.
4. Wait 100-500 ms, then read the idle bit.
5. Retranslate and re-arm each epoch; count accessed epochs per stable VA.

Freeze migration during the future measurement horizon so VA-to-PFN changes
do not invalidate the oracle. The observer is still intrusive because it
clears Accessed bits, so report a tracker-overhead control.

This fallback measures whether a page was touched in an epoch, not the number
of accesses. It is useful for coverage and reuse cadence but weaker than PEBS
for distinguishing a one-touch stream from a repeatedly accessed page.

## Minimal Attribution Tracepoint

Add a debug-only tracepoint at the NUMA tiering decision and a second event
around the migration attempt. Required fields are:

```text
pid, tgid, mm_cookie, virtual address, source PFN, folio order
source node, destination node
reuse latency, current hot threshold
accept/reject, decision reason
migration prepare result, migration result
```

Suggested hooks are:

```text
linux/kernel/sched/fair.c
    should_numa_migrate_memory()

linux/mm/mempolicy.c
    mpol_misplaced()

linux/mm/memory.c
    migrate_misplaced_folio_prepare()
    migrate_misplaced_folio()

linux/mm/huge_memory.c
    corresponding THP migration path

linux/include/trace/events/sched.h
    tracepoint definition
```

The trace must distinguish:

1. **Coverage failure:** a future-hot remote page never generates a hint
   fault.
2. **Classification failure:** it faults but the classifier rejects it.
3. **Action failure:** it is selected but migration fails.
4. **Retention failure:** it is promoted and quickly demoted.

Without this separation, poor local contents cannot specifically be assigned
to the Linux hot-page classifier.

## Experiment Matrix

Use generated GAPBS graphs only.

| Workload/configuration | Purpose | Placement arms |
| --- | --- | --- |
| PR g29, local16 | Primary failure case | Linux-frozen, random-K, past-hot-K, future-oracle-K |
| PR g29, local32 | Capacity confirmation | Linux-frozen, past-hot-K, future-oracle-K |
| BC g29, local16 | Same builder and repeated-trial control | Linux-frozen, random-K, past-hot-K |
| GUPS 64 GiB, local16 | Uniform-random negative control | Linux-frozen, random-K, past-hot-K |

Use at least three repetitions, preferably five. Use future horizons of 10,
20, and approximately 40 seconds. Exclude graph setup from the trial-level
comparison, but do not feed workload identity or phase labels into the
controller.

For the realizable causal arm, learn hotness from trial `n`, move the same
stable graph-relative regions before trial `n+1`, disable migration and
demotion, verify the placement, and time trial `n+1`. Generated graph creation
is deterministic, but allocation bases must be normalized to VMA or
allocation-relative offsets. Scratch arrays that are destroyed at a trial
boundary must be handled separately from the persistent graph.

## Decision Table

| Observation | Conclusion |
| --- | --- |
| Stable oracle hot set, high Linux regret, and faster oracle/past-hot placement | Strong support for Linux hot-page misselection causing PR loss. |
| Oracle, Linux, and random sets have similar capture and runtime | Reject stable-hot-set misselection; broad streaming or moving hotness dominates. |
| Linux placement is close to oracle, but migration ON is slower | Selection is adequate; hint faults, copies, demotion, or churn cause the loss. |
| Oracle improves capture but not runtime | Ranking differs, but high MLP/bandwidth prevents a demonstrated runtime benefit. |
| Future-hot pages fault but are rejected | Classification failure. |
| Future-hot pages never fault | Sampling coverage failure. |
| Correct pages are selected but migration fails or they are quickly demoted | Action or retention failure, not ranking failure. |

## Recommended First Test

Start with one PR g29 local16 host-native diagnostic:

1. Run normal tiering until the first refill has settled.
2. Pause PR and snapshot every resident VA's node with `move_pages()`.
3. Resume PR and collect 20 seconds of PEBS future data addresses.
4. Compare Linux local-set capture with random-K and offline oracle-K at 2 MiB
   granularity.
5. Break results down by large anonymous VMA/offset to determine whether the
   repeatedly accessed `outgoing_contrib` region is already local or remains
   remote.

This observation does not yet prove causality, but it quickly determines
whether there is enough Linux-versus-oracle regret to justify the placement
A/B experiment and kernel attribution tracepoint.
