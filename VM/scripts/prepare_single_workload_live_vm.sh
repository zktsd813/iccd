#!/usr/bin/env bash
set -euo pipefail

EXP_NAME="${EXP_NAME:-20260522-single-workload-live-placement}"
EXP_DIR="/Serverless/iccd/experiments/${EXP_NAME}"
PORT="${PORT:-10030}"
VM_NAME="${VM_NAME:-iccd-single-live-placement}"
ROOTFS_BASE="${ROOTFS_BASE:-/Serverless/iccd/experiments/20260522-gapbs-capacity-off-rerun/qemu-logs/ubuntu-overlay.qcow2}"
OVERLAY="${OVERLAY:-${EXP_DIR}/qemu-logs/ubuntu-overlay.qcow2}"
KERNEL_IMAGE="${KERNEL_IMAGE:-/Serverless/iccd/linux-build-mt/arch/x86/boot/bzImage}"
INITRD_IMAGE="${INITRD_IMAGE:-/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified.img}"
GUEST_SCRIPT="${GUEST_SCRIPT:-/Serverless/iccd/scripts/run_single_workload_live_placement_guest.sh}"
MEMORY="${MEMORY:-96G}"
CPUS="${CPUS:-32}"
HOST_CPUS="${HOST_CPUS:-0-31}"
NUMA_NODE0_CPUS="${NUMA_NODE0_CPUS:-0-31}"
NUMA_NODE0_MEM="${NUMA_NODE0_MEM:-32G}"
NUMA_NODE1_MEM="${NUMA_NODE1_MEM:-64G}"
NUMA_NODE0_HOST_NODES="${NUMA_NODE0_HOST_NODES:-0}"
NUMA_NODE1_HOST_NODES="${NUMA_NODE1_HOST_NODES:-2}"
LAUNCH_ONLY="${LAUNCH_ONLY:-0}"

mkdir -p "${EXP_DIR}"/{guest,summaries,graphs,notes,qemu-logs,guest-results}
cp "${GUEST_SCRIPT}" "${EXP_DIR}/guest/"

if [[ ! -f "${ROOTFS_BASE}" ]]; then
  echo "missing ROOTFS_BASE=${ROOTFS_BASE}" >&2
  exit 1
fi
if [[ ! -f "${KERNEL_IMAGE}" ]]; then
  echo "missing KERNEL_IMAGE=${KERNEL_IMAGE}" >&2
  exit 1
fi
if [[ ! -f "${INITRD_IMAGE}" ]]; then
  echo "missing INITRD_IMAGE=${INITRD_IMAGE}" >&2
  exit 1
fi

if [[ ! -f "${OVERLAY}" ]]; then
  qemu-img create -f qcow2 -F qcow2 -b "${ROOTFS_BASE}" "${OVERLAY}"
fi

cat > "${EXP_DIR}/notes/launch.env" <<EOF
EXP_NAME=${EXP_NAME}
EXP_DIR=${EXP_DIR}
PORT=${PORT}
VM_NAME=${VM_NAME}
ROOTFS_BASE=${ROOTFS_BASE}
OVERLAY=${OVERLAY}
KERNEL_IMAGE=${KERNEL_IMAGE}
INITRD_IMAGE=${INITRD_IMAGE}
GUEST_SCRIPT=${GUEST_SCRIPT}
MEMORY=${MEMORY}
CPUS=${CPUS}
HOST_CPUS=${HOST_CPUS}
NUMA_NODE0_CPUS=${NUMA_NODE0_CPUS}
NUMA_NODE0_MEM=${NUMA_NODE0_MEM}
NUMA_NODE1_MEM=${NUMA_NODE1_MEM}
NUMA_NODE0_HOST_NODES=${NUMA_NODE0_HOST_NODES}
NUMA_NODE1_HOST_NODES=${NUMA_NODE1_HOST_NODES}
EOF

cat > "${EXP_DIR}/notes/run-after-ssh.txt" <<EOF
scp -P ${PORT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \\
  ${GUEST_SCRIPT} root@127.0.0.1:/root/scripts/run_single_workload_live_placement_guest.sh

ssh -p ${PORT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1 \\
  'chmod +x /root/scripts/run_single_workload_live_placement_guest.sh && \\
   OUTROOT=/root/single-live-placement \\
   WORKLOADS="pr bc FT LU SP gups graph500 btree xsbench silo" \\
   CAPS="8g:2097152 16g:4194304" \\
   TRIALS=8 OMP_THREADS=32 TIMEOUT_SEC=1800 SAMPLE_SEC=1 \\
   /root/scripts/run_single_workload_live_placement_guest.sh'

scp -r -P ${PORT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \\
  root@127.0.0.1:/root/single-live-placement ${EXP_DIR}/guest-results/
EOF

echo "prepared experiment directory: ${EXP_DIR}"
echo "overlay: ${OVERLAY}"
echo "ssh port: ${PORT}"

if [[ "${LAUNCH_ONLY}" == "0" ]]; then
  echo "set LAUNCH_ONLY=1 to skip VM launch"
fi

if [[ "${LAUNCH_ONLY}" == "1" ]]; then
  exit 0
fi

/Serverless/Migration-friendly/scripts/kernel/launch_kernel_qemu.sh \
  --name "${VM_NAME}" \
  --rootfs "${OVERLAY}" \
  --rootfs-format qcow2 \
  --kernel-dir /Serverless/iccd/linux \
  --kernel-image "${KERNEL_IMAGE}" \
  --initrd "${INITRD_IMAGE}" \
  --ssh-forward-port "${PORT}" \
  --memory "${MEMORY}" \
  --cpus "${CPUS}" \
  --host-cpus "${HOST_CPUS}" \
  --numa-node0-cpus "${NUMA_NODE0_CPUS}" \
  --numa-node0-mem "${NUMA_NODE0_MEM}" \
  --numa-node1-mem "${NUMA_NODE1_MEM}" \
  --numa-node0-host-nodes "${NUMA_NODE0_HOST_NODES}" \
  --numa-node1-host-nodes "${NUMA_NODE1_HOST_NODES}" \
  --numa-mem-policy bind \
  --numa-prealloc
