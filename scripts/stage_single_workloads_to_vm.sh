#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-10030}"
HOST="${HOST:-127.0.0.1}"
SSH_OPTS=(-p "${PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
SCP_OPTS=(-P "${PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
BENCHMARK_DIR="${BENCHMARK_DIR:-/Serverless/benchmark}"
INCLUDE_LIBLINEAR="${INCLUDE_LIBLINEAR:-0}"
INCLUDE_SILO="${INCLUDE_SILO:-1}"

remote() {
  ssh "${SSH_OPTS[@]}" "root@${HOST}" "$@"
}

copy_file() {
  local src="$1"
  local dst="$2"
  remote "mkdir -p '$(dirname "${dst}")'"
  scp "${SCP_OPTS[@]}" "${src}" "root@${HOST}:${dst}"
}

remote "mkdir -p /root/scripts /root/benchmark"
copy_file /Serverless/iccd/scripts/run_single_workload_live_placement_guest.sh \
  /root/scripts/run_single_workload_live_placement_guest.sh
copy_file /Serverless/iccd/scripts/run_single_workload_policy_matrix_8g_guest.sh \
  /root/scripts/run_single_workload_policy_matrix_8g_guest.sh
copy_file /Serverless/iccd/scripts/run_local_util_adapt_experiment.sh \
  /root/scripts/run_local_util_adapt_experiment.sh
copy_file /Serverless/iccd/scripts/local_util_adapt_controller.py \
  /root/scripts/local_util_adapt_controller.py
remote "chmod +x /root/scripts/run_single_workload_live_placement_guest.sh /root/scripts/run_single_workload_policy_matrix_8g_guest.sh /root/scripts/run_local_util_adapt_experiment.sh /root/scripts/local_util_adapt_controller.py"

# GAPBS PR/BC are already expected as /root/pr and /root/bc in the current
# experiment overlay. Keep using those with /root/gapbs_graphs/kron_g28.sg.

copy_file "${BENCHMARK_DIR}/NPB3.4.3/NPB3.4-OMP/bin/ft.H.x" \
  /root/benchmark/NPB3.4.3/NPB3.4-OMP/bin/ft.H.x
copy_file "${BENCHMARK_DIR}/NPB3.4.3/NPB3.4-OMP/bin/lu.H.x" \
  /root/benchmark/NPB3.4.3/NPB3.4-OMP/bin/lu.H.x
copy_file "${BENCHMARK_DIR}/NPB3.4.3/NPB3.4-OMP/bin/sp.H.x" \
  /root/benchmark/NPB3.4.3/NPB3.4-OMP/bin/sp.H.x
remote "chmod +x /root/benchmark/NPB3.4.3/NPB3.4-OMP/bin/ft.H.x /root/benchmark/NPB3.4.3/NPB3.4-OMP/bin/lu.H.x /root/benchmark/NPB3.4.3/NPB3.4-OMP/bin/sp.H.x"

for lib in \
  /lib/x86_64-linux-gnu/libgfortran.so.5 \
  /lib/x86_64-linux-gnu/libgfortran.so.5.* \
  /lib/x86_64-linux-gnu/libquadmath.so.0 \
  /lib/x86_64-linux-gnu/libquadmath.so.0.* \
  /lib/x86_64-linux-gnu/libgomp.so.1 \
  /lib/x86_64-linux-gnu/libgomp.so.1.*
do
  if compgen -G "${lib}" >/dev/null; then
    for src in ${lib}; do
      copy_file "${src}" "/usr/local/lib/npb-deps/$(basename "${src}")"
    done
  fi
done
remote "printf '%s\n' /usr/local/lib/npb-deps > /etc/ld.so.conf.d/npb-deps.conf && ldconfig"

copy_file "${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_gups_mt" \
  /root/benchmark/vmitosis-workloads/bin/bench_gups_mt
copy_file "${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_graph500_mt" \
  /root/benchmark/vmitosis-workloads/bin/bench_graph500_mt
copy_file "${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_btree_mt" \
  /root/benchmark/vmitosis-workloads/bin/bench_btree_mt

copy_file "${BENCHMARK_DIR}/XSBench/openmp-threading/XSBench" \
  /root/benchmark/XSBench/openmp-threading/XSBench

if [[ "${INCLUDE_LIBLINEAR}" == "1" ]]; then
  copy_file "${BENCHMARK_DIR}/liblinear-multicore-2.47/train" \
    /root/benchmark/liblinear-multicore-2.47/train
  copy_file "${BENCHMARK_DIR}/liblinear-multicore-2.47/datasets/kdd12" \
    /root/benchmark/liblinear-multicore-2.47/datasets/kdd12
fi

if [[ "${INCLUDE_SILO}" == "1" ]]; then
  remote "mkdir -p /root/benchmark/silo"
  scp -r "${SCP_OPTS[@]}" "${BENCHMARK_DIR}/silo/out-perf.masstree" \
    "root@${HOST}:/root/benchmark/silo/"
  copy_file "${BENCHMARK_DIR}/silo/third-party/lz4/liblz4.so" \
    /usr/local/lib/silo-deps/liblz4.so
  for lib in \
    /lib/x86_64-linux-gnu/libjemalloc.so.2 \
    /lib/x86_64-linux-gnu/libdb_cxx-5.3.so
  do
    copy_file "${lib}" "/usr/local/lib/silo-deps/$(basename "${lib}")"
  done
  remote "printf '%s\n' /usr/local/lib/silo-deps > /etc/ld.so.conf.d/silo-deps.conf && ldconfig"
fi

remote "find /root/benchmark -type f | sort; ls -lh /root/pr /root/bc /root/gapbs_graphs/kron_g28.sg 2>/dev/null || true"
