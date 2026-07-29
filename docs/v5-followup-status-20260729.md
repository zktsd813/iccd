# ICCD v5 Follow-up Branch Status

Date: 2026-07-29

## Purpose

This branch preserves post-submission development separately from the v3
submission on `main`. Its base is:

```text
0d9635b3e Add final submission summaries
```

The v3 paper results and their selected summaries remain authoritative on
`main`. This branch is a work-in-progress source snapshot, not a replacement
result package and not a claim that v3 results were produced by the v5 stack.

## Preserved Work

- `quantile_snapshot_v5` kernel sampling ABI and order-0 folio probe
  accounting;
- same-window protected, cancelled, dropped-fault, local-CDF, and remote-CDF
  reporting;
- the matching July 24 kernel source diff and successful build provenance;
- follow-up controller design, tests, VM plumbing, and experiment-runner
  changes;
- microbenchmark arena placement, fixed-work phase switching, weighted/disjoint
  hot-set presets, boundary residency probes, and MLP helpers;
- historical handoff and policy-analysis documents.

Large raw results, VM images, local worktrees, kernel build products, caches,
and machine-local helper files are deliberately not committed.

## Known Integration Boundary

The branch is intentionally marked WIP because the active files are not yet a
coherent v5 runtime:

- `design/fault_bucket_controller/DESIGN.md` and the controller tests describe
  a v5 same-window policy;
- `design/fault_bucket_controller/bucket_latency_controller.py` and
  `run_guest.sh` still contain the instrumented v3/v4 controller path;
- that runner requires `remote_quantile_rank_ppm`, while the v5 kernel removes
  that ABI;
- VM wrappers propagate v5 policy variables that the current shared runner
  does not consume.

Accordingly, do not launch a controller experiment from this branch until the
shared controller and runner are reconciled with the v5 ABI.

## Verification Snapshot

Completed checks:

```text
git diff --check                                      pass
shell syntax checks for active runners                pass
make -C Microbenchmark test                           pass
v5 kernel full build                                  pass
```

Kernel build provenance:

```text
release  6.18.0modified
build    #47 SMP PREEMPT_DYNAMIC Fri Jul 24 08:23:40 UTC 2026
bzImage  10,055,872 bytes
sha256   bd39c3fed3ac7633f95c186c9b99068a9ac444c323e99ddfd6aec418ddfc99c3
```

Expected failing check:

```text
python3 -m unittest -v test_bucket_latency_controller.py
```

The test module currently fails during import because the active controller
does not define the v5 `DEFAULT_START_CDF_GAP_PPM` interface.

## Experiment Rules

Future PR/BC runs must use generated graphs (`-g <scale>`), never serialized
`.sg`/`.wsg` inputs. Unless an experiment explicitly changes them, keep normal
NUMA scan size at 256 MiB, local fault scan size at 64 MiB, and local fault
scan period at 1000 ms.

## Next Integration Steps

1. Select one documented v5 START/STOP/arbitration contract.
2. Restore or reimplement that contract in the shared controller.
3. Update `run_guest.sh` to consume only the v5 ABI.
4. Align VM and host-native wrappers with the shared runner.
5. Make the v5 controller unit suite pass.
6. Perform ABI smoke validation before any full workload run.
