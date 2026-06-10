# Design Histogram Figure

This directory contains the two-panel histogram figure requested for the
design section.

- `design_histogram.pdf`, `design_histogram.svg`, `design_histogram.png`: final
  figure.
- `selected_histogram_data.csv`: selected window histogram data extracted from
  the source SVG panels.
- `plot_design_histogram.py`: reproducible extraction and plotting script.
- `source/`: copies of the source facet PDFs/SVGs used to extract the two
  selected panels.

Panels:

- `(a) GAPBS BC`, window 32 from
  `gapbs_bc_g29_lfrate_01_i4_local48_remote128_10s_fault_latency_windows_histograms_local_p80_remote_p20_facets`.
  Local P80 is `<=128 ms`; remote P20 is `<=1024 ms`.
- `(b) BTree`, window 130 from
  `btree_local16_10s_fault_latency_windows_histograms_local_p80_remote_p20_facets`.
  Local P80 is `<=1024 ms`; remote P20 is `<=256 ms`.

Encoding:

- Blue bars: local fault-latency samples.
- Red bars: remote fault-latency samples.
- Blue dotted line and down-triangle: local P80 bucket.
- Red dotted line and up-triangle: remote P20 bucket.

The latest copy is also placed under `experiments/figure/` as
`submission_design_histogram.{pdf,svg,png}`.
