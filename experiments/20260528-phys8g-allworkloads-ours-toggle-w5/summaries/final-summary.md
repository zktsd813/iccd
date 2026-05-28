# Physical 8G all workloads, ours-toggle w5

Date: 2026-05-28.

Policy: physical node0 8G, node1 160G, `ours` with 5s window and `reenable_consecutive=2`. Cgroup `node_capacity` was disabled (`capacity_pages=0`), so the local-memory limit is the VM physical node0 size.

All workloads completed with return code 0.

| workload | elapsed_s | primary time | off_ms | on_ms | final state | hint faults | promoted | demoted |
| --- | ---: | ---: | --- | --- | --- | ---: | ---: | ---: |
| pr | 234 | avg trial 25.32617 | 40019 |  | off | 7,980,616 | 245,557 | 1,587,843 |
| bc | 428 | avg trial 50.06641 | 70025 |  | off | 13,651,318 | 1,287,263 | 2,150,203 |
| silo | 1029 |  | 15009;330163 | 35020 | off | 33,667,736 | 2,502,786 | 6,805,925 |
| liblinear | 1832 |  | 15009;240120 | 50027;250125 | on | 269,057,482 | 0 | 0 |
| FT | 612 | 599.42 | 20013 |  | off | 11,239,629 | 1,426,069 | 1,478,119 |
| LU | 1033 | 941.86 | 25012 |  | off | 18,334,384 | 1,360,320 | 1,477,761 |
| SP | 1125 | 1047.21 | 20017 |  | off | 12,813,269 | 959,772 | 1,095,932 |
| gups | 629 | Took 626.18446744073709551234 | 40019 |  | off | 17,590,954 | 520,534 | 1,601,736 |
| graph500 | 382 |  | 170060;325100 | 310093;350114 | on | 19,845,169 | 3,035,071 | 4,778,779 |
| btree | 786 | Took 781.18446744073709551292 | 150080 |  | off | 16,750,468 | 2,017,374 | 6,640,865 |
| xsbench | 782 |  | 15008;80044 | 45025 | off | 12,165,458 | 808,953 | 2,021,574 |

`demoted` is `pgdemote_kswapd + pgdemote_direct`; direct demotion was 0 for every row in this run.

Raw artifacts are under `guest-results/phys8g-allworkloads-ours-toggle-w5/`.
