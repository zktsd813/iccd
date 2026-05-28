#!/usr/bin/env bash
set -euo pipefail

EXP=/Serverless/iccd/experiments/20260528-physlimit-gups-ours-w5-8-16-32
LAUNCH=/Serverless/Migration-friendly/scripts/kernel/launch_kernel_qemu.sh
KERNEL=/Serverless/iccd/linux-build-mt/arch/x86/boot/bzImage
INITRD=/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified.img
ROOTFS=/Serverless/Migration-friendly/qemu/build/ubuntu.img
QEMU=/Serverless/Migration-friendly/qemu/build/qemu-system-x86_64
RUN_SCRIPT=/Serverless/iccd/scripts/run_local_util_adapt_experiment.sh
CONTROLLER=/Serverless/iccd/scripts/local_util_adapt_controller.py
GUPS=/Serverless/benchmark/vmitosis-workloads/bin/bench_gups_mt
TOTAL_GB=168

SSH_BASE=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
SCP_BASE=(scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

wait_ssh() {
  local port="$1"
  local deadline=$((SECONDS + 360))
  until "${SSH_BASE[@]}" -p "${port}" root@127.0.0.1 'true' >/dev/null 2>&1; do
    if (( SECONDS > deadline )); then
      echo "ssh did not come up on port ${port}" >&2
      return 1
    fi
    sleep 2
  done
}

stop_vm() {
  local name="$1"
  local pids
  pids="$(pgrep -f "qemu-system-x86_64.*-name ${name}" || true)"
  if [[ -n "${pids}" ]]; then
    kill ${pids} 2>/dev/null || true
    sleep 2
  fi
  pids="$(pgrep -f "qemu-system-x86_64.*-name ${name}" || true)"
  if [[ -n "${pids}" ]]; then
    kill -9 ${pids} 2>/dev/null || true
  fi
}

run_one() {
  local cap_gb="$1"
  local port="$2"
  local n1_gb=$((TOTAL_GB - cap_gb))
  local name="iccd-phys-gups-ours-w5-${cap_gb}g"
  local host_dir="${EXP}/guest-results/${cap_gb}g"
  local note_dir="${EXP}/notes/${cap_gb}g"
  local guest_dir="/root/physlimit-gups-ours-w5/${cap_gb}g"

  mkdir -p "${host_dir}" "${note_dir}"
  stop_vm "${name}"

  echo "== ${cap_gb}G start $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
  "${LAUNCH}" \
    --kernel-image "${KERNEL}" \
    --initrd "${INITRD}" \
    --rootfs "${ROOTFS}" \
    --rootfs-format raw \
    --qemu-bin "${QEMU}" \
    --ssh-forward-port "${port}" \
    --memory "${TOTAL_GB}G" \
    --cpus 32 \
    --host-cpus 0-31 \
    --numa-node0-cpus 0-31 \
    --numa-node0-mem "${cap_gb}G" \
    --numa-node1-mem "${n1_gb}G" \
    --numa-node0-host-nodes 0 \
    --numa-node1-host-nodes 2 \
    --numa-mem-policy bind \
    --numa-prealloc \
    --name "${name}" \
    > "${note_dir}/qemu-launch.log" 2>&1 &
  local launcher_pid=$!

  wait_ssh "${port}"

  "${SSH_BASE[@]}" -p "${port}" root@127.0.0.1 'mkdir -p /root/scripts /root/benchmark/vmitosis-workloads/bin /root/physlimit-gups-ours-w5' >/dev/null
  "${SCP_BASE[@]}" -P "${port}" "${RUN_SCRIPT}" "${CONTROLLER}" root@127.0.0.1:/root/scripts/ >/dev/null
  "${SCP_BASE[@]}" -P "${port}" "${GUPS}" root@127.0.0.1:/root/benchmark/vmitosis-workloads/bin/ >/dev/null
  "${SSH_BASE[@]}" -p "${port}" root@127.0.0.1 'chmod +x /root/scripts/run_local_util_adapt_experiment.sh /root/scripts/local_util_adapt_controller.py /root/benchmark/vmitosis-workloads/bin/bench_gups_mt' >/dev/null

  "${SSH_BASE[@]}" -p "${port}" root@127.0.0.1 \
    'set -e;
     {
       date -u +%Y-%m-%dT%H:%M:%SZ;
       uname -a;
       cat /proc/cmdline;
       numactl -H;
       printf "mglru="; cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null || true;
       printf "global_numa_balancing="; cat /proc/sys/kernel/numa_balancing 2>/dev/null || true;
       printf "global_demotion_enabled="; cat /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true;
       printf "global_demotion_target="; cat /sys/kernel/mm/numa/demotion_target 2>/dev/null || true;
     }' > "${note_dir}/guest-before-run.txt"

  "${SSH_BASE[@]}" -p "${port}" root@127.0.0.1 \
    "/root/scripts/run_local_util_adapt_experiment.sh \
      --outdir ${guest_dir}/ours_w5 \
      --run-id gups_phys${cap_gb}g_ours_w5 \
      --policy ours \
      --capacity-pages 0 \
      --global-numa-balancing 0 \
      --global-demotion-enabled 1 \
      --global-demotion-target '0 1' \
      --node-balancing 2 \
      --kswapd-demotion 1 \
      --local-fault-rate 10 \
      --local-fault-hit-ms 2000 \
      --window-sec 5 \
      --threshold-pct 80 \
      --consecutive 3 \
      --remote-threshold-pct 20 \
      --min-pte-updates 1 \
      --min-hint-faults 1 \
      --eval-lag prev \
      --cpuset-cpus 0-31 \
      --cpuset-mems 0,1 \
      --mglru 0x0007 \
      --timeout-sec 0 \
      -- /root/benchmark/vmitosis-workloads/bin/bench_gups_mt" \
    > "${note_dir}/guest-run.log" 2>&1

  rm -rf "${host_dir}/ours_w5"
  "${SCP_BASE[@]}" -P "${port}" -r root@127.0.0.1:"${guest_dir}/ours_w5" "${host_dir}/" >/dev/null
  "${SSH_BASE[@]}" -p "${port}" root@127.0.0.1 'sync' >/dev/null 2>&1 || true
  stop_vm "${name}"
  wait "${launcher_pid}" 2>/dev/null || true
  echo "== ${cap_gb}G done $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
}

run_one 8 10058
run_one 16 10059
run_one 32 10060
