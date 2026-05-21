# PR g28 local8: migration off vs ours

Run ID: `20260510T085906Z-prg28-i20n3-local8-off-ours`

Artifacts:
`/Serverless/iccd/experiments/20260510-pr-g28-local8-off-ours/qemu-logs/pr_g28_local8_off_ours/20260510T085906Z-prg28-i20n3-local8-off-ours`

## Setup

| item | value |
| --- | --- |
| workload | GAPBS PageRank |
| command | `/root/mbench -g28 -i20 -t1e-4 -n3` |
| graph | 268435455 nodes, 4236159892 undirected edges, degree 15 |
| kernel | `Linux kernel 6.18.0modified #172 SMP PREEMPT_DYNAMIC Sun May 10 07:45:36 UTC 2026` |
| kernel image | `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage` |
| initrd | `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-lf-hit2000-20260510.img` |
| KVM | yes, `-accel kvm` |
| VM topology | 32 vCPUs, 96G memory |
| guest node0 | 32G, CPUs 0-31, host node0 |
| guest node1 | 64G, host node2 |
| host NUMA policy | bind, prealloc on |
| cgroup local capacity | 2097152 pages, 8 GiB |
| MGLRU | `0x0007` |
| scan | 256MB, 1000ms min period, fast scan off |
| global numa balancing | 0 |
| earlystop / pingpong stat | 0 / 0 |

Note: an earlier full command path was observed running as `-i1000 -n20`.
That run was stopped before completion because one policy would take too long
under the 8G local cap. The valid result below is the corrected `-i20 -n3`
run.

## Policy settings

| policy | node_balancing | demotion | local fault sampling |
| --- | ---: | ---: | ---: |
| off | 0 | on | 0 |
| ours | 2, then controller turns off | on | 10 |

Ours controller condition: 10s windows, utilization >= 80%, 3 consecutive
windows, minimum 1000 sampled PTE updates.

Ours turned migration off at elapsed 170701 ms in window 17:
`util_pct=96.37`, `pte_delta=56293`, `hit_delta=54252`, `consecutive=3`.
The three triggering windows were 97.74%, 95.65%, and 96.37%.

## Runtime result

| policy | generate_s | build_s | trial_avg_s | trial_times_s | elapsed_s |
| --- | ---: | ---: | ---: | --- | ---: |
| off | 60.75393 | 123.28196 | 19.12841 | 19.26414, 19.06122, 19.05987 | 273 |
| ours | 65.95028 | 158.45001 | 19.24772 | 19.39538, 19.17437, 19.17341 | 315 |

Ratios:

| metric | ours / off |
| --- | ---: |
| PageRank trial average time | 1.006x |
| total elapsed time | 1.154x |
| generate time | 1.086x |
| build time | 1.285x |

Interpretation: for the measured PageRank trials, ours is nearly identical to
off, about 0.62% slower. The larger end-to-end elapsed gap comes mostly from
generation/build time while migration and local sampling were still active.

## Migration counters

| policy | hint_faults | pte_updates | promoted_pages | promoted_GiB | demoted_direct_pages | demoted_direct_GiB | demoted_kswapd_pages |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| off | 0 | 0 | 0 | 0.00 | 11374243 | 43.39 | 0 |
| ours | 14857778 | 22113223 | 2474062 | 9.44 | 13477670 | 51.41 | 0 |

Additional ours local-fault sampling counters:

| metric | value |
| --- | ---: |
| local fault sampled/PTE updates | 746898 |
| local fault refault | 597846 |
| local fault refault hit | 318213 |
| local fault lost | 149052 |
| PFN candidates | 8467385 |
| PFN selected | 746898 |
| selected / candidates | 8.82% |
| hit / sampled PTE updates | 42.60% |
| hit / refault | 53.23% |

`numa_local_fault_on_tiering` is a policy knob, not an event counter; the final
cgroup diff shows `-10` only because the controller changed the knob from 10 to
0 after the trigger.

## Files

| file | path |
| --- | --- |
| off stdout | `guest-artifacts/20260510T085906Z-prg28-i20n3-local8-off-ours/off/stdout.log` |
| ours stdout | `guest-artifacts/20260510T085906Z-prg28-i20n3-local8-off-ours/ours/stdout.log` |
| ours controller | `guest-artifacts/20260510T085906Z-prg28-i20n3-local8-off-ours/ours/controller.csv` |
| off samples | `guest-artifacts/20260510T085906Z-prg28-i20n3-local8-off-ours/off/samples.csv` |
| ours samples | `guest-artifacts/20260510T085906Z-prg28-i20n3-local8-off-ours/ours/samples.csv` |
