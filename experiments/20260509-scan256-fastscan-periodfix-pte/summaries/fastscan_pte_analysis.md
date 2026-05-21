# scan256 fast-scan PTE update diagnostic

Date: 2026-05-09

Kernel: `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`,
`Linux 6.18.0modified #160`.

Initrd:
`/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-fastscan-periodfix-20260509.img`

Patch under test:

- In `task_numa_work()`, if `task_numa_fast_scan(p)` is true, force
  `p->numa_scan_period = task_scan_min(p)` before setting `mm->numa_next_scan`.
- The guest runner now records memcg-scoped `numa_pte_updates` in cgroup
  snapshots and live CSV as `cg_numa_pte_updates`.

## Runs

Experiment root:
`/Serverless/iccd/experiments/20260509-scan256-fastscan-periodfix-pte/`

Both runs:

- workload: `skew_lf_hotremote_4g_move_60s_remoteonly_mulshift_persistent`
- scan size: 256 MiB
- duration: 120 s
- MGLRU: `0x0007`
- topology: 32 vCPU, guest node0 32G on host node0, guest node1 64G on host node2
- cgroup fast-tier cap: 16G

| case | scan period min | fast scan |
| --- | ---: | ---: |
| `20260509TSCAN256-p1000-fastoff-periodfix-on5s` | 1000 ms | 0 |
| `20260509TSCAN256-p250-faston-periodfix-on5s` | 250 ms | 1 |

## Strict live 0-120 s-ish deltas

Live deltas are from sample 0 to the last live sample at about 120 s, avoiding
post-workload cleanup samples.

| case | live end | cg hint | cg PTE updates | cg PTE GiB | promote | candidate |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1000ms no-fast | 120.941 s | 6 | 7,423,470 | 28.32 | 6 | 6 |
| 250ms fast-on | 120.631 s | 5,079,822 | 5,246,432 | 20.01 | 2,194,032 | 2,194,032 |

At full-run snapshot granularity, post-120s cleanup adds more activity in the
1000ms run, so live-window deltas are the cleaner measurement for this question.

## Fine-grained PTE update shape

5s live-sample deltas show the intended fast-scan behavior as bursts, not as a
larger 120s total.

| time | 1000ms no-fast PTE GiB | 250ms fast-on PTE GiB | 250ms fast-on hint | 250ms fast-on promote |
| ---: | ---: | ---: | ---: | ---: |
| 0-5s | 1.25 | 6.90 | 2,051,393 | 709,310 |
| 5-10s | 1.00 | 4.31 | 417,456 | 346,883 |
| 10-75s | about 1.0-1.25 per 5s | ~0 | ~0 | ~0 |
| 75-80s | 1.25 | 2.92 | 1,438,972 | 360,289 |
| 80-85s | 1.25 | 5.57 | 1,171,989 | 777,544 |
| 85-90s | 1.25 | 0.30 | 0 | 0 |
| 90-120s | about 1.0-1.25 per 5s | ~0 | ~0 | ~0 |

## Interpretation

The previous experiment was suspicious for the reason raised by the user: if
fast scan is really active, PTE update timing should differ substantially.

The issue was not only dirty prefault baselines. The fast-scan knob was set, but
worker threads could retain the initial 1000 ms `p->numa_scan_period`; the
winning scanner then set the shared `mm->numa_next_scan` at that stale cadence.
That made 250ms fast-on look too similar to 1000ms no-fast in PTE update rate.

After forcing fast-scan tasks to use `task_scan_min()` in `task_numa_work()`,
the difference appears in fine-grained timing:

- no-fast keeps producing roughly one 256 MiB scan per second.
- fast-on consumes/protects the relevant ranges quickly, then has little new
  present non-NUMA PTE left to update until the next active window.

Therefore the right comparison is not just total PTE updates over 120 s. The
diagnostic signal is the burst timing and the matching hint/promote burst.

