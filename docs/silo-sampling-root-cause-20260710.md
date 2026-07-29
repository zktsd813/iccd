# Silo Sampling Root Cause - 2026-07-10

## Conclusion

Local and remote samples do not disappear during Silo's transaction main
phase. The earlier analysis incorrectly classified worker preparation as main.

- Incorrect main interval in the earlier notes: about 186-451 seconds after
  workload start
- Transaction main identified by perf: about 471.7-736.8 seconds
- Low-sample interval at about 186-470 seconds: serial Zipf worker setup
- Controller windows W31-W53 overlapping transaction main: 23 of 23 valid

The sampler and NUMA fault path therefore remain active during transaction
main. The billions of loads and stores reported by perf in the low-sample
interval are primarily instructions from Zipf setup, not hot database
transactions.

## Source-Level Cause

The Silo binary used by the experiments executes the following sequence:

1. `/Serverless/benchmark/silo/benchmarks/bench.cc:244` prints
   `starting benchmark...`.
2. `bench.cc:249` then calls `make_workers()`.
3. The loop at `/Serverless/benchmark/silo/benchmarks/ycsb.cc:427` constructs
   all 32 workers serially on the main thread.
4. Every worker constructor calls `zipfian_rng.init(nkeys, ...)` at
   `ycsb.cc:54`.
5. `nkeys` is `scale_factor * 1000`, or 800,000,000 for this configuration.
6. `/Serverless/benchmark/silo/third-party/foedus/zipfian_random.hpp:37`
   executes an `n`-iteration `pow()` loop for every worker.
7. Only after all workers have been constructed do `bench.cc:251-257` start
   the threads and release the transaction barrier.

`starting benchmark...` is therefore not a transaction-start marker. This
configuration executes 25.6 billion zeta-loop iterations before transactions
begin.

## Timeline Evidence

Primary perf run:

`motivation/3_realworld/VM/results/20260710T-silo-local16-perf-access-check-v2`

| Stage | Time | Observation |
| --- | ---: | --- |
| Data loading | 0-186.142s | Builds a 118,632 MB database |
| Worker/Zipf setup | about 186-470.7s | About 4G cycles/s, effectively one core |
| Transaction main | about 470.7-735.8s | 78-107G cycles/s, 32 workers |
| Shutdown | about 735.8-751.4s | Worker activity falls |

The clearest perf transition is:

| Perf time | Cycles/s | Page faults/s |
| ---: | ---: | ---: |
| 469.655s | 3.98G | 0 |
| 470.659s | 7.63G | 516,298 |
| 471.662s | 77.88G | 8,504,041 |
| 472.666s | 77.74G | 5,701,449 |

The high-concurrency interval lasts about 265.1 seconds, matching Silo's
reported `runtime: 265.26 sec`.

An independent PTE-skip run shows the same transition:

`motivation/3_realworld/VM/results/20260710T-silo-local16-pte-skip-counters`

- W27 at 472.460s: 22 hint faults, 2 local, 20 remote
- W28 at 493.935s: 32,448,099 hint faults, 3,242,820 local,
  29,205,487 remote
- Large sample counts continue in every subsequent window until exit.

W28 is the first controller window overlapping transaction execution. This is
not evidence that a protected set happened to overlap a hot stream by chance.

## Main-Phase Samples

Re-aggregating W31-W53 from the perf run gives:

| Metric | Result |
| --- | ---: |
| Valid windows | 23 / 23 |
| Local samples per window | minimum 70,679; median 83,426 |
| Remote samples per window | minimum 1,616,495; median 2,189,192 |
| Total local samples | 6,913,640 |
| Total remote samples | 110,268,674 |
| Total NUMA hint faults | 136,890,360 |

By contrast, W13-W30, previously labeled as main, are all invalid. Those
windows precede worker startup, so the protected database PTEs are not being
accessed and are not expected to fault.

## Why the Earlier Interpretation Failed

The earlier analysis combined two facts incorrectly:

- `starting benchmark...` is printed immediately after data loading.
- Perf continues to count billions of loads and stores afterward.

The code running after that message is a single main thread performing
`zeta()/pow()` setup, not database transactions. Perf stat counts retired
instructions and cannot identify whether they access database objects.

Large `remote_scan_skip_protnone` counts are also expected during this stage.
Database pages protected during loading remain unreferenced and therefore
remain `PROT_NONE`. As soon as the worker threads start, hint faults and both
sample classes increase sharply.

## Controller Impact

The first stop in the perf run occurred at 205.567 seconds, about 266 seconds
before transaction main. It was based on a loading/setup tail sample, not on
transaction behavior.

The implemented corrections are:

- Remove `starting benchmark` from the controller's optional default
  main-phase patterns.
- Keep the first `time: ... throughput:` line as the safe Silo marker.
- Do not treat data-load completion as main in the offline replay tool.
- Prefer a timestamped controller marker only when its resolved pattern is
  known to be safe. Otherwise prefer a sustained perf-cycle concurrency
  transition and reject an explicitly unsafe marker.
- Normalize perf interval counts to cycles per second before applying the
  concurrency threshold.

The stdout/stderr gate remains opt-in. The default workload-independent
controller policy does not depend on application logs.

### Final Gate Validation

The corrected gate behavior was validated in a fresh VM with the Silo log gate
enabled and the original immediate selected-gap response:

`motivation/3_realworld/VM/results/20260711T-silo-local16-main-gate-verify`

The run used a 16 GiB local tier, a 192 GiB remote tier, 32 threads, normal
NUMA scan size 256 MB, and local scan size 64 MB at a 1-second period. It
completed the workload/controller case successfully in 724 seconds. Results
were copied before QEMU failed to exit within the 120-second graceful-stop
window; the runner then terminated it and deleted the overlay.

| Event | Elapsed | Controller result |
| --- | ---: | --- |
| Data load complete | 180.794s | `starting benchmark...` follows |
| Setup tail W12 | 199.261s | Valid 46,037 local / 2,646,157 remote, but `main_phase_wait`; remain on |
| Last setup window W26 | 455.454s | `main_phase_detected=0`; remain on |
| First throughput detected | 477.121s | Main gate opens |
| Decision W27 | 477.123s | Stop after 2,965,649 local / 27,493,277 remote samples |
| Controller exit | 722.805s | Final state off; no restart |

The first throughput line summarizes the preceding five seconds, placing
transaction start at about 472.121 seconds. The interval from that estimate to
controller exit is 250.684 seconds, within 0.374 seconds of Silo's reported
`runtime: 250.310 sec`.

Every main-detected window, W27-W39, was valid (13/13). Their aggregate counts
were:

| Metric | Result |
| --- | ---: |
| Local samples | 6,279,382 |
| Remote samples | 110,106,197 |
| NUMA hint faults | 127,137,333 |
| Local samples/window | minimum 67,042; median 316,011 |
| Remote samples/window | minimum 2,345,885; median 7,502,992 |

This run directly proves that the corrected pattern ignores the pre-worker
message, preserves migration through setup, and makes its first immediate
decision from a large transaction-phase sample.

After this VM run, a replay-only provenance change added JSON metadata for the
resolved pattern set. Replay now trusts a controller timestamp over perf only
when every resolved pattern is allowlisted as safe. This metadata change does
not alter live gate matching and is covered by unit tests rather than a second
full VM run.

### Rejected Global Workaround

We also tested requiring three consecutive capacity-infeasible windows for
every `selected-gap` workload.

Silo validation run:

`motivation/3_realworld/VM/results/20260710T-silo-local16-phasefix-consecutive3`

| Window | Elapsed | Experimental decision |
| ---: | ---: | --- |
| W13 | 205.300s | Candidate 1/3; remain on |
| W14 | 225.313s | Invalid; reset |
| W29 | 470.515s | Invalid; local 6 / remote 0 |
| W30 | 476.479s | Main overlap; local 657,836 / remote 3,490,997 |
| W31 | 482.904s | Candidate 1/3 |
| W32 | 489.476s | Candidate 2/3 |
| W33 | 511.488s | Stop at 3/3 |

This is an actual on-state run rather than an offline replay: migration stayed
enabled through W33. Across W30-W44 it collected 5,016,316 local and
91,698,985 remote samples. W31-W44 were valid in all 14 windows.

The GUPS48 comparison uses these runs:

- Immediate: `motivation/3_realworld/VM/results/20260710T-gups48-window-clamp-5-20-th09`
- Three-window confirmation: `motivation/3_realworld/VM/results/20260711T-gups48-consecutive3-verify-v2`

| Policy | First stop | Total elapsed |
| --- | ---: | ---: |
| Immediate selected-gap | 40.540s | 311s |
| Three consecutive windows | 95.475s | 363s |

The observed first-stop and elapsed differences are 54.935 and 52 seconds.
This is not a strict causal A/B: the runs used guest kernel builds #23 and #26,
and their post-stop observation settings also differed. In the new trace, W2
was invalid because its CDF query did not match the selected local P75. An
immediate policy on that same trace would stop at W3 (54.169s), while the
three-window policy waited through W5 (95.475s). The directly attributable
control-flow delay is therefore 41.306 seconds. Promotion/demotion traffic also
rose from 0.348/0.566 GiB to 1.593/1.637 GiB.

This evidence is sufficient to reject a global confirmation delay as the Silo
fix, but not to claim a paper-quality 52-second causal slowdown. The workaround
was removed from the final code. The Silo phase issue is handled by the opt-in
log gate and a correct marker, without changing selected-gap responsiveness for
other workloads.

## Remaining Policy Boundary

The sampling root cause is resolved, but a controller with no application
phase signal can still make a decision during setup. A truly
workload-independent policy needs a separate general setup/main discriminator.
The current evidence rules out:

- The sampler stopping during Silo transaction main
- Sustained main-phase memory activity accompanied by near-zero NUMA
  fault/sample counts
- PID-inactive VMA skipping as the primary cause of missing main samples
- A need for spatial bucket instrumentation to explain this observation

Phase-marker diagnostics and workload-independent policy evaluation should
remain separate experiments.
