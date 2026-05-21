# BC g28 local8 fixed-source: off vs on vs ours

Run ID: `20260510T093630Z-bcg28-i1n10-r11861354-local8-off-on-ours`

Artifacts:
`/Serverless/iccd/experiments/20260510-bc-g28-local8-off-on-ours-fixedsrc/qemu-logs/bc_g28_local8_off_on_ours/20260510T093630Z-bcg28-i1n10-r11861354-local8-off-on-ours`

## Setup

| item | value |
| --- | --- |
| workload | GAPBS Betweenness Centrality |
| command | `/root/mbench -g28 -i1 -n10 -r11861354 -l` |
| fixed source | `11861354` |
| source selection | first random nonzero-degree source from discovery run |
| graph | 268435455 nodes, 4236159892 undirected edges, degree 15 |
| kernel | `Linux kernel 6.18.0modified #172 SMP PREEMPT_DYNAMIC Sun May 10 07:45:36 UTC 2026` |
| kernel image | `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage` |
| initrd | `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-lf-hit2000-20260510.img` |
| KVM | yes, `-accel kvm` |
| VM topology | 32 vCPUs, 96G memory |
| guest node0 | 32G, CPUs 0-31, host node0 |
| guest node1 | 64G, host node2 |
| cgroup local capacity | 2097152 pages, 8 GiB |
| MGLRU | `0x0007` |
| scan | 256MB, 1000ms min period, fast scan off |
| earlystop / pingpong stat | 0 / 0 |

I first tried `-r0`, but stopped that run because trial time was only about
1.23s, which indicated a non-representative BC source. The source used here was
found by running `-g28 -i1 -n1 -l` without `-r`; it logged
`Source: 11861354` and a single-trial time of 14.65s.

## Policy settings

| policy | node_balancing | demotion | local fault sampling |
| --- | ---: | ---: | ---: |
| off | 0 | on | 0 |
| on | 2 | on | 0 |
| ours | 2, then controller turns off | on | 10 |

Ours controller condition: 10s windows, utilization >= 80%, 3 consecutive
windows, minimum 1000 sampled PTE updates.

Ours turned migration off at elapsed 160621 ms, before trial start:

| item | value |
| --- | ---: |
| generate + build / trial start | 215.325s |
| controller off | 160.621s |
| off happened before trial by | 54.704s |
| triggering utilization windows | 96.28%, 98.19%, 94.11% |

## Runtime result

| policy | generate_s | build_s | trial_avg_s | elapsed_s | trial RSS avg GiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| off | 67.31845 | 125.00955 | 13.95519 | 364 | 39.41 |
| on | 60.41712 | 272.58445 | 36.33318 | 735 | 39.05 |
| ours | 62.30007 | 153.02444 | 14.06218 | 389 | 40.34 |

Ratios:

| metric | ratio |
| --- | ---: |
| on / off trial time | 2.604x |
| ours / off trial time | 1.008x |
| on / ours trial time | 2.584x |
| on / off elapsed | 2.019x |
| ours / off elapsed | 1.069x |

Trial times:

| policy | trial times |
| --- | --- |
| off | 14.04381, 13.95800, 13.93122, 13.93588, 13.94973, 13.94490, 13.94399, 13.93689, 13.96203, 13.94546 |
| on | 14.14599, 14.70205, 35.59861, 42.34098, 31.16058, 23.73806, 39.69161, 48.96237, 56.79349, 56.19806 |
| ours | 14.27565, 14.05081, 14.04957, 14.07613, 14.04131, 14.03193, 14.02118, 14.01628, 14.01694, 14.04198 |

## Migration counters

| policy | hint_faults | PTE updates | promoted pages | promoted GiB | demoted direct pages | demoted direct GiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| off | 0 | 0 | 0 | 0.00 | 11414908 | 43.54 |
| on | 77476606 | 87049009 | 17074398 | 65.13 | 29404584 | 112.17 |
| ours | 13532148 | 20663333 | 2173861 | 8.29 | 13097864 | 49.96 |

Additional ours local-fault sampling counters:

| metric | value |
| --- | ---: |
| local fault sampled/PTE updates | 701110 |
| local fault refault | 554818 |
| local fault refault hit | 283733 |
| local fault lost | 146292 |
| PFN candidates | 8108026 |
| PFN selected | 701110 |
| selected / candidates | 8.65% |
| hit / sampled PTE updates | 40.47% |
| hit / refault | 51.14% |

## Notes

All three policies completed with return code 0 and empty stderr. The key
behavior is that plain `on` keeps migration active into the BC trial phase and
the trial time degrades after the first two trials. `ours` detects high local
reuse during graph build, disables migration before the measured trial phase,
and its 10 fixed-source trial times remain close to `off`.
