# PC64 stride pointer-chase on/off

- Run: `pc64_stride_onoff_20260507T064942Z`
- Artifact root: `/Serverless/iccd/experiments/20260507-pc64-stride-onoff-bound-cxl/qemu-logs/phase_candidate_microbench/pc64_stride_onoff_20260507T064942Z/guest-artifacts/pc64_stride_onoff_20260507T064942Z`
- VM: host CPUs 0-31; guest node0 32G backed by host node0 DRAM; guest node1 64G backed by host node2 CXL; QEMU memory policy bind + prealloc.
- Workload: `mbench --mode pc --window-size 64G --pc-chains 1 --pc-pattern stride --threads 32 --persistent-workers --duration-ms 60000`. Arena is 64G and remote-firsttouch is enabled.
- Cgroup node0 cap: 4194304 pages = 16.0 GiB, low 15.2 GiB, high 15.68 GiB.

| policy | mean Mops/s | median Mops/s | on/off | promoted GiB | hint faults | blocked | max node0 GiB | refault avg us |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| off | 119.40 | 119.41 | 0.82 | 0.00 | 0 | 0 | 1.42 | 0 |
| on | 97.32 | 93.78 | 0.82 | 21.78 | 247778487 | 1167601 | 15.62 | 1 |

- Result: migration-on/off throughput ratio is `0.82x`; migration-on is slower by `18.5%`.
- On promoted about 21.78 GiB and filled node0 to the cgroup high watermark region, but this did not improve throughput. It added NUMA hint fault and migration overhead to a global 64G dependent pointer-chase stream.
- Off had no NUMA hint faults and kept almost all anonymous memory on node1 after remote-firsttouch, with only about 1.42 GiB node0 residency during initialization/measurement.
