# sparse64 on/off demotion check

Date: 2026-05-07 UTC

Workload:

- candidate: `sparse_stride_read_64g_block2m_remoteft`
- command shape: `--mode bw --bw-kernel read --window-size 64G --move-policy fixed --bw-stride 512 --bw-block 2M --threads 32`
- measurement: 50s after remote-firsttouch prefault
- VM: 32 vCPU, node0 32G host node0, node1 64G host node2, cgroup node0 cap 16G
- migration stop and pingpong stat were disabled
- kernel: `Linux kernel 6.18.0modified #107 SMP PREEMPT_DYNAMIC Thu May 7 12:03:56 UTC 2026`

Important accounting note:

- `memcg_reclaimd` demotion is currently accounted as `pgdemote_direct`, not
  `pgdemote_kswapd`.
- Demotion below uses `pgdemote_direct + pgdemote_kswapd` from
  `memory.numa_stat` before/after.

| policy | mean MB/s | on/off | promote GiB | demote direct GiB | demote kswapd GiB | demote total GiB | hint faults | reclaimd wake/run |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| off | 417.82 | 1.000 | 0.00 | 0.00 | 0.00 | 0.00 | 0 | 0/0 |
| on | 1725.43 | 4.130 | 14.89 | 0.86 | 0.00 | 0.86 | 202805231 | 1/1 |

Watermark/capacity:

- capacity: `4194304 pages` = 16.00 GiB
- low watermark: `3984588 pages` = 15.20 GiB
- high watermark: `4110417 pages` = 15.68 GiB
- on max node0 usage sampled: `4094049 pages` = 15.62 GiB
- sample likely missed the short over-high point; reclaimd still woke and
  demoted `225178 pages` = 0.86 GiB.

Prefault placement:

- off before measurement: `anon N0=0`, `anon N1=67148947456`
- on before measurement: `anon N0=0`, `anon N1=67154264064`

Artifacts:

- root: `/Serverless/iccd/experiments/20260507-sparse64-onoff-demotion-check/qemu-logs/phase_candidate_microbench/sparse64_onoff_demote_20260507T120140Z/guest-artifacts/sparse64_onoff_demote_20260507T120140Z_manual`
