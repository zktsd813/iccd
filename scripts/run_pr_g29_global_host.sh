#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/Serverless/iccd-git}"
ICCD_REPO_ROOT="${ICCD_REPO_ROOT:-${REPO_ROOT}}"
ICCD_DEFAULTS="${ICCD_DEFAULTS:-${REPO_ROOT}/scripts/iccd_experiment_defaults.sh}"
if [[ -r "${ICCD_DEFAULTS}" ]]; then
  # shellcheck source=scripts/iccd_experiment_defaults.sh
  source "${ICCD_DEFAULTS}"
fi
VMCTL="${VMCTL:-${ICCD_VMCTL:-${REPO_ROOT}/VM/vmctl.sh}}"
KERNEL="${KERNEL:-${ICCD_KERNEL:-${REPO_ROOT}/linux-global-build/arch/x86/boot/bzImage}}"
BASE_ROOTFS="${BASE_ROOTFS:-/Serverless/Migration-friendly/qemu/build/ubuntu.img}"
BASE_ROOTFS_FORMAT="${BASE_ROOTFS_FORMAT:-raw}"
SSH_KEY="${SSH_KEY:-/Serverless/Migration-friendly/qemu/tests/keys/id_rsa}"
EXP_ROOT="${EXP_ROOT:-${REPO_ROOT}/experiments/20260601-pr-g29-global}"
HOST_CPUS="${HOST_CPUS:-${ICCD_HOST_CPUS:-0-31}}"
GUEST_CPUS="${GUEST_CPUS:-${ICCD_GUEST_CPUS:-32}}"
GUEST_NODE0_CPUS="${GUEST_NODE0_CPUS:-${ICCD_GUEST_NODE0_CPUS:-0-31}}"
LOCAL16_FAST_MEM="${LOCAL16_FAST_MEM:-16G}"
LOCAL16_SLOW_MEM="${LOCAL16_SLOW_MEM:-176G}"
ALLFAST_FAST_MEM="${ALLFAST_FAST_MEM:-160G}"
ALLFAST_SLOW_MEM="${ALLFAST_SLOW_MEM:-4G}"
FAST_HOST_NODE="${FAST_HOST_NODE:-${ICCD_FAST_HOST_NODE:-0}}"
SLOW_HOST_NODE="${SLOW_HOST_NODE:-${ICCD_SLOW_HOST_NODE:-2}}"
ALLFAST_HOST_NODE="${ALLFAST_HOST_NODE:-0-1}"
SLOW_MEMORY_MODE="${SLOW_MEMORY_MODE:-${ICCD_SLOW_MEMORY_MODE:-host-cxl}}"
HMAT_FAST_LATENCY_NS="${HMAT_FAST_LATENCY_NS:-${ICCD_HMAT_FAST_LATENCY_NS:-80}}"
HMAT_SLOW_LATENCY_NS="${HMAT_SLOW_LATENCY_NS:-${ICCD_HMAT_SLOW_LATENCY_NS:-250}}"
HMAT_FAST_BANDWIDTH="${HMAT_FAST_BANDWIDTH:-${ICCD_HMAT_FAST_BANDWIDTH:-40000M}}"
HMAT_SLOW_BANDWIDTH="${HMAT_SLOW_BANDWIDTH:-${ICCD_HMAT_SLOW_BANDWIDTH:-10000M}}"
LOCAL16_PORT="${LOCAL16_PORT:-10092}"
ALLFAST_PORT="${ALLFAST_PORT:-10093}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"
GRAPH_SCALE="${GRAPH_SCALE:-29}"
PR_ITERATIONS="${PR_ITERATIONS:-20}"
PR_TOLERANCE="${PR_TOLERANCE:-1e-4}"
PR_TRIALS="${PR_TRIALS:-1}"
OMP_THREADS="${OMP_THREADS:-32}"
TIMEOUT_SEC="${TIMEOUT_SEC:-21600}"
RUN_LOCAL16="${RUN_LOCAL16:-1}"
RUN_ALLFAST="${RUN_ALLFAST:-1}"

log() {
  printf '[pr-g29-host] %s\n' "$*" >&2
}

mkdir -p "${EXP_ROOT}"/{images,host-logs,guest-results,summaries,notes}

create_overlay() {
  local output="$1"
  if [[ -e "${output}" ]]; then
    log "reusing overlay ${output}"
    return 0
  fi
  "${VMCTL}" create-image \
    --overlay-from "${BASE_ROOTFS}" \
    --backing-format "${BASE_ROOTFS_FORMAT}" \
    --output "${output}"
}

boot_vm() {
  local name="$1" port="$2" overlay="$3" fast_host="$4" slow_host="$5" fast_mem="$6" slow_mem="$7"
  local -a args=(
    boot
    --name "${name}"
    --kernel "${KERNEL}"
    --rootfs "${overlay}"
    --rootfs-format qcow2
    --root-device /dev/vda2
    --ssh-key "${SSH_KEY}"
    --ssh-port "${port}"
    --host-cpus "${HOST_CPUS}"
    --guest-cpus "${GUEST_CPUS}"
    --guest-node0-cpus "${GUEST_NODE0_CPUS}"
    --fast-host-node "${fast_host}"
    --slow-host-node "${slow_host}"
    --fast-mem "${fast_mem}"
    --slow-mem "${slow_mem}"
    --slow-memory-mode "${SLOW_MEMORY_MODE}"
    --accel kvm
  )
  args+=(--hmat-fast-latency-ns "${HMAT_FAST_LATENCY_NS}")
  args+=(--hmat-slow-latency-ns "${HMAT_SLOW_LATENCY_NS}")
  args+=(--hmat-fast-bandwidth "${HMAT_FAST_BANDWIDTH}")
  args+=(--hmat-slow-bandwidth "${HMAT_SLOW_BANDWIDTH}")
  [[ -z "${CXL_FMW_SIZE:-}" ]] || args+=(--cxl-fmw-size "${CXL_FMW_SIZE}")
  "${VMCTL}" "${args[@]}"
}

ssh_vm() {
  local port="$1"
  shift
  "${VMCTL}" ssh --ssh-key "${SSH_KEY}" --ssh-port "${port}" -- "$@"
}

copy_to_vm() {
  local port="$1"
  shift
  "${VMCTL}" copy-to --ssh-key "${SSH_KEY}" --ssh-port "${port}" -- "$@"
}

copy_from_vm() {
  local port="$1"
  shift
  "${VMCTL}" copy-from --ssh-key "${SSH_KEY}" --ssh-port "${port}" -- "$@"
}

run_guest_matrix() {
  local name="$1" port="$2" runs="$3" guest_out="$4"
  local host_out="${EXP_ROOT}/guest-results/${name}"

  SSH_TIMEOUT="${WAIT_TIMEOUT}" "${VMCTL}" wait-ssh --ssh-key "${SSH_KEY}" --ssh-port "${port}"
  "${VMCTL}" verify-placement --name "${name}" --ssh-key "${SSH_KEY}" --ssh-port "${port}" \
    > "${EXP_ROOT}/host-logs/${name}.placement.log" 2>&1 || true
  ssh_vm "${port}" "mkdir -p /root/scripts"
  copy_to_vm "${port}" "${REPO_ROOT}/scripts/run_pr_g29_global_guest.sh" /root/scripts/
  ssh_vm "${port}" "chmod +x /root/scripts/run_pr_g29_global_guest.sh"

  log "running ${name}: ${runs}"
  ssh_vm "${port}" \
    "OUTROOT='${guest_out}' RUNS='${runs}' GRAPH_SCALE='${GRAPH_SCALE}' PR_ITERATIONS='${PR_ITERATIONS}' PR_TOLERANCE='${PR_TOLERANCE}' PR_TRIALS='${PR_TRIALS}' OMP_THREADS='${OMP_THREADS}' TIMEOUT_SEC='${TIMEOUT_SEC}' /root/scripts/run_pr_g29_global_guest.sh" \
    > "${EXP_ROOT}/host-logs/${name}.ssh.log" 2>&1 || true

  rm -rf "${host_out}"
  mkdir -p "$(dirname "${host_out}")"
  copy_from_vm "${port}" "${guest_out}" "${host_out}"
}

run_local16_vm() {
  local name="pr-g29-local16" port="${LOCAL16_PORT}" overlay="${EXP_ROOT}/images/local16.qcow2"
  create_overlay "${overlay}"
  boot_vm "${name}" "${port}" "${overlay}" "${FAST_HOST_NODE}" "${SLOW_HOST_NODE}" "${LOCAL16_FAST_MEM}" "${LOCAL16_SLOW_MEM}"
  run_guest_matrix "${name}" "${port}" "migration_off migration_on all_slow" "/root/pr-g29-local16"
  "${VMCTL}" stop --name "${name}" || true
}

run_allfast_vm() {
  local name="pr-g29-allfast" port="${ALLFAST_PORT}" overlay="${EXP_ROOT}/images/allfast.qcow2"
  create_overlay "${overlay}"
  boot_vm "${name}" "${port}" "${overlay}" "${ALLFAST_HOST_NODE}" "${SLOW_HOST_NODE}" "${ALLFAST_FAST_MEM}" "${ALLFAST_SLOW_MEM}"
  run_guest_matrix "${name}" "${port}" "all_fast" "/root/pr-g29-allfast"
  "${VMCTL}" stop --name "${name}" || true
}

main() {
  [[ -x "${VMCTL}" ]] || { log "missing vmctl: ${VMCTL}"; exit 1; }
  [[ -f "${KERNEL}" ]] || { log "missing kernel: ${KERNEL}"; exit 1; }
  [[ -f "${BASE_ROOTFS}" ]] || { log "missing rootfs: ${BASE_ROOTFS}"; exit 1; }
  [[ -f "${SSH_KEY}" ]] || { log "missing SSH key: ${SSH_KEY}"; exit 1; }

  {
    printf 'date_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'required_protocol_doc=%s\n' "${ICCD_REQUIRED_PROTOCOL_DOC:-}"
    printf 'repo_root=%s\n' "${REPO_ROOT}"
    printf 'kernel=%s\n' "${KERNEL}"
    printf 'base_rootfs=%s\n' "${BASE_ROOTFS}"
    printf 'host_cpus=%s\n' "${HOST_CPUS}"
    printf 'guest_cpus=%s\n' "${GUEST_CPUS}"
    printf 'local16_fast_mem=%s\n' "${LOCAL16_FAST_MEM}"
    printf 'local16_slow_mem=%s\n' "${LOCAL16_SLOW_MEM}"
    printf 'allfast_fast_mem=%s\n' "${ALLFAST_FAST_MEM}"
    printf 'allfast_slow_mem=%s\n' "${ALLFAST_SLOW_MEM}"
    printf 'fast_host_node=%s\n' "${FAST_HOST_NODE}"
    printf 'slow_host_node=%s\n' "${SLOW_HOST_NODE}"
    printf 'allfast_host_node=%s\n' "${ALLFAST_HOST_NODE}"
    printf 'slow_memory_mode=%s\n' "${SLOW_MEMORY_MODE}"
    printf 'hmat_fast_latency_ns=%s\n' "${HMAT_FAST_LATENCY_NS}"
    printf 'hmat_slow_latency_ns=%s\n' "${HMAT_SLOW_LATENCY_NS}"
    printf 'hmat_fast_bandwidth=%s\n' "${HMAT_FAST_BANDWIDTH}"
    printf 'hmat_slow_bandwidth=%s\n' "${HMAT_SLOW_BANDWIDTH}"
    [[ -z "${CXL_FMW_SIZE:-}" ]] || printf 'cxl_fmw_size=%s\n' "${CXL_FMW_SIZE}"
    numactl -H
  } > "${EXP_ROOT}/host-logs/host-config.log"

  if [[ "${RUN_LOCAL16}" == "1" ]]; then
    run_local16_vm
  fi
  if [[ "${RUN_ALLFAST}" == "1" ]]; then
    run_allfast_vm
  fi
}

main "$@"
