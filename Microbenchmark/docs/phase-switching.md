# Phase-Switching Experiment

This experiment tests whether migration remains beneficial inside one
execution after the access pattern or hotset changes. The run should keep one
process, one arena, and one cgroup lifetime while changing only the workload
phase. That exposes policies that look good for a stable hotset but leave pages
in the wrong tier after locality moves.

## Built-In Preset

The built-in `friendly-unfriendly` phase preset alternates between two access
shapes:

- `friendly-bw-reuse`: stable bandwidth reads over a fixed window that should
  give migration enough time to identify hot pages and improve throughput.
- `unfriendly-stream`: a larger streaming `triad` window that sweeps across
  the arena, making stale placement and excess migration visible.

Interpret the preset by phase, not only by whole-run average. A useful policy
should show a throughput gain during the friendly phase, limited disruption at
the phase boundary, and no large sustained loss during the unfriendly phase. If
migration counters rise while unfriendly-phase throughput stays flat or drops,
the policy is probably chasing stale hotness. If the next friendly interval
recovers quickly, the policy is adapting to the new hotset; slow recovery means
old residency is still influencing placement.

### Unfriendly-to-friendly fixed-work preset

The `sparse64-mulshift4g` preset keeps a 64 GiB arena and reverses the existing
`mulshift4g-sparse64` pair:

1. `sparse-stride-read-64g` reads one cache line per 4 KiB page across the full
   64 GiB arena. Its active set is larger than a 32 GiB local-memory tier, so
   repeatedly migrating the stream is expected to be unfriendly.
2. `mulshift-hotset-4g-fixed` performs read-only mulshift-indexed accesses in a
   fixed 4 GiB window at offset 60 GiB. Its active set fits well below the
   32 GiB local-memory tier and is expected to benefit from promotion.

Use `--phase1-target-ops` and `--phase2-target-ops` when policies must execute
identical work rather than run for identical durations. Both values must be
zero (duration mode) or both must be nonzero (fixed-work mode). With
`--phase-repeat N`, the same phase-1 and phase-2 targets are reused for every
pair. Global operation counters remain cumulative; each phase terminates when
the counter increase since that phase started reaches its target. The
`phase_complete` record reports the achieved delta, which can exceed the target
slightly because worker threads publish operations in batches.

After calibrating each phase independently to a 200--300 second solo runtime, a
fixed-work run has this shape:

```bash
Microbenchmark/mbench --phase-preset sparse64-mulshift4g \
  --arena-size 64G --window-size 64G --threads 32 \
  --phase1-target-ops "$SPARSE_TARGET_OPS" \
  --phase2-target-ops "$MULSHIFT_TARGET_OPS" \
  --sample-ms 1000 --csv
```

The preset requires an arena of at least 64 GiB. Placement and local-memory
capacity are experiment-runner concerns; keep them fixed across policies.

### Weighted remote-hot friendly phase

The `sparse64-weighted8g` preset is the explicit 64 GiB RSS, 32-thread
unfriendly-to-friendly sequence used with a 32 GiB local-memory tier:

1. `sparse-stride-read-64g` gives each worker a private 2 GiB slice of the
   64 GiB window and reads one 8-byte element per 4 KiB page. The aggregate
   active set is 64 GiB, larger than local memory.
2. `friendly-weighted-tail8g-off20g` gives all workers the same fixed 8 GiB window at
   offset 20 GiB. The final 4 GiB is the hotset and receives 90 percent of
   read-only accesses; the leading 4 GiB is background and receives 10 percent.
   Workers use independent xorshift sequences, so they share the global
   hot/background boundary without issuing identical address streams.

Use normal arena placement with the first 24 GiB on local node 0 and the final
40 GiB on remote node 1:

```text
arena:       [ 0 GiB ........ 24 GiB | 24 GiB ............... 64 GiB )
residency:   [          local          |              remote             )
phase 2:                     [ background | hotset )
window:                      [ 20--24 GiB | 24--28 GiB )
access share:                    10%           90%
```

The initial 24 GiB local residency leaves 8 GiB of capacity headroom for
promotion. The 4 GiB hotset is below the 32 GiB local capacity, while the full
phase-2 active set remains 8 GiB. Run the preset with:

```bash
Microbenchmark/mbench --phase-preset sparse64-weighted8g \
  --arena-size 64G --window-size 64G --threads 32 \
  --placement arena-split:0,1 --arena-split-local 24G \
  --ops-per-pass 65536 \
  --phase1-target-ops "$SPARSE_TARGET_OPS" \
  --phase2-target-ops "$WEIGHTED_TARGET_OPS" \
  --sample-ms 1000 --csv
```

With 32 workers and `--ops-per-pass 65536`, phase 1 publishes 524,288
operations per worker after each complete 2 GiB sparse traversal, for an
aggregate accounting wave of 16,777,216 operations. Phase 2 publishes 65,536
operations per worker, for a 2,097,152-operation wave. Fixed-work targets are
therefore comparable across policies, and any target overshoot can be bounded
from these logged batch dimensions.

### Disjoint local-background and far-remote hotset

The `sparse60-disjoint8g` preset keeps the 64 GiB allocation but separates the
friendly phase's two active regions:

1. `sparse-stride-read-60g` reads one element per 4 KiB page over `[0,60)` GiB.
   This 60 GiB active set is larger than the 32 GiB local tier, while the future
   remote hotset at `[60,64)` GiB receives no phase-1 workload accesses.
2. `friendly-disjoint8g-bg20-hot60` uses a shared logical span of `[20,64)` GiB.
   The background-page limit makes 10 percent of accesses uniform within the
   first 4 GiB, `[20,24)` GiB. Tail-hotset selection makes 90 percent uniform
   within the final 4 GiB, `[60,64)` GiB. The intervening `[24,60)` GiB gap is
   never selected, so the active set is 8 GiB rather than the 44 GiB span.

With `arena-split:0,1` and a 24 GiB split, the background begins local and the
far hotset begins remote:

```text
arena:       [ 0 ........ 24 | 24 ........................ 60 | 60 .... 64 ) GiB
residency:   [     local     |               remote          |  remote   )
phase 1:     [====================== sparse ==================) untouched
phase 2:                 [ bg ]           skipped              [  hot  ]
access share:             10%                                     90%
```

Run this preset with:

```bash
Microbenchmark/mbench --phase-preset sparse60-disjoint8g \
  --arena-size 64G --window-size 64G --threads 32 \
  --placement arena-split:0,1 --arena-split-local 24G \
  --ops-per-pass 65536 \
  --phase1-target-ops "$SPARSE_TARGET_OPS" \
  --phase2-target-ops "$DISJOINT_TARGET_OPS" \
  --sample-ms 1000 --csv
```

Each phase-1 worker traverses a private 1.875 GiB slice and publishes 491,520
operations per traversal, yielding a 15,728,640-operation aggregate wave.
Phase 2 retains the 65,536-operation worker batch and 2,097,152-operation
aggregate wave. The phase-start record logs `hotset_background_pages=1048576`
alongside the hotset, window, and thread geometry.

### Full-local-background disjoint preset

The `sparse60-disjoint28g` preset preserves the same 60 GiB sparse phase and
far-remote 4 GiB hotset, but uses the complete initially local 24 GiB prefix as
the friendly phase's background:

1. `sparse-stride-read-60g` accesses `[0,60)` GiB and leaves `[60,64)` GiB
   untouched by phase-1 workload accesses.
2. `friendly-disjoint28g-bg0-hot60` uses a shared full-arena span. Its
   6,291,456 background pages cover `[0,24)` GiB and receive 10 percent of
   read-only xorshift accesses. Its 1,048,576 tail-hotset pages cover
   `[60,64)` GiB and receive 90 percent. `[24,60)` GiB remains unselected.

The resulting active set is 28 GiB, below the 32 GiB local capacity. With the
same 24/40 GiB initial arena split, all background pages begin local and all hot
pages begin remote. This distinguishes policy response to a fully occupied
local background from the smaller 4 GiB background in `sparse60-disjoint8g`.

```bash
Microbenchmark/mbench --phase-preset sparse60-disjoint28g \
  --arena-size 64G --window-size 64G --threads 32 \
  --placement arena-split:0,1 --arena-split-local 24G \
  --ops-per-pass 65536 \
  --phase1-target-ops "$SPARSE_TARGET_OPS" \
  --phase2-target-ops "$DISJOINT28_TARGET_OPS" \
  --phase-boundary-probe local_background:0:24G \
  --phase-boundary-probe remote_hotset:60G:4G \
  --sample-ms 1000 --csv
```

Accounting geometry is unchanged from `sparse60-disjoint8g`: phase 1 uses a
491,520-operation worker batch and 15,728,640-operation aggregate wave, while
phase 2 uses a 65,536-operation worker batch and 2,097,152-operation aggregate
wave when `--ops-per-pass 65536` is supplied.

## Smoke Command

Use a small arena first so the phase path, sample labels, and counter capture
can be checked quickly:

```bash
make -C Microbenchmark
Microbenchmark/mbench --phase-preset friendly-unfriendly \
  --arena-size 256M --window-size 64M --threads 2 \
  --phase-ms 3000 --sample-ms 250 --csv
```

This smoke run is for plumbing only. It should produce samples tagged with
`phase_elapsed_ms`, `phase_id`, and `phase_name`, and show at least one
friendly-to-unfriendly switch. Phase-preset runs use the configured phase
durations directly, so this smoke path does not wait for the legacy single-mode
fixed warmup and measured window.

To smoke-test fixed-work termination without allocating 64 GiB, use an existing
size-relative preset:

```bash
Microbenchmark/mbench --phase-preset friendly-unfriendly \
  --arena-size 256M --window-size 64M --threads 2 \
  --phase1-target-ops 100000 --phase2-target-ops 100000 \
  --sample-ms 250 --csv
```

## Main Experiment Preparation

- Keep arena size, window size, thread count, placement, and phase timing fixed
  across migration-policy comparisons.
- Run at least a no-migration baseline and the target migration policy in the
  same cgroup/memory-cap configuration.
- Choose phase lengths long enough for the friendly phase to reach steady
  throughput, then keep `--sample-ms` short enough to observe the switch and
  recovery window.
- Save raw CSV/stdout together with kernel and cgroup counters so phase samples
  can be aligned with residency and migration events.

## Metrics

- Phase throughput: steady throughput for each phase, excluding the immediate
  switch transient when reporting steady state.
- Recovery after switch: time from a phase boundary until throughput returns
  near that phase's steady value.
- Migration counters: deltas in counters such as successful/failed migrations,
  NUMA migrations, and policy-specific migration events per phase.
- Stale migration and residency risk: pages left in the previously preferred
  tier, rising migrations without throughput gain, or slow residency movement
  after the hotset changes.
