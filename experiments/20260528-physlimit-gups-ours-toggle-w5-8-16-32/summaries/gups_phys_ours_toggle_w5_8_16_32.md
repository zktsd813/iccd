# GUPS physical ours-toggle w5, 8G/16G/32G

Date: 2026-05-28.

Kernel image: `/Serverless/iccd/linux-build-mt/arch/x86/boot/bzImage`.
Initrd: `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified.img`.
Guest kernel: `6.18.0modified+ #10 SMP PREEMPT_DYNAMIC Fri May 22 03:33:06 UTC 2026`.

Topology: physical node0-size experiment. Guest node0 was backed by host node0 DRAM and sized to 8G, 16G, or 32G. Guest node1 was backed by host node2 CXL memory. Total VM memory was fixed at 168G. Cgroup `node_capacity` was disabled (`capacity_pages=0`).

Policy: `ours` now means toggle-enabled controller: `window_sec=5`, `reenable_consecutive=2`, `node_balancing=2` initially, `numa_local_fault_on_tiering=10`, threshold 80%, 3 consecutive windows, eval lag `prev`.

## Result

| physical local | GUPS Took (s) | script elapsed (s) | off event | on events | final state |
| --- | ---: | ---: | --- | ---: | --- |
| 8G | 648.184 | 651 | 45.020s, window 9, `local_access` | 0 | off |
| 16G | 548.043 | 551 | 50.022s, window 10, `local_access` | 0 | off |
| 32G | 318.251 | 321 | 45.020s, window 9, `local_access` | 0 | off |

## Counters

| physical local | hint faults | promoted | demoted | migrate success | local PTE updates | local refault | local refault hit |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 8G | 18,095,181 | 993,023 | 1,849,734 | 3,191,098 | 3,015,399 | 2,930,711 | 2,801,356 |
| 16G | 19,139,474 | 644,887 | 649,893 | 1,631,792 | 5,963,459 | 5,961,088 | 5,592,340 |
| 32G | 17,486,397 | 588,032 | 614,275 | 1,503,060 | 9,916,799 | 9,904,753 | 9,258,270 |

## Toggle Observation

The controller was run with `--reenable-consecutive 2`, but no `on` event occurred in any of the three runs. After the first `off`, the local-fault condition remained true in later windows, so the re-enable counter never advanced.

Artifacts:

- Runner: `notes/run_phys_gups_ours_toggle_w5.sh`
- Raw results: `guest-results/{8g,16g,32g}/toggle_w5/`
- CSV summary: `summaries/gups_phys_ours_toggle_w5_8_16_32.csv`
