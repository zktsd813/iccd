# Local-Fixed Unfriendly Candidate Sweep

Date: 2026-05-07

## Verdict

Confirmed unfriendly candidates under the current 256 MiB NUMA scan setup:

| candidate | final n | on/off | off throughput | on throughput | on promoted | on demoted | status |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `sparse_stride_read_64g_block2m_localft` | 3 | `0.567 +/- 0.007` | `1978.71 +/- 14.49 MiB/s` | `1121.61 +/- 5.44 MiB/s` | `2,005,879` pages (`7.65 GiB`) | `2,202,975` pages (`8.40 GiB`) | confirmed strong |
| `sparse_stride_read_64g` | 3 | `0.716 +/- 0.004` | `1667.92 +/- 17.04 MiB/s` | `1194.97 +/- 11.79 MiB/s` | `1,957,369` pages (`7.47 GiB`) | `1,953,943` pages (`7.45 GiB`) | confirmed strong |

Rejected/unstable validation candidate:

| candidate | final n | on/off | off throughput | on throughput | on promoted | on demoted | status |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `stream_triad_sweep_32g` | 3 | `0.906 +/- 0.019` | `33018.57 +/- 319.85 MiB/s` | `29917.23 +/- 460.11 MiB/s` | `1,461,687` pages (`5.58 GiB`) | `1,566,704` pages (`5.98 GiB`) | outside allowed `0.9` cutoff |

The strongest replacement for the old remote-first-touch negative case is
`sparse_stride_read_64g_block2m_localft`. It is local-first-touch, fixed
window, 64 GiB footprint, sparse read, `--bw-stride 512`, `--bw-block 2M`.
Migration-on repeatedly loses about 43% throughput while promoting and demoting
about 8 GiB in the measured interval.

## Run Setup

Both the broad smoke sweep and final validation used the required VM setup:

| item | value |
| --- | --- |
| kernel image | `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage` |
| initrd | `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260507T171412Z-unfriendly.img` |
| guest kernel | `Linux kernel 6.18.0modified #121 SMP PREEMPT_DYNAMIC Thu May 7 16:47:15 UTC 2026 x86_64` |
| KVM | enabled, QEMU command used `-accel kvm` |
| vCPUs/memory | `CPUS=32`, `MEMORY=96G` |
| CPU binding | `HOST_CPUS=0-31`, guest node0 CPUs `0-31` |
| memory binding | guest node0 `32G` on host node0, guest node1 `64G` on host node2 CXL |
| QEMU memory policy | `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1` |
| cgroup cap | `CAPACITY_PAGES=4194304` (`16 GiB`) |
| workload memory | `ARENA_SIZE=64G`, `THREADS=32`, `CPUSET_CPUS=0-31`, `CPUSET_MEMS=0,1` |
| placement | local-first-touch; final candidates used `remote_firsttouch=0` |
| MGLRU runtime | `/sys/kernel/mm/lru_gen/enabled = 0x0007` |
| migration on knobs | `GLOBAL_NUMA_ON=0`, `NODE_BALANCING_ON=2` |
| demotion knobs | `KSWAPD_DEMOTION_ON=1`, `OFF_DEMOTION_ON=1` |
| scan tuning | `NUMA_SCAN_SIZE_MB=256`, `SCAN_PERIOD_SCALE=1`, `HOT_THRESHOLD_MS=0` |
| build rule | kernel builds for this line of experiments must use `make -C /Serverless/Migration-friendly/linux -j$(nproc) ...`; no rebuild was needed for this sweep because the fresh initrd above was reused |

## Smoke Sweep

Run:
`/Serverless/iccd/experiments/20260507-unfriendly-localfixed-6h-sweep-256scan-initrd/qemu-logs/phase_candidate_microbench/localfixed_smoke_20260507T172855Z`

The smoke sweep ran 43 local-first-touch candidates across head/tail pointer
chase, hotset sizes, fixed and moving windows, sparse read/write, STREAM triad,
and irregular-index access patterns. It used `REPS=1`, `POLICIES=off,on`, and
30 second measurement windows. Candidate list:
`/Serverless/iccd/experiments/20260507-unfriendly-localfixed-6h-sweep-256scan-initrd/notes/smoke_candidates.txt`.

Smoke candidates at or near the cutoff:

| candidate | smoke on/off | off throughput | on throughput | on promoted | on demoted | decision |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `sparse_stride_read_64g_block2m_localft` | `0.547` | `1980.89 MiB/s` | `1084.30 MiB/s` | `2,115,385` pages (`8.07 GiB`) | `2,112,213` pages (`8.06 GiB`) | final validation |
| `sparse_stride_read_64g_block2m` | `0.602` | `1988.07 MiB/s` | `1196.98 MiB/s` | `2,159,450` pages (`8.24 GiB`) | `2,164,576` pages (`8.26 GiB`) | duplicate runner args; not final separately |
| `sparse_stride_read_64g` | `0.760` | `1681.18 MiB/s` | `1277.62 MiB/s` | `1,869,907` pages (`7.13 GiB`) | `1,870,249` pages (`7.13 GiB`) | final validation |
| `stream_triad_sweep_32g` | `0.844` | `32883.07 MiB/s` | `27761.97 MiB/s` | `728,521` pages (`2.78 GiB`) | `816,316` pages (`3.11 GiB`) | final validation, later rejected |
| `sparse_stride_write_64g` | `0.905` | `1169.63 MiB/s` | `1058.03 MiB/s` | `1,701,842` pages (`6.49 GiB`) | `1,689,831` pages (`6.45 GiB`) | near miss, above `0.9` cutoff |
| `tail64_hotset_4g_move_10s` | `0.947` | `2185.27 Mops/s` | `2070.05 Mops/s` | `118,017` pages (`0.45 GiB`) | `179,961` pages (`0.69 GiB`) | rejected |

`sparse_stride_read_64g_block2m` and
`sparse_stride_read_64g_block2m_localft` currently expand to the same runner
arguments and both use local-first-touch. Final validation kept only the
explicit `_localft` label to avoid counting the same workload twice.

## Final Validation

Run:
`/Serverless/iccd/experiments/20260507-unfriendly-localfixed-6h-sweep-256scan-initrd/qemu-logs/phase_candidate_microbench/localfixed_final3_20260507T192316Z`

The final validation used `REPS=3`, `POLICIES=off,on`, 60 second measurement
windows, and `LIVE_SAMPLE_SEC=1`.

### `sparse_stride_read_64g_block2m_localft`

| rep | on/off | off throughput | on throughput | on promoted | on demoted |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | `0.575` | `1962.53 MiB/s` | `1127.86 MiB/s` | `1,967,915` pages (`7.51 GiB`) | `2,538,924` pages (`9.69 GiB`) |
| 2 | `0.564` | `1983.16 MiB/s` | `1117.89 MiB/s` | `2,060,732` pages (`7.86 GiB`) | `2,045,021` pages (`7.80 GiB`) |
| 3 | `0.562` | `1990.46 MiB/s` | `1119.09 MiB/s` | `1,988,989` pages (`7.59 GiB`) | `2,024,979` pages (`7.72 GiB`) |

Migration-off still had small demotion deltas from the enabled off-policy
demotion path: mean `191,641` pages (`0.73 GiB`) demoted and zero promotions.

### `sparse_stride_read_64g`

| rep | on/off | off throughput | on throughput | on promoted | on demoted |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | `0.716` | `1687.48 MiB/s` | `1207.44 MiB/s` | `2,007,337` pages (`7.66 GiB`) | `2,059,584` pages (`7.86 GiB`) |
| 2 | `0.721` | `1656.28 MiB/s` | `1193.47 MiB/s` | `1,917,898` pages (`7.32 GiB`) | `1,869,841` pages (`7.13 GiB`) |
| 3 | `0.713` | `1660.00 MiB/s` | `1184.00 MiB/s` | `1,946,871` pages (`7.43 GiB`) | `1,932,403` pages (`7.37 GiB`) |

Migration-off mean demotion was `174,624` pages (`0.67 GiB`) with zero
promotions.

### `stream_triad_sweep_32g`

| rep | on/off | off throughput | on throughput | on promoted | on demoted |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | `0.895` | `33378.61 MiB/s` | `29875.27 MiB/s` | `1,959,163` pages (`7.47 GiB`) | `2,087,499` pages (`7.96 GiB`) |
| 2 | `0.928` | `32767.28 MiB/s` | `30396.89 MiB/s` | `464,951` pages (`1.77 GiB`) | `451,287` pages (`1.72 GiB`) |
| 3 | `0.896` | `32909.80 MiB/s` | `29479.54 MiB/s` | `1,960,947` pages (`7.48 GiB`) | `2,161,326` pages (`8.24 GiB`) |

This candidate does not meet the requested final cutoff because the 3-run mean
is `0.906`, above the allowed `0.9`. It should be kept as a near-miss only.

## Interpretation

The confirmed cases are not remote-first-touch artifacts. They start from
local-first-touch placement (`remote_firsttouch=0`) under the same 16 GiB local
cap used by the friendly validation. Migration-on then creates substantial
promotion/demotion churn for footprints that exceed the local cap, and the
measured throughput falls well below migration-off.

Use `sparse_stride_read_64g_block2m_localft` as the primary unfriendly case.
Use `sparse_stride_read_64g` as a secondary unfriendly case with a different
block shape (`--bw-block 4K`). Do not use `stream_triad_sweep_32g` as a final
negative case unless the cutoff is relaxed beyond `0.9`.
