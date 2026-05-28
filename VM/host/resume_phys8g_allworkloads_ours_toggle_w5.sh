#!/usr/bin/env bash
set -euo pipefail

EXP=/Serverless/iccd/experiments/20260528-phys8g-allworkloads-ours-toggle-w5
VM_DIR="${VM_DIR:-/Serverless/iccd/VM}"
VM_SCRIPTS="${VM_SCRIPTS:-${VM_DIR}/scripts}"
VM_GUEST="${VM_GUEST:-${VM_DIR}/guest}"
LAUNCH=/Serverless/Migration-friendly/scripts/kernel/launch_kernel_qemu.sh
KERNEL=/Serverless/iccd/linux-build-mt/arch/x86/boot/bzImage
INITRD=/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified.img
ROOTFS=/Serverless/Migration-friendly/qemu/build/ubuntu.img
QEMU=/Serverless/Migration-friendly/qemu/build/qemu-system-x86_64
BENCH=/Serverless/benchmark
PORT=10064
VM_NAME=aw8tog
TOTAL_GB=168
NODE0_GB=8
NODE1_GB=160

SSH_BASE=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p "${PORT}" root@127.0.0.1)
SCP_BASE=(scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P "${PORT}")

remote() {
  "${SSH_BASE[@]}" "$@"
}

copy_file() {
  local src="$1"
  local dst="$2"
  remote "mkdir -p '$(dirname "${dst}")'"
  "${SCP_BASE[@]}" "${src}" "root@127.0.0.1:${dst}" >/dev/null
}

copy_file_if_missing() {
  local src="$1"
  local dst="$2"
  if remote "test -e '${dst}'"; then
    echo "skip existing ${dst}"
    return 0
  fi
  echo "copy ${src} -> ${dst}"
  copy_file "${src}" "${dst}"
}

copy_dir_if_missing() {
  local src="$1"
  local marker="$2"
  local dst_parent="$3"
  if remote "test -e '${marker}'"; then
    echo "skip existing ${marker}"
    return 0
  fi
  remote "mkdir -p '${dst_parent}'"
  echo "copy dir ${src} -> ${dst_parent}/"
  scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P "${PORT}" "${src}" "root@127.0.0.1:${dst_parent}/" >/dev/null
}

wait_ssh() {
  local deadline=$((SECONDS + 360))
  until remote 'true' >/dev/null 2>&1; do
    if (( SECONDS > deadline )); then
      echo "ssh did not come up on port ${PORT}" >&2
      return 1
    fi
    sleep 2
  done
}

stop_vm() {
  local pids
  pids="$(pgrep -f "qemu-system-x86_64.*-name ${VM_NAME}" || true)"
  if [[ -n "${pids}" ]]; then
    kill ${pids} 2>/dev/null || true
    sleep 2
  fi
  pids="$(pgrep -f "qemu-system-x86_64.*-name ${VM_NAME}" || true)"
  if [[ -n "${pids}" ]]; then
    kill -9 ${pids} 2>/dev/null || true
  fi
}

stage_guest() {
  remote "mkdir -p /root/scripts /root/benchmark /root/gapbs_graphs"
  copy_file "${VM_SCRIPTS}/run_local_util_adapt_experiment.sh" /root/scripts/run_local_util_adapt_experiment.sh
  copy_file "${VM_SCRIPTS}/local_util_adapt_controller.py" /root/scripts/local_util_adapt_controller.py
  copy_file "${VM_GUEST}/run_all_workloads_phys8g_ours_toggle_w5_guest.sh" /root/scripts/run_all_workloads_phys8g_ours_toggle_w5_guest.sh
  remote "chmod +x /root/scripts/run_local_util_adapt_experiment.sh /root/scripts/local_util_adapt_controller.py /root/scripts/run_all_workloads_phys8g_ours_toggle_w5_guest.sh"

  copy_file_if_missing "${BENCH}/gapbs/pr" /root/pr
  copy_file_if_missing "${BENCH}/gapbs/bc" /root/bc
  copy_file_if_missing "${BENCH}/gapbs/benchmark/graphs/kron_g28.sg" /root/gapbs_graphs/kron_g28.sg

  copy_file_if_missing "${BENCH}/NPB3.4.3/NPB3.4-OMP/bin/ft.H.x" /root/benchmark/NPB3.4.3/NPB3.4-OMP/bin/ft.H.x
  copy_file_if_missing "${BENCH}/NPB3.4.3/NPB3.4-OMP/bin/lu.H.x" /root/benchmark/NPB3.4.3/NPB3.4-OMP/bin/lu.H.x
  copy_file_if_missing "${BENCH}/NPB3.4.3/NPB3.4-OMP/bin/sp.H.x" /root/benchmark/NPB3.4.3/NPB3.4-OMP/bin/sp.H.x
  remote "chmod +x /root/benchmark/NPB3.4.3/NPB3.4-OMP/bin/ft.H.x /root/benchmark/NPB3.4.3/NPB3.4-OMP/bin/lu.H.x /root/benchmark/NPB3.4.3/NPB3.4-OMP/bin/sp.H.x"

  copy_file_if_missing "${BENCH}/vmitosis-workloads/bin/bench_gups_mt" /root/benchmark/vmitosis-workloads/bin/bench_gups_mt
  copy_file_if_missing "${BENCH}/vmitosis-workloads/bin/bench_graph500_mt" /root/benchmark/vmitosis-workloads/bin/bench_graph500_mt
  copy_file_if_missing "${BENCH}/vmitosis-workloads/bin/bench_btree_mt" /root/benchmark/vmitosis-workloads/bin/bench_btree_mt
  remote "chmod +x /root/benchmark/vmitosis-workloads/bin/bench_gups_mt /root/benchmark/vmitosis-workloads/bin/bench_graph500_mt /root/benchmark/vmitosis-workloads/bin/bench_btree_mt"

  copy_file_if_missing "${BENCH}/XSBench/openmp-threading/XSBench" /root/benchmark/XSBench/openmp-threading/XSBench
  remote "chmod +x /root/benchmark/XSBench/openmp-threading/XSBench"

  copy_file_if_missing "${BENCH}/liblinear-multicore-2.47/train" /root/benchmark/liblinear-multicore-2.47/train
  copy_file_if_missing "${BENCH}/liblinear-multicore-2.47/datasets/kdd12" /root/benchmark/liblinear-multicore-2.47/datasets/kdd12
  remote "chmod +x /root/benchmark/liblinear-multicore-2.47/train"

  copy_dir_if_missing "${BENCH}/silo/out-perf.masstree" /root/benchmark/silo/out-perf.masstree/benchmarks/dbtest /root/benchmark/silo
  copy_file_if_missing "${BENCH}/silo/third-party/lz4/liblz4.so" /usr/local/lib/silo-deps/liblz4.so

  for lib in \
    /lib/x86_64-linux-gnu/libgfortran.so.5 \
    /lib/x86_64-linux-gnu/libquadmath.so.0 \
    /lib/x86_64-linux-gnu/libgomp.so.1 \
    /lib/x86_64-linux-gnu/libjemalloc.so.2 \
    /lib/x86_64-linux-gnu/libdb_cxx-5.3.so; do
    if [[ -e "${lib}" ]]; then
      copy_file_if_missing "${lib}" "/usr/local/lib/iccd-deps/$(basename "${lib}")"
    fi
  done
  remote "printf '%s\n%s\n' /usr/local/lib/iccd-deps /usr/local/lib/silo-deps > /etc/ld.so.conf.d/iccd-exp-deps.conf && ldconfig"

  remote "df -h /; ls -lh /root/pr /root/bc /root/gapbs_graphs/kron_g28.sg /root/benchmark/liblinear-multicore-2.47/datasets/kdd12 2>/dev/null || true" \
    > "${EXP}/notes/guest-stage-state.txt"
}

mkdir -p "${EXP}/notes" "${EXP}/guest-results"
stop_vm

"${LAUNCH}" \
  --kernel-image "${KERNEL}" \
  --initrd "${INITRD}" \
  --rootfs "${ROOTFS}" \
  --rootfs-format raw \
  --qemu-bin "${QEMU}" \
  --ssh-forward-port "${PORT}" \
  --memory "${TOTAL_GB}G" \
  --cpus 32 \
  --host-cpus 0-31 \
  --numa-node0-cpus 0-31 \
  --numa-node0-mem "${NODE0_GB}G" \
  --numa-node1-mem "${NODE1_GB}G" \
  --numa-node0-host-nodes 0 \
  --numa-node1-host-nodes 2 \
  --numa-mem-policy bind \
  --numa-prealloc \
  --name "${VM_NAME}" \
  > "${EXP}/notes/qemu-launch.log" 2>&1 &
launcher_pid=$!

wait_ssh
remote 'date -u +%Y-%m-%dT%H:%M:%SZ; uname -a; numactl -H; printf "mglru="; cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null || true' \
  > "${EXP}/notes/guest-before-stage.txt"
stage_guest

remote 'OUTROOT=/root/phys8g-allworkloads-ours-toggle-w5 WORKLOADS="silo liblinear FT LU SP gups graph500 btree xsbench" TIMEOUT_SEC=3600 /root/scripts/run_all_workloads_phys8g_ours_toggle_w5_guest.sh' \
  > "${EXP}/notes/guest-run.log" 2>&1

rm -rf "${EXP}/guest-results/phys8g-allworkloads-ours-toggle-w5"
"${SCP_BASE[@]}" -r root@127.0.0.1:/root/phys8g-allworkloads-ours-toggle-w5 "${EXP}/guest-results/" >/dev/null
remote 'sync' >/dev/null 2>&1 || true
stop_vm
wait "${launcher_pid}" 2>/dev/null || true
