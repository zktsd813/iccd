# Physical 8G Silo Ours-Toggle w5 With Window Vmstat

Date: 2026-05-28.

This rerun uses the same physical-limit VM topology as the previous physical
8G workload run, but executes only Silo.  The controller was extended to record
per-window `/proc/vmstat` deltas for promotion, demotion, and migration.

## Result

| item | value |
| --- | ---: |
| return code | 0 |
| elapsed | 1075 s |
| final controller state | off |
| first off | 15.013 s, window 3, `remote_ratio` |
| re-enabled | 25.020 s, window 5 |
| final off | 335.221 s, window 67, `local_access` |
| hint faults | 32,769,927 |
| promoted pages | 2,195,945 |
| promoted GiB | 8.38 |
| demoted pages | 6,470,850 |
| demoted GiB | 24.68 |
| pgmigrate_success | 8,964,043 |

## Phase Totals

| windows | interpretation | promoted | demoted | hint faults | pte updates | refault |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 1-24 | dataloading | 4 | 4,080,853 | 82 | 349,792 | 62 |
| 25-60 | post-load / worker initialization | 9,211 | 160,129 | 1,752,735 | 174,950 | 4,407 |
| 61-67 | worker start and stop decision | 2,184,618 | 2,221,833 | 26,575,958 | 138,022 | 137,199 |
| 68-215 | after migration off | 1,347 | 6,306 | 4,436,365 | 4,524,555 | 4,237,880 |

## Stop Window

| window | elapsed s | local access | promoted | demoted | hint faults | state |
| ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 64 | 320.216 | 24.14% | 57,292 | 68,388 | 9,205,769 | on |
| 65 | 325.218 | 100.00% | 734,052 | 766,581 | 10,312,354 | on |
| 66 | 330.219 | 99.09% | 702,776 | 721,837 | 3,597,330 | on |
| 67 | 335.221 | 99.85% | 690,498 | 665,027 | 3,460,496 | off |

After window 67, promotion effectively stops.  Window 68 still has residual
migration (`promoted=1,347`, `demoted=6,306`), then later windows have zero
promotion/demotion deltas while local access remains high.

Raw window data:

- `summaries/silo_window_local_promotion.csv`
- `guest-results/phys8g-allworkloads-ours-toggle-w5/silo/ours_toggle_w5/controller.csv`
