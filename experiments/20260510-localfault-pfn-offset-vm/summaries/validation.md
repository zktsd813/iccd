# Local Fault PFN Offset Validation

Date: 2026-05-10

## Kernel Change

- Replaced event-counter local fault sampling with fixed PFN-residue sampling.
- For `numa_local_fault_on_tiering=10`, eligible order-0 local folios are selected by `folio_pfn(folio) % 10 == 0`.
- Removed `numa_local_fault_seq`; the local fault sample decision no longer advances with scan-event count.

## VM Run

- Run id: `20260510Tlocalfault-pfnoffset-stream32-on-90s`
- Kernel: `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`
- Initrd: `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-pfnoffset-20260510.img`
- Guest kernel: `Linux kernel 6.18.0modified #168 SMP PREEMPT_DYNAMIC Sun May 10 06:45:49 UTC 2026 x86_64`
- KVM: enabled
- VM: `CPUS=32`, `MEMORY=96G`, guest node0 `32G`, guest node1 `64G`
- Host binding: node0 memory to host node0, node1 memory to host node2, `NUMA_PREALLOC=1`
- MGLRU: `0x0007`

## Workload

- Candidate: `stream_read_32g_split16_4kstride`
- Policy: migration on
- Duration: `90000ms`
- Scan: `NUMA_SCAN_SIZE_MB=256`, `NUMA_SCAN_PERIOD_MIN_MS=1000`, `NUMA_FAST_SCAN=0`
- Local fault sampling: `NUMA_LOCAL_FAULT_ON_TIERING=10`
- Earlystop/pingpong stat: disabled

## Result

| metric | value |
| --- | ---: |
| steady mean throughput | 1884.40 MiB/s |
| steady median throughput | 1794.00 MiB/s |
| hint faults | 16,370,047 |
| PTE updates | 15,958,862 |
| promoted | 4,552,455 pages / 17.37 GiB |
| demoted | 4,261,894 pages / 16.26 GiB |
| local fault sampled | 1,842,008 pages / 7.03 GiB |
| local fault PTE updates | 1,842,008 |
| local fault refault | 1,798,049 |
| local fault refault hit | 1,621,794 |
| local fault lost | 43,959 |
| local fault refault rate | 97% |

Runtime `live.csv` confirms `cg_local_fault_on_tiering=10` during the run.
The final `summary.json` reports `numa_local_fault_on_tiering=0` because the
runner snapshots after policy cleanup resets the knob.

Artifacts:

- `/Serverless/iccd/experiments/20260510-localfault-pfn-offset-vm/qemu-logs/phase_candidate_microbench/20260510Tlocalfault-pfnoffset-stream32-on-90s/`

## PFN Ratio Diagnostic

After adding diagnostic counters, a second run measured the actual PFN predicate
selection ratio.

- Run id: `20260510Tlocalfault-pfnoffset-diag-stream32-on-60s`
- Guest kernel: `Linux kernel 6.18.0modified #170 SMP PREEMPT_DYNAMIC Sun May 10 06:58:17 UTC 2026 x86_64`
- Workload: `stream_read_32g_split16_4kstride`, migration on, `60000ms`
- Runtime knob: `numa_local_fault_on_tiering=10`
- Scan: `256MB`, `1000ms`, fast scan off

| metric | value |
| --- | ---: |
| PFN candidates | 15,511,571 |
| PFN selected | 1,550,650 |
| selected / candidates | 9.9967% |
| selected basis points | 999 |
| local fault sampled | 1,550,650 |
| local fault PTE updates | 1,550,650 |
| local fault refault | 1,529,434 |
| local fault lost | 21,216 |

This validates the PFN predicate ratio among eligible local-fault sampling
checks. It does not count unique resident folios; proving unique coverage would
require a per-run PFN bitmap or equivalent tracing.

Artifacts:

- `/Serverless/iccd/experiments/20260510-localfault-pfn-offset-vm/qemu-logs/phase_candidate_microbench/20260510Tlocalfault-pfnoffset-diag-stream32-on-60s/`

## Full-Sweep Coverage Diagnostic

To validate coverage rather than only the event-ratio counter, a controlled VM
run allocated and first-touched a 16 GiB order-0 mapping on local node0 with
local-fault sampling disabled. After allocation, it enabled
`numa_local_fault_on_tiering=10`, waited until the NUMA scan had armed the
expected number of local pages, then touched the whole 16 GiB mapping once and
measured the resulting local refault count.

- Run id: `20260510Tlocalfault-fullsweep-16g-rate10-v3`
- Guest kernel: `Linux kernel 6.18.0modified #170 SMP PREEMPT_DYNAMIC Sun May 10 06:58:17 UTC 2026 x86_64`
- Allocation: `16G`, `4,194,304` pages, THP disabled with `MADV_NOHUGEPAGE`
- Expected selected pages at 10%: `419,430`
- Scan: `256MB`, `1000ms`, fast scan off
- Runtime knobs: global NUMA balancing `0`, cgroup `memory.node_balancing=2`,
  `numa_local_fault_on_tiering=10`
- MGLRU: `0x0007`

Scan wait timeline:

| elapsed | PFN candidates | PFN selected | PTE updates | refault |
| ---: | ---: | ---: | ---: | ---: |
| 0s | 0 | 0 | 0 | 0 |
| 5s | 1,835,009 | 183,502 | 183,502 | 0 |
| 11s | 4,194,319 | 419,427 | 419,427 | 0 |

Sweep result:

| metric | value |
| --- | ---: |
| expected selected pages | 419,430 |
| PTE updates before sweep | 419,427 |
| PTE updates / expected | 99.9993% |
| hint faults during full sweep | 419,427 |
| local-fault refault delta during full sweep | 419,427 |
| refault delta / expected | 99.9993% |

This validates that the PFN-offset sampler armed essentially 10% of the
controlled local resident 16 GiB mapping, and that a subsequent full-memory
access refaulted exactly the pre-sweep armed pages. The post-sweep snapshot also
contains 19,664 extra PTE updates and matching lost count because the scanner
continued running while the final sweep/snapshot completed; coverage is
therefore judged from `before_sweep` PTE updates and the sweep-time refault
delta.

Artifacts:

- `/Serverless/iccd/experiments/20260510-localfault-pfn-offset-vm/qemu-logs/local_fault_sweep/20260510Tlocalfault-fullsweep-16g-rate10-v3/`
