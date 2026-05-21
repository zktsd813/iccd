# Scan256 Window2 Promotion Gap Analysis

Question: why did `250ms + fast_scan=on + scan_size=256MB` stop promoting the
second 4GiB moving window?

## Runs

| case | run_id | scan_size_mb | period_min_ms | fast_scan | hot_threshold_ms |
| --- | --- | ---: | ---: | ---: | ---: |
| default threshold | `20260509TSCAN256-p250-faston-on5s` | 256 | 250 | 1 | 0, Linux default 1000ms |
| diagnostic | `20260509TSCAN256-p250-faston-hot120s3-on5s` | 256 | 250 | 1 | 120000 |

Both used kernel `6.18.0modified #159`, MGLRU `0x0007`, the same VM topology,
and candidate `skew_lf_hotremote_4g_move_60s_remoteonly_mulshift_persistent`.
The valid diagnostic run used initrd
`/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-fastscan-20260509.img`.

## Key Counter Split

Default 1000ms hot threshold, window2:

| interval_s | hint | local_hint | candidate | promote | demote | fail/over_high/block/alloc |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 75.443-80.478 | 1,048,576 | 0 | 0 | 0 | 0 | 0 |

Diagnostic 120s hot threshold, window2:

| interval_s | hint | local_hint | candidate | promote | demote | fail/over_high/block/alloc |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 75.397-80.454 | 406,801 | 37,010 | 368,435 | 369,794 | 31,489 | 0 |
| 80.454-85.483 | 746,640 | 67,850 | 680,146 | 678,787 | 799,413 | 8 pgmigrate_fail only |
| 85.483-90.507 | 190,958 | 17,360 | 173,598 | 173,598 | 160,256 | 2 pgmigrate_fail only |
| 90.507-95.532 | 128,372 | 11,670 | 116,702 | 116,702 | 247,104 | 4 pgmigrate_fail only |

Throughput:

| case | 60-70s | 70-80s | 80-90s | 90-100s |
| --- | ---: | ---: | ---: | ---: |
| default threshold | 226.1 Mops/s | 228.4 Mops/s | 228.3 Mops/s | 228.3 Mops/s |
| diagnostic 120s | 896.4 Mops/s | 1794.4 Mops/s | 1791.6 Mops/s | 1791.8 Mops/s |

## Interpretation

The original scan256 result was not a failed promotion attempt. It was a
pre-candidate rejection:

- `numa_hint_faults` rose by exactly one 4GiB window in window2.
- `pgpromote_candidate`, `pgpromote_success`, `pgmigrate_fail`, and the memcg
  promotion failure counters all stayed flat.
- Raising only the hot threshold made those same window2 accesses become
  promotion candidates and then successful promotions.

The kernel path matches this:

- `do_numa_page()` calls `numa_migrate_check()`.
- `numa_migrate_check()` counts hint faults before calling `mpol_misplaced()`.
- `mpol_misplaced()` calls `should_numa_migrate_memory()` for tiering.
- In `should_numa_migrate_memory()`, `PGPROMOTE_CANDIDATE` is incremented only
  inside `numa_promotion_rate_limit()`, after the latency check.
- Therefore `hint_faults > 0` with `pgpromote_candidate == 0` means the access
  returned `NUMA_NO_NODE` before the rate-limit/migration path. Given migration
  stop was off and the mbench placement does not leave an `MPOL_BIND` VMA policy
  behind, the observed branch is the hotness latency check.

The diagnostic also has an important caveat: with `HOT_THRESHOLD_MS=120000`,
the prefault/measurement gate already allowed substantial pre-measurement
promotion/demotion. Use it as a branch-confirmation diagnostic, not as an
apples-to-apples performance run.

## Conclusion

The weird part is not allocation, over-high, or rate limit. With scan size
256MB and default 1000ms hot threshold, the second-window NUMA hint faults are
classified as not hot enough and never become promotion candidates. Increasing
the threshold confirms the second window can promote under the same scan
cadence once that latency gate is removed.
