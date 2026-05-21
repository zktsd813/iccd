# sparse block2M deep result

- Candidate: `sparse_stride_read_64g_block2m_remoteft`
- VM: guest node0 32G bound to host node0 DRAM, guest node1 64G bound to host node2 CXL, cgroup local cap 16G.
- Measurement: remote prefault, then 60s measured run, 3 reps, 32 threads. off also keeps demotion enabled; on enables cgroup NUMA balancing `0x2`.
- Access shape: 64G read, `--bw-block 2M --bw-stride 512`, so the loop reads one double per 4KiB page but orders accesses by 2MiB blocks/lane.

| policy | n | mean MB/s | sd | on/off | mean Mops/s | sd | promoted GiB | hints | refault avg | max N0 anon |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| off | 3 | 392.17 | 45.41 |  | 49.02 | 5.68 | 0.00 | 0.0M | 0.0 us | 1.45 GiB |
| on | 3 | 128.72 | 37.55 | 0.328x | 16.09 | 4.69 | 18.72 | 29.5M | 1.3 us | 15.62 GiB |

## Per run

| policy | rep | MB/s | Mops/s | promote GiB | hint faults | refault sampled | refault avg | return |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| off | 1 | 354.72 | 44.34 | 0.00 | 0.0M | 0.00M | 0.0 us | 0 |
| off | 2 | 379.11 | 47.39 | 0.00 | 0.0M | 0.00M | 0.0 us | 0 |
| off | 3 | 442.68 | 55.34 | 0.00 | 0.0M | 0.00M | 0.0 us | 0 |
| on | 1 | 110.67 | 13.83 | 14.59 | 29.4M | 0.38M | 1.0 us | 0 |
| on | 2 | 103.61 | 12.95 | 20.92 | 29.1M | 0.55M | 1.0 us | 0 |
| on | 3 | 171.89 | 21.49 | 20.67 | 29.9M | 0.54M | 2.0 us | 0 |

## Interpretation

- Deep average confirms a strong unfriendly case: on/off by MB/s = 0.328 (-67.2%).
- The on runs promote about 18.7 GiB in total and keep node0 anon near 15.6 GiB, but the access order does not reuse those promoted pages enough during the measured window.
- The cost shows up as millions of NUMA hint faults and page migrations on the critical path; off avoids that work and stays much faster for this sparse block2M traversal.
- All 6 deep runs returned `0`; no timeout/failure was observed.
