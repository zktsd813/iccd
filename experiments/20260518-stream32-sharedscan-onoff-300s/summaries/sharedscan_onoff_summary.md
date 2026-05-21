# Stream32 shared-scan on/off, 300s

mbench change: `--bw-shared-window` makes every BW worker scan the full 32G window instead of splitting it into per-thread slices. Workload command uses `--placement window-split:0,1`, `--bw-stride 512`, `--bw-block 4K`, `--threads 32`, forced duration 300s.

## Summary
| policy | final avg MiB/s | sample mean MiB/s | sample median MiB/s | promoted GiB | demoted GiB | hint faults | PTE updates |
|---|---:|---:|---:|---:|---:|---:|---:|
| off | 5271.0 | 5269.3 | 5312.0 | 0.00 | 0.00 | 0 | 0 |
| on | 517.8 | 522.9 | 0.0 | 60.47 | 60.24 | 47,481,507 | 39,415,456 |

## Interpretation Notes
- `final avg MiB/s = final_bytes_total / 300s`; this is the primary comparison metric.
- `sample median` is misleading for shared-scan because each worker reports bytes only after completing a large full-window pass; on can have many 1s samples with zero progress.
- Initial placement before measurement is about 14.6GiB on node0 and 17.4GiB on node1 for both policies.

## off Details

30s throughput:

| interval | mean MiB/s | median MiB/s |
|---|---:|---:|
| 0-30s | 5147.7 | 5152.0 |
| 30-60s | 5256.4 | 5376.0 |
| 60-90s | 5422.4 | 5440.0 |
| 90-120s | 5345.0 | 5312.0 |
| 120-150s | 5162.5 | 5085.4 |
| 150-180s | 5218.0 | 5248.0 |
| 180-210s | 5348.3 | 5504.0 |
| 210-240s | 5177.6 | 5088.0 |
| 240-270s | 5267.9 | 5376.0 |
| 270-300s | 5363.6 | 5376.0 |

30s migration/residency:

| interval | promote | demote | hint | PTE | anon N0 | anon N1 |
|---|---:|---:|---:|---:|---:|---:|
| 0-30s | 0 | 0 | 0 | 0 | 14.60 | 17.40 |
| 30-60s | 0 | 0 | 0 | 0 | 14.60 | 17.40 |
| 60-90s | 0 | 0 | 0 | 0 | 14.60 | 17.40 |
| 90-120s | 0 | 0 | 0 | 0 | 14.60 | 17.40 |
| 120-150s | 0 | 0 | 0 | 0 | 14.60 | 17.40 |
| 150-180s | 0 | 0 | 0 | 0 | 14.60 | 17.40 |
| 180-210s | 0 | 0 | 0 | 0 | 14.60 | 17.40 |
| 210-240s | 0 | 0 | 0 | 0 | 14.60 | 17.40 |
| 240-270s | 0 | 0 | 0 | 0 | 14.60 | 17.40 |
| 270-300s | 0 | 0 | 0 | 0 | 14.60 | 17.40 |
## on Details

30s throughput:

| interval | mean MiB/s | median MiB/s |
|---|---:|---:|
| 0-30s | 204.6 | 0.0 |
| 30-60s | 787.5 | 0.0 |
| 60-90s | 498.3 | 0.0 |
| 90-120s | 264.3 | 0.0 |
| 120-150s | 353.0 | 0.0 |
| 150-180s | 264.5 | 0.0 |
| 180-210s | 635.8 | 0.0 |
| 210-240s | 882.8 | 0.0 |
| 240-270s | 140.8 | 0.0 |
| 270-300s | 1156.1 | 0.0 |

30s migration/residency:

| interval | promote | demote | hint | PTE | anon N0 | anon N1 |
|---|---:|---:|---:|---:|---:|---:|
| 0-30s | 314,856 | 64,563 | 9,089,143 | 8,914,654 | 15.56 | 16.44 |
| 30-60s | 1,713,263 | 1,760,621 | 4,657,224 | 4,167,165 | 15.38 | 16.62 |
| 60-90s | 1,462,442 | 1,591,494 | 3,557,721 | 2,896,334 | 14.88 | 17.12 |
| 90-120s | 1,161,339 | 1,026,125 | 3,938,944 | 2,834,673 | 15.40 | 16.60 |
| 120-150s | 1,724,730 | 1,628,864 | 4,707,644 | 3,951,542 | 15.77 | 16.23 |
| 150-180s | 1,803,524 | 1,947,118 | 3,703,671 | 2,631,193 | 15.22 | 16.78 |
| 180-210s | 1,198,170 | 1,329,408 | 3,290,859 | 2,752,034 | 14.72 | 17.28 |
| 210-240s | 1,671,403 | 1,577,536 | 4,168,424 | 3,196,947 | 15.08 | 16.92 |
| 240-270s | 1,962,855 | 1,804,160 | 3,613,818 | 2,700,979 | 15.68 | 16.32 |
| 270-300s | 1,828,425 | 2,004,481 | 4,101,876 | 3,430,554 | 15.01 | 16.99 |
