#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EXP_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
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
ROOT_DEVICE="${ROOT_DEVICE:-/dev/vda2}"
ROOT_DISK="${ROOT_DISK:-/dev/vda}"
ROOT_PARTITION_NUMBER="${ROOT_PARTITION_NUMBER:-2}"
ROOTFS_VIRTUAL_SIZE="${ROOTFS_VIRTUAL_SIZE:-120G}"
SSH_KEY="${SSH_KEY:-/Serverless/Migration-friendly/qemu/tests/keys/id_rsa}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
HOST="${HOST:-127.0.0.1}"

RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-vm32-local16-32-48}"
RESULTS_ROOT="${RESULTS_ROOT:-${EXP_ROOT}/results}"
RUN_ROOT="${RUN_ROOT:-${RESULTS_ROOT}/${RUN_ID}}"
IMAGES_DIR="${RUN_ROOT}/images"
HOST_LOG_DIR="${RUN_ROOT}/host-logs"
GUEST_RESULTS_DIR="${RUN_ROOT}/guest-results"
SUMMARY_DIR="${RUN_ROOT}/summaries"
VM_RUN_TAG="${VM_RUN_TAG:-$(printf '%s' "${RUN_ID}" | cksum | awk '{print $1}')}"
VM_RUN_DIR_HOST="${VM_RUN_DIR_HOST:-/tmp/vm32-realworld-${VM_RUN_TAG}}"

LOCAL_SIZES_GIB="${LOCAL_SIZES_GIB:-16 32 48}"
CONFIGS="${CONFIGS:-migration_off tiering_0x2 tpp_0x4}"
WORKLOADS="${WORKLOADS:-pr bc gups graph500 btree redis_uniform redis_ycsb_a faster_uniform faster_ycsb_a}"
FAULT_BUCKET_CONTROLLER_DIR="${FAULT_BUCKET_CONTROLLER_DIR:-${REPO_ROOT}/design/fault_bucket_controller}"

HOST_CPUS="${HOST_CPUS:-${ICCD_HOST_CPUS:-0-31}}"
GUEST_CPUS="${GUEST_CPUS:-${ICCD_GUEST_CPUS:-32}}"
GUEST_NODE0_CPUS="${GUEST_NODE0_CPUS:-${ICCD_GUEST_NODE0_CPUS:-0-31}}"
FAST_HOST_NODE="${FAST_HOST_NODE:-${ICCD_FAST_HOST_NODE:-0}}"
SLOW_HOST_NODE="${SLOW_HOST_NODE:-${ICCD_SLOW_HOST_NODE:-2}}"
SLOW_MEMORY_MODE="${SLOW_MEMORY_MODE:-${ICCD_SLOW_MEMORY_MODE:-host-cxl}}"
HMAT_FAST_LATENCY_NS="${HMAT_FAST_LATENCY_NS:-${ICCD_HMAT_FAST_LATENCY_NS:-80}}"
HMAT_SLOW_LATENCY_NS="${HMAT_SLOW_LATENCY_NS:-${ICCD_HMAT_SLOW_LATENCY_NS:-250}}"
HMAT_FAST_BANDWIDTH="${HMAT_FAST_BANDWIDTH:-${ICCD_HMAT_FAST_BANDWIDTH:-40000M}}"
HMAT_SLOW_BANDWIDTH="${HMAT_SLOW_BANDWIDTH:-${ICCD_HMAT_SLOW_BANDWIDTH:-10000M}}"
ALL_LOCAL_FAST_MEM="${ALL_LOCAL_FAST_MEM:-152G}"
ALL_LOCAL_SLOW_MEM="${ALL_LOCAL_SLOW_MEM:-4G}"
ALL_SLOW_FAST_MEM="${ALL_SLOW_FAST_MEM:-4G}"
ALL_SLOW_SLOW_MEM="${ALL_SLOW_SLOW_MEM:-152G}"
MIGRATION_FAST_MEM="${MIGRATION_FAST_MEM:-16G}"
MIGRATION_SLOW_MEM="${MIGRATION_SLOW_MEM:-128G}"
ALL_LOCAL_FAST_HOST_NODE="${ALL_LOCAL_FAST_HOST_NODE:-0}"
ALL_LOCAL_SLOW_HOST_NODE="${ALL_LOCAL_SLOW_HOST_NODE:-${SLOW_HOST_NODE}}"
ALL_SLOW_FAST_HOST_NODE="${ALL_SLOW_FAST_HOST_NODE:-${FAST_HOST_NODE}}"
ALL_SLOW_SLOW_HOST_NODE="${ALL_SLOW_SLOW_HOST_NODE:-${SLOW_HOST_NODE}}"
MIGRATION_FAST_HOST_NODE="${MIGRATION_FAST_HOST_NODE:-${FAST_HOST_NODE}}"
MIGRATION_SLOW_HOST_NODE="${MIGRATION_SLOW_HOST_NODE:-${SLOW_HOST_NODE}}"

MIGRATION_OFF_PORT="${MIGRATION_OFF_PORT:-10160}"
MIGRATION_ON_PORT="${MIGRATION_ON_PORT:-10161}"
ALL_LOCAL_PORT="${ALL_LOCAL_PORT:-10162}"
ALL_SLOW_PORT="${ALL_SLOW_PORT:-10163}"
CONTROLLER_PORT="${CONTROLLER_PORT:-10165}"

BENCHMARK_DIR="${BENCHMARK_DIR:-/Serverless/benchmark}"
TIMEOUT_SEC="${TIMEOUT_SEC:-21600}"
SAMPLE_INTERVAL_SEC="${SAMPLE_INTERVAL_SEC:-5}"
OMP_THREADS="${OMP_THREADS:-32}"
MGLRU_ENABLED="${MGLRU_ENABLED:-0x0007}"
NUMA_SCAN_SIZE_MB="${NUMA_SCAN_SIZE_MB:-}"
NUMA_SCAN_PERIOD_MIN_MS="${NUMA_SCAN_PERIOD_MIN_MS:-}"
LOCAL_FAULT_RATE="${LOCAL_FAULT_RATE:-}"
REMOTE_FAULT_RATE="${REMOTE_FAULT_RATE:-}"
LOCAL_FAULT_SCAN_PERIOD_MS="${LOCAL_FAULT_SCAN_PERIOD_MS:-}"
LOCAL_FAULT_SCAN_SIZE_MB="${LOCAL_FAULT_SCAN_SIZE_MB:-}"
REMOTE_FAULT_SCAN_PERIOD_MS="${REMOTE_FAULT_SCAN_PERIOD_MS:-}"
REMOTE_FAULT_SCAN_SIZE_MB="${REMOTE_FAULT_SCAN_SIZE_MB:-}"
THP_MODE="${THP_MODE:-}"
THP_DEFRAG="${THP_DEFRAG:-${THP_MODE}}"
REALWORLD_SIZE_PROFILE="${REALWORLD_SIZE_PROFILE:-rss60}"
VERIFY_REQUIRED_STATE="${VERIFY_REQUIRED_STATE:-1}"
TRACE_BC_TRIAL_PROMOTIONS="${TRACE_BC_TRIAL_PROMOTIONS:-0}"
FORBID_HOST_NODE1="${FORBID_HOST_NODE1:-1}"
CONTROLLER_WINDOW_SEC="${CONTROLLER_WINDOW_SEC:-5}"
CONTROLLER_LOCAL_RATE="${CONTROLLER_LOCAL_RATE:-5}"
CONTROLLER_REMOTE_RATE="${CONTROLLER_REMOTE_RATE:-5}"
CONTROLLER_LOCAL_FAULT_SCAN_PERIOD_MS="${CONTROLLER_LOCAL_FAULT_SCAN_PERIOD_MS:-1000}"
CONTROLLER_LOCAL_FAULT_SCAN_SIZE_MB="${CONTROLLER_LOCAL_FAULT_SCAN_SIZE_MB:-256}"
CONTROLLER_REMOTE_FAULT_SCAN_PERIOD_MS="${CONTROLLER_REMOTE_FAULT_SCAN_PERIOD_MS:-${CONTROLLER_LOCAL_FAULT_SCAN_PERIOD_MS}}"
CONTROLLER_REMOTE_FAULT_SCAN_SIZE_MB="${CONTROLLER_REMOTE_FAULT_SCAN_SIZE_MB:-${CONTROLLER_LOCAL_FAULT_SCAN_SIZE_MB}}"
CONTROLLER_MIN_LOCAL_PAGES="${CONTROLLER_MIN_LOCAL_PAGES:-1024}"
CONTROLLER_MIN_REMOTE_PAGES="${CONTROLLER_MIN_REMOTE_PAGES:-1024}"
CONTROLLER_CONSECUTIVE_EFFECTIVE="${CONTROLLER_CONSECUTIVE_EFFECTIVE:-2}"
CONTROLLER_CONSECUTIVE_NO_IMPROVE="${CONTROLLER_CONSECUTIVE_NO_IMPROVE:-2}"
CONTROLLER_RESTART_REMOTE_SHARE_THRESHOLD="${CONTROLLER_RESTART_REMOTE_SHARE_THRESHOLD:-1.2}"
CONTROLLER_CONSECUTIVE_RESTART="${CONTROLLER_CONSECUTIVE_RESTART:-2}"
CONTROLLER_RESTART_GRACE_WINDOWS="${CONTROLLER_RESTART_GRACE_WINDOWS:-1}"
CONTROLLER_NUMA_BALANCING_ON="${CONTROLLER_NUMA_BALANCING_ON:-2}"
CONTROLLER_NUMA_BALANCING_OFF="${CONTROLLER_NUMA_BALANCING_OFF:-0}"
RESUME="${RESUME:-1}"
CLEAN_STAGE="${CLEAN_STAGE:-0}"
CLEAN_SCRIPTS="${CLEAN_SCRIPTS:-1}"
STAGE_WORKLOADS="${STAGE_WORKLOADS:-1}"
SSH_RETRY_ATTEMPTS="${SSH_RETRY_ATTEMPTS:-30}"
SSH_RETRY_DELAY_SEC="${SSH_RETRY_DELAY_SEC:-10}"
SSH_READY_ATTEMPTS="${SSH_READY_ATTEMPTS:-30}"
SSH_READY_DELAY_SEC="${SSH_READY_DELAY_SEC:-10}"
POST_STAGE_SSH_SETTLE_SEC="${POST_STAGE_SSH_SETTLE_SEC:-30}"
REBOOT_AFTER_STAGE="${REBOOT_AFTER_STAGE:-1}"
STOP_VM_ON_SUCCESS="${STOP_VM_ON_SUCCESS:-1}"
STOP_VM_ON_FAILURE="${STOP_VM_ON_FAILURE:-1}"
STOP_VM_ON_EXIT="${STOP_VM_ON_EXIT:-1}"
DRY_RUN="${DRY_RUN:-0}"

PR_ITERATIONS="${PR_ITERATIONS:-20}"
PR_TOLERANCE="${PR_TOLERANCE:-1e-4}"
PR_TRIALS="${PR_TRIALS:-8}"
BC_ITERATIONS="${BC_ITERATIONS:-1}"
BC_TRIALS="${BC_TRIALS:-8}"
GAPBS_GRAPH_SCALE="${GAPBS_GRAPH_SCALE:-29}"
GRAPH=""
DROP_GUEST_CACHES="${DROP_GUEST_CACHES:-1}"
COMPACT_GUEST_MEMORY="${COMPACT_GUEST_MEMORY:-1}"
GUPS_MEMORY_GB="${GUPS_MEMORY_GB:-64}"
GRAPH500_SCALE="${GRAPH500_SCALE:-28}"
XSBENCH_GRID="${XSBENCH_GRID:-130000}"
XSBENCH_PARTICLES="${XSBENCH_PARTICLES:-90000000}"
DELETE_VM_IMAGES="${DELETE_VM_IMAGES:-1}"
DISABLE_SMT="${DISABLE_SMT:-1}"
RESTORE_SMT="${RESTORE_SMT:-1}"
SILO_BIN_HOST="${SILO_BIN_HOST:-${BENCHMARK_DIR}/silo/out-perf.masstree/benchmarks/dbtest}"
SILO_LZ4_HOST="${SILO_LZ4_HOST:-${BENCHMARK_DIR}/silo/third-party/lz4/liblz4.so}"
LIBLINEAR_ROOT_HOST="${LIBLINEAR_ROOT_HOST:-${BENCHMARK_DIR}/liblinear-multicore-2.47}"
LIBLINEAR_DATASET="${LIBLINEAR_DATASET:-kdd12}"
LIBLINEAR_TRAIN_HOST="${LIBLINEAR_TRAIN_HOST:-${LIBLINEAR_ROOT_HOST}/train}"
LIBLINEAR_DATASET_HOST="${LIBLINEAR_DATASET_HOST:-${LIBLINEAR_ROOT_HOST}/datasets/${LIBLINEAR_DATASET}}"

CURRENT_VM_NAME=""
CURRENT_LOCAL_SIZE_GIB=""
CURRENT_LOCAL_LABEL=""
CURRENT_FAST_MEM=""
EXPERIMENT_SCRIPTS_STAGED=0
ORIG_SMT_CONTROL=""
TOTAL_WORKLOAD_CASES=0
CURRENT_PROGRESS_BASE=0

log() {
  printf '[vm32-host] %s\n' "$*" >&2
}

die() {
  printf '[vm32-host] error: %s\n' "$*" >&2
  exit 2
}

vmctl_cmd() {
  VM_RUN_DIR="${VM_RUN_DIR_HOST}" "${VMCTL}" "$@"
}

as_root() {
  if [[ "$(id -u)" == "0" ]]; then
    "$@"
  else
    sudo -n "$@"
  fi
}

read_smt_control() {
  if [[ -r /sys/devices/system/cpu/smt/control ]]; then
    cat /sys/devices/system/cpu/smt/control
  else
    printf 'NA\n'
  fi
}

set_smt_control() {
  local value="$1"
  [[ -w /sys/devices/system/cpu/smt/control || "$(id -u)" != "0" ]] || return 0
  as_root sh -c "printf '%s\n' '$value' > /sys/devices/system/cpu/smt/control"
}

disable_smt_if_requested() {
  [[ "${DISABLE_SMT}" == "1" ]] || return 0
  [[ -r /sys/devices/system/cpu/smt/control ]] || return 0
  ORIG_SMT_CONTROL="$(read_smt_control)"
  if [[ "${ORIG_SMT_CONTROL}" != "off" ]]; then
    log "disable SMT before VM sweep (original=${ORIG_SMT_CONTROL})"
    set_smt_control off
  fi
}

restore_smt_if_requested() {
  [[ "${RESTORE_SMT}" == "1" ]] || return 0
  [[ -n "${ORIG_SMT_CONTROL}" && "${ORIG_SMT_CONTROL}" != "NA" ]] || return 0
  if [[ "$(read_smt_control)" != "${ORIG_SMT_CONTROL}" ]]; then
    log "restore SMT state to ${ORIG_SMT_CONTROL}"
    set_smt_control "${ORIG_SMT_CONTROL}" || true
  fi
}

expand_local_sizes() {
  local item
  for item in "$@"; do
    [[ "${item}" =~ ^[0-9]+$ ]] || die "invalid local size GiB '${item}'"
    printf '%s\n' "${item}"
  done | awk '!seen[$0]++'
}

expand_configs() {
  local item
  for item in "$@"; do
    case "${item}" in
      all|default)
        printf '%s\n' migration_off tiering_0x2 tpp_0x4
        ;;
      migration_off|tiering_0x2|migration_on|tpp_0x4|tpp|all_local|all_slow|controller_0x2)
        printf '%s\n' "${item}"
        ;;
      controller)
        printf '%s\n' controller_0x2
        ;;
      *)
        die "unknown config '${item}'"
        ;;
    esac
  done | awk '!seen[$0]++'
}

expand_numeric_spec() {
  local spec="$1" part start end value
  spec="${spec//,/ }"
  for part in ${spec}; do
    if [[ "${part}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      ((start <= end)) || die "invalid numeric range '${part}'"
      for ((value = start; value <= end; value++)); do
        printf '%s\n' "${value}"
      done
    elif [[ "${part}" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "${part}"
    elif [[ -n "${part}" ]]; then
      die "invalid numeric spec '${spec}'"
    fi
  done
}

host_node_spec_has_node() {
  local spec="$1" want="$2" node
  while read -r node; do
    [[ -n "${node}" ]] || continue
    [[ "${node}" == "${want}" ]] && return 0
  done < <(expand_numeric_spec "${spec}")
  return 1
}

host_cpu_node() {
  local cpu="$1" node_path node_name
  for node_path in /sys/devices/system/cpu/cpu"${cpu}"/node[0-9]*; do
    [[ -e "${node_path}" ]] || continue
    node_name="$(basename -- "${node_path}")"
    printf '%s\n' "${node_name#node}"
    return 0
  done
  return 1
}

host_cpu_spec_has_node() {
  local spec="$1" want="$2" cpu node
  while read -r cpu; do
    [[ -n "${cpu}" ]] || continue
    [[ -d "/sys/devices/system/cpu/cpu${cpu}" ]] || die "host CPU missing: ${cpu}"
    node="$(host_cpu_node "${cpu}")" || die "cannot resolve NUMA node for host CPU ${cpu}"
    [[ "${node}" == "${want}" ]] && return 0
  done < <(expand_numeric_spec "${spec}")
  return 1
}

validate_no_host_node1_use() {
  local config fast_node slow_node
  [[ "${FORBID_HOST_NODE1}" == "1" ]] || return 0

  if host_cpu_spec_has_node "${HOST_CPUS}" 1; then
    die "HOST_CPUS=${HOST_CPUS} includes a CPU from forbidden host node1"
  fi

  while read -r config; do
    [[ -n "${config}" ]] || continue
    fast_node="$(config_fast_host_node "${config}")"
    slow_node="$(config_slow_host_node "${config}")"
    if host_node_spec_has_node "${fast_node}" 1; then
      die "${config} fast host node spec uses forbidden host node1: ${fast_node}"
    fi
    if host_node_spec_has_node "${slow_node}" 1; then
      die "${config} slow host node spec uses forbidden host node1: ${slow_node}"
    fi
  done < <(expand_configs ${CONFIGS})
}

expand_workloads() {
  local item
  for item in "$@"; do
    case "${item}" in
      all|default)
        printf '%s\n' \
          pr bc gups graph500 btree \
          redis_uniform redis_ycsb_a faster_uniform faster_ycsb_a
        ;;
      *)
        printf '%s\n' "${item}"
        ;;
    esac
  done | awk '!seen[$0]++'
}

configs_need_controller() {
  local config
  while read -r config; do
    case "${config}" in
      controller_0x2)
        return 0
        ;;
    esac
  done < <(expand_configs ${CONFIGS})
  return 1
}

workloads_need_gapbs_graph() {
  local workload
  while read -r workload; do
    case "${workload}" in
      pr|bc|gapbs_pr|gapbs_bc|gapbs_bfs|gapbs_cc|gapbs_sssp|bfs|cc|sssp)
        return 0
        ;;
    esac
  done < <(expand_workloads ${WORKLOADS})
  return 1
}

use_gapbs_data_disk() {
  return 1
}

drop_host_page_cache() {
  sync || true
  as_root sh -c 'echo 3 > /proc/sys/vm/drop_caches'
}

mount_gapbs_data_disk_guest() {
  return 0
}

unmount_gapbs_data_disk_guest() {
  return 0
}

config_fast_mem() {
  case "$1" in
    migration_off|migration_on|tiering_0x2|tpp|tpp_0x4|controller_0x2) printf '%s\n' "${CURRENT_FAST_MEM:-${MIGRATION_FAST_MEM}}" ;;
    all_local) printf '%s\n' "${ALL_LOCAL_FAST_MEM}" ;;
    all_slow) printf '%s\n' "${ALL_SLOW_FAST_MEM}" ;;
    *) die "unknown config '$1'" ;;
  esac
}

config_slow_mem() {
  case "$1" in
    migration_off|migration_on|tiering_0x2|tpp|tpp_0x4|controller_0x2) printf '%s\n' "${MIGRATION_SLOW_MEM}" ;;
    all_local) printf '%s\n' "${ALL_LOCAL_SLOW_MEM}" ;;
    all_slow) printf '%s\n' "${ALL_SLOW_SLOW_MEM}" ;;
    *) die "unknown config '$1'" ;;
  esac
}

config_fast_host_node() {
  case "$1" in
    migration_off|migration_on|tiering_0x2|tpp|tpp_0x4|controller_0x2) printf '%s\n' "${MIGRATION_FAST_HOST_NODE}" ;;
    all_local) printf '%s\n' "${ALL_LOCAL_FAST_HOST_NODE}" ;;
    all_slow) printf '%s\n' "${ALL_SLOW_FAST_HOST_NODE}" ;;
    *) die "unknown config '$1'" ;;
  esac
}

config_slow_host_node() {
  case "$1" in
    migration_off|migration_on|tiering_0x2|tpp|tpp_0x4|controller_0x2) printf '%s\n' "${MIGRATION_SLOW_HOST_NODE}" ;;
    all_local) printf '%s\n' "${ALL_LOCAL_SLOW_HOST_NODE}" ;;
    all_slow) printf '%s\n' "${ALL_SLOW_SLOW_HOST_NODE}" ;;
    *) die "unknown config '$1'" ;;
  esac
}

config_port() {
  case "$1" in
    migration_off) printf '%s\n' "${MIGRATION_OFF_PORT}" ;;
    migration_on|tiering_0x2) printf '%s\n' "${MIGRATION_ON_PORT}" ;;
    tpp|tpp_0x4) printf '%s\n' "${TPP_PORT:-10164}" ;;
    controller_0x2) printf '%s\n' "${CONTROLLER_PORT}" ;;
    all_local) printf '%s\n' "${ALL_LOCAL_PORT}" ;;
    all_slow) printf '%s\n' "${ALL_SLOW_PORT}" ;;
    *) die "unknown config '$1'" ;;
  esac
}

config_numa_balancing() {
  case "$1" in
    migration_on|tiering_0x2|controller_0x2) printf '2\n' ;;
    tpp|tpp_0x4) printf '4\n' ;;
    all_local|all_slow|migration_off) printf '0\n' ;;
    *) die "unknown config '$1'" ;;
  esac
}

config_placement() {
  case "$1" in
    all_local) printf 'numactl --cpunodebind=0 --membind=0\n' ;;
    all_slow) printf 'numactl --cpunodebind=0 --membind=1\n' ;;
    migration_off|migration_on|tiering_0x2|tpp|tpp_0x4|controller_0x2) printf 'numactl --cpunodebind=0\n' ;;
    *) die "unknown config '$1'" ;;
  esac
}

cleanup_current_vm() {
  if [[ -n "${CURRENT_VM_NAME}" && "${STOP_VM_ON_EXIT}" == "1" && -x "${VMCTL}" ]]; then
    log "cleanup stop ${CURRENT_VM_NAME}"
    vmctl_cmd stop --name "${CURRENT_VM_NAME}" >/dev/null 2>&1 || true
  fi
}

cleanup_host_state() {
  cleanup_current_vm
  restore_smt_if_requested
}
trap cleanup_host_state EXIT

print_dry_run() {
  local -a config_list=("$@")
  local -a workload_list=()
  local -a local_size_list=()
  mapfile -t workload_list < <(expand_workloads ${WORKLOADS})
  mapfile -t local_size_list < <(expand_local_sizes ${LOCAL_SIZES_GIB})

  cat <<EOF
Experiment root: ${EXP_ROOT}
Run root:        ${RUN_ROOT}
Kernel:          ${KERNEL}
Base rootfs:     ${BASE_ROOTFS} (${BASE_ROOTFS_FORMAT})
Rootfs size:     ${ROOTFS_VIRTUAL_SIZE}
VM helper:       ${VMCTL}
Slow mode:       ${SLOW_MEMORY_MODE}
Host CPUs:       ${HOST_CPUS}
Guest CPUs:      ${GUEST_CPUS}
Guest node0:     ${GUEST_NODE0_CPUS}
Local sizes GiB: ${local_size_list[*]}
Default fast host node: ${FAST_HOST_NODE}
Default slow host node: ${SLOW_HOST_NODE}
HMAT:            fast ${HMAT_FAST_LATENCY_NS}ns/${HMAT_FAST_BANDWIDTH}, slow ${HMAT_SLOW_LATENCY_NS}ns/${HMAT_SLOW_BANDWIDTH}
GAPBS graph:     generated g${GAPBS_GRAPH_SCALE}
GAPBS data disk: disabled
THP:             mode=${THP_MODE:-default} defrag=${THP_DEFRAG:-default}
Delete images:   ${DELETE_VM_IMAGES}
Forbid host n1:  ${FORBID_HOST_NODE1}
Controller:      dir=${FAULT_BUCKET_CONTROLLER_DIR} window=${CONTROLLER_WINDOW_SEC}s local_rate=${CONTROLLER_LOCAL_RATE} remote_rate=${CONTROLLER_REMOTE_RATE}
Controller scan: local=${CONTROLLER_LOCAL_FAULT_SCAN_SIZE_MB}MB/${CONTROLLER_LOCAL_FAULT_SCAN_PERIOD_MS}ms remote=${CONTROLLER_REMOTE_FAULT_SCAN_SIZE_MB}MB/${CONTROLLER_REMOTE_FAULT_SCAN_PERIOD_MS}ms

VM plan:
EOF
  local config local_size
  for local_size in "${local_size_list[@]}"; do
    CURRENT_LOCAL_SIZE_GIB="${local_size}"
    CURRENT_LOCAL_LABEL="local${local_size}"
    CURRENT_FAST_MEM="${local_size}G"
    for config in "${config_list[@]}"; do
      printf '  %-7s %-14s port=%s fast=%s@host[%s] slow=%s@host[%s] numa_balancing=%s placement="%s"\n' \
        "${CURRENT_LOCAL_LABEL}" "${config}" "$(config_port "${config}")" "$(config_fast_mem "${config}")" \
        "$(config_fast_host_node "${config}")" "$(config_slow_mem "${config}")" \
        "$(config_slow_host_node "${config}")" "$(config_numa_balancing "${config}")" \
        "$(config_placement "${config}")"
    done
  done

  printf '\nRun matrix:\n'
  local total=0 workload
  for local_size in "${local_size_list[@]}"; do
    for config in "${config_list[@]}"; do
      for workload in "${workload_list[@]}"; do
        printf '  local%-3s %-14s %s\n' "${local_size}" "${config}" "${workload}"
        total=$((total + 1))
      done
    done
  done
  printf '\nTotal runs: %d local_sizes=%d configs=%d workloads=%d\n' \
    "${total}" "${#local_size_list[@]}" "${#config_list[@]}" "${#workload_list[@]}"
}

preflight() {
  local -a local_size_list=()
  mapfile -t local_size_list < <(expand_local_sizes ${LOCAL_SIZES_GIB})
  ((${#local_size_list[@]} > 0)) || die "LOCAL_SIZES_GIB is empty"
  validate_no_host_node1_use
  [[ -x "${VMCTL}" ]] || die "missing vmctl: ${VMCTL}"
  [[ -f "${KERNEL}" ]] || die "missing kernel: ${KERNEL}"
  [[ -f "${BASE_ROOTFS}" ]] || die "missing base rootfs: ${BASE_ROOTFS}"
  [[ -f "${SSH_KEY}" ]] || die "missing SSH key: ${SSH_KEY}"
  [[ -x "${REPO_ROOT}/scripts/stage_workloads_to_vm.sh" ]] || die "missing stage script"
  [[ -x "${SCRIPT_DIR}/run_vm_sweep_guest.sh" ]] || die "missing guest runner"
  [[ -x "${SCRIPT_DIR}/run_workload_case_guest.sh" ]] || die "missing case runner"
  if configs_need_controller; then
    [[ -d "${FAULT_BUCKET_CONTROLLER_DIR}" ]] || die "missing fault bucket controller dir: ${FAULT_BUCKET_CONTROLLER_DIR}"
    [[ -x "${FAULT_BUCKET_CONTROLLER_DIR}/bucket_latency_controller.py" ]] || die "missing executable controller: ${FAULT_BUCKET_CONTROLLER_DIR}/bucket_latency_controller.py"
    [[ -x "${FAULT_BUCKET_CONTROLLER_DIR}/run_guest.sh" ]] || die "missing executable controller runner: ${FAULT_BUCKET_CONTROLLER_DIR}/run_guest.sh"
    [[ -x "${FAULT_BUCKET_CONTROLLER_DIR}/plot_controller.py" ]] || die "missing executable controller plotter: ${FAULT_BUCKET_CONTROLLER_DIR}/plot_controller.py"
  fi
  command -v python3 >/dev/null 2>&1 || die "python3 not found"
  command -v qemu-img >/dev/null 2>&1 || die "qemu-img not found"
  [[ -d "/sys/devices/system/node/node${FAST_HOST_NODE}" ]] || die "missing fast host node ${FAST_HOST_NODE}"
  [[ -d "/sys/devices/system/node/node${SLOW_HOST_NODE}" ]] || die "missing slow host node ${SLOW_HOST_NODE}"
  [[ "${DISABLE_SMT}" != "1" || "$(id -u)" == "0" ]] || sudo -n true >/dev/null 2>&1 || die "sudo -n is required to disable SMT"
  if use_gapbs_data_disk; then
    sudo -n true >/dev/null 2>&1 || die "sudo -n is required to create/mount GAPBS data disk"
    ensure_gapbs_data_disk
  fi
  if expand_workloads ${WORKLOADS} | grep -qx silo; then
    [[ -d "${BENCHMARK_DIR}/silo" ]] || die "missing Silo source tree: ${BENCHMARK_DIR}/silo"
  fi
  if expand_workloads ${WORKLOADS} | grep -qx liblinear; then
    [[ -d "${LIBLINEAR_ROOT_HOST}" ]] || die "missing Liblinear source tree: ${LIBLINEAR_ROOT_HOST}"
    [[ -f "${LIBLINEAR_DATASET_HOST}" ]] || die "missing Liblinear dataset: ${LIBLINEAR_DATASET_HOST}"
  fi
}

ensure_gapbs_data_disk() {
  return 0
}

write_host_config() {
  mkdir -p "${IMAGES_DIR}" "${HOST_LOG_DIR}" "${GUEST_RESULTS_DIR}" "${SUMMARY_DIR}" "${VM_RUN_DIR_HOST}"
  {
    printf 'date_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'run_id=%s\n' "${RUN_ID}"
    printf 'required_protocol_doc=%s\n' "${ICCD_REQUIRED_PROTOCOL_DOC:-}"
    printf 'repo_root=%s\n' "${REPO_ROOT}"
    printf 'experiment_root=%s\n' "${EXP_ROOT}"
    printf 'kernel=%s\n' "${KERNEL}"
    printf 'base_rootfs=%s\n' "${BASE_ROOTFS}"
    printf 'base_rootfs_format=%s\n' "${BASE_ROOTFS_FORMAT}"
    printf 'root_device=%s\n' "${ROOT_DEVICE}"
    printf 'root_disk=%s\n' "${ROOT_DISK}"
    printf 'root_partition_number=%s\n' "${ROOT_PARTITION_NUMBER}"
    printf 'rootfs_virtual_size=%s\n' "${ROOTFS_VIRTUAL_SIZE}"
    printf 'local_sizes_gib=%s\n' "${LOCAL_SIZES_GIB}"
    printf 'host_cpus=%s\n' "${HOST_CPUS}"
    printf 'guest_cpus=%s\n' "${GUEST_CPUS}"
    printf 'guest_node0_cpus=%s\n' "${GUEST_NODE0_CPUS}"
    printf 'fast_host_node=%s\n' "${FAST_HOST_NODE}"
    printf 'slow_host_node=%s\n' "${SLOW_HOST_NODE}"
    printf 'all_local_fast_host_node=%s\n' "${ALL_LOCAL_FAST_HOST_NODE}"
    printf 'all_local_slow_host_node=%s\n' "${ALL_LOCAL_SLOW_HOST_NODE}"
    printf 'all_slow_fast_host_node=%s\n' "${ALL_SLOW_FAST_HOST_NODE}"
    printf 'all_slow_slow_host_node=%s\n' "${ALL_SLOW_SLOW_HOST_NODE}"
    printf 'migration_fast_host_node=%s\n' "${MIGRATION_FAST_HOST_NODE}"
    printf 'migration_slow_host_node=%s\n' "${MIGRATION_SLOW_HOST_NODE}"
    printf 'slow_memory_mode=%s\n' "${SLOW_MEMORY_MODE}"
    printf 'hmat_fast_latency_ns=%s\n' "${HMAT_FAST_LATENCY_NS}"
    printf 'hmat_slow_latency_ns=%s\n' "${HMAT_SLOW_LATENCY_NS}"
    printf 'hmat_fast_bandwidth=%s\n' "${HMAT_FAST_BANDWIDTH}"
    printf 'hmat_slow_bandwidth=%s\n' "${HMAT_SLOW_BANDWIDTH}"
    printf 'workloads=%s\n' "${WORKLOADS}"
    printf 'configs=%s\n' "${CONFIGS}"
    printf 'migration_fast_mem_default=%s\n' "${MIGRATION_FAST_MEM}"
    printf 'migration_slow_mem=%s\n' "${MIGRATION_SLOW_MEM}"
    printf 'timeout_sec=%s\n' "${TIMEOUT_SEC}"
    printf 'sample_interval_sec=%s\n' "${SAMPLE_INTERVAL_SEC}"
    printf 'omp_threads=%s\n' "${OMP_THREADS}"
    printf 'mglru_enabled=%s\n' "${MGLRU_ENABLED}"
    printf 'numa_scan_size_mb=%s\n' "${NUMA_SCAN_SIZE_MB}"
    printf 'numa_scan_period_min_ms=%s\n' "${NUMA_SCAN_PERIOD_MIN_MS}"
    printf 'local_fault_rate=%s\n' "${LOCAL_FAULT_RATE}"
    printf 'remote_fault_rate=%s\n' "${REMOTE_FAULT_RATE}"
    printf 'local_fault_scan_period_ms=%s\n' "${LOCAL_FAULT_SCAN_PERIOD_MS}"
    printf 'local_fault_scan_size_mb=%s\n' "${LOCAL_FAULT_SCAN_SIZE_MB}"
    printf 'remote_fault_scan_period_ms=%s\n' "${REMOTE_FAULT_SCAN_PERIOD_MS}"
    printf 'remote_fault_scan_size_mb=%s\n' "${REMOTE_FAULT_SCAN_SIZE_MB}"
    printf 'thp_mode=%s\n' "${THP_MODE}"
    printf 'thp_defrag=%s\n' "${THP_DEFRAG}"
    printf 'realworld_size_profile=%s\n' "${REALWORLD_SIZE_PROFILE}"
    printf 'verify_required_state=%s\n' "${VERIFY_REQUIRED_STATE}"
    printf 'trace_bc_trial_promotions=%s\n' "${TRACE_BC_TRIAL_PROMOTIONS}"
    printf 'forbid_host_node1=%s\n' "${FORBID_HOST_NODE1}"
    printf 'fault_bucket_controller_dir=%s\n' "${FAULT_BUCKET_CONTROLLER_DIR}"
    printf 'controller_window_sec=%s\n' "${CONTROLLER_WINDOW_SEC}"
    printf 'controller_local_rate=%s\n' "${CONTROLLER_LOCAL_RATE}"
    printf 'controller_remote_rate=%s\n' "${CONTROLLER_REMOTE_RATE}"
    printf 'controller_local_fault_scan_period_ms=%s\n' "${CONTROLLER_LOCAL_FAULT_SCAN_PERIOD_MS}"
    printf 'controller_local_fault_scan_size_mb=%s\n' "${CONTROLLER_LOCAL_FAULT_SCAN_SIZE_MB}"
    printf 'controller_remote_fault_scan_period_ms=%s\n' "${CONTROLLER_REMOTE_FAULT_SCAN_PERIOD_MS}"
    printf 'controller_remote_fault_scan_size_mb=%s\n' "${CONTROLLER_REMOTE_FAULT_SCAN_SIZE_MB}"
    printf 'controller_min_local_pages=%s\n' "${CONTROLLER_MIN_LOCAL_PAGES}"
    printf 'controller_min_remote_pages=%s\n' "${CONTROLLER_MIN_REMOTE_PAGES}"
    printf 'controller_consecutive_effective=%s\n' "${CONTROLLER_CONSECUTIVE_EFFECTIVE}"
    printf 'controller_consecutive_no_improve=%s\n' "${CONTROLLER_CONSECUTIVE_NO_IMPROVE}"
    printf 'controller_restart_remote_share_threshold=%s\n' "${CONTROLLER_RESTART_REMOTE_SHARE_THRESHOLD}"
    printf 'controller_consecutive_restart=%s\n' "${CONTROLLER_CONSECUTIVE_RESTART}"
    printf 'controller_restart_grace_windows=%s\n' "${CONTROLLER_RESTART_GRACE_WINDOWS}"
    printf 'controller_numa_balancing_on=%s\n' "${CONTROLLER_NUMA_BALANCING_ON}"
    printf 'controller_numa_balancing_off=%s\n' "${CONTROLLER_NUMA_BALANCING_OFF}"
    printf 'gapbs_graph_mode=generated\n'
    printf 'gapbs_graph_scale=%s\n' "${GAPBS_GRAPH_SCALE}"
    printf 'gapbs_graph_path=generated:g%s\n' "${GAPBS_GRAPH_SCALE}"
    printf 'gapbs_data_disk=0\n'
    printf 'drop_guest_caches=%s\n' "${DROP_GUEST_CACHES}"
    printf 'compact_guest_memory=%s\n' "${COMPACT_GUEST_MEMORY}"
    printf 'graph_build_included=1\n'
    printf 'pr_trials=%s\n' "${PR_TRIALS}"
    printf 'bc_trials=%s\n' "${BC_TRIALS}"
    printf 'silo_bin_host=%s\n' "${SILO_BIN_HOST}"
    printf 'liblinear_train_host=%s\n' "${LIBLINEAR_TRAIN_HOST}"
    printf 'liblinear_dataset_host=%s\n' "${LIBLINEAR_DATASET_HOST}"
    printf 'disable_smt=%s\n' "${DISABLE_SMT}"
    printf 'smt_control=%s\n' "$(read_smt_control)"
    printf 'delete_vm_images=%s\n' "${DELETE_VM_IMAGES}"
    [[ -z "${CXL_FMW_SIZE:-}" ]] || printf 'cxl_fmw_size=%s\n' "${CXL_FMW_SIZE}"
    numactl -H 2>/dev/null || true
  } > "${HOST_LOG_DIR}/host-config.log"
}

create_overlay() {
  local config="$1"
  local output="${IMAGES_DIR}/${CURRENT_LOCAL_LABEL}-${config}.qcow2"

  if [[ -e "${output}" && "${RESUME}" == "1" ]]; then
    log "reuse overlay ${output}"
    qemu-img resize "${output}" "${ROOTFS_VIRTUAL_SIZE}" \
      > "${HOST_LOG_DIR}/${CURRENT_LOCAL_LABEL}-${config}.resize-image.log" 2>&1 || true
    printf '%s\n' "${output}"
    return 0
  fi

  rm -f "${output}"
  log "create overlay ${output}"
  vmctl_cmd create-image \
    --overlay-from "${BASE_ROOTFS}" \
    --backing-format "${BASE_ROOTFS_FORMAT}" \
    --output "${output}" \
    > "${HOST_LOG_DIR}/${CURRENT_LOCAL_LABEL}-${config}.create-image.log" 2>&1 || return $?
  qemu-img resize "${output}" "${ROOTFS_VIRTUAL_SIZE}" \
    > "${HOST_LOG_DIR}/${CURRENT_LOCAL_LABEL}-${config}.resize-image.log" 2>&1 || return $?
  printf '%s\n' "${output}"
}

boot_vm() {
  local config="$1" overlay="$2"
  local name="vm32-${VM_RUN_TAG}-${CURRENT_LOCAL_LABEL}-${config}"
  local port fast_mem slow_mem fast_host_node slow_host_node
  port="$(config_port "${config}")"
  fast_mem="$(config_fast_mem "${config}")"
  slow_mem="$(config_slow_mem "${config}")"
  fast_host_node="$(config_fast_host_node "${config}")"
  slow_host_node="$(config_slow_host_node "${config}")"

  local -a args=(
    boot
    --qemu-bin "${QEMU_BIN}"
    --name "${name}"
    --kernel "${KERNEL}"
    --rootfs "${overlay}"
    --rootfs-format qcow2
    --root-device "${ROOT_DEVICE}"
    --ssh-key "${SSH_KEY}"
    --ssh-port "${port}"
    --host-cpus "${HOST_CPUS}"
    --guest-cpus "${GUEST_CPUS}"
    --guest-node0-cpus "${GUEST_NODE0_CPUS}"
    --fast-host-node "${fast_host_node}"
    --slow-host-node "${slow_host_node}"
    --fast-mem "${fast_mem}"
    --slow-mem "${slow_mem}"
    --slow-memory-mode "${SLOW_MEMORY_MODE}"
    --accel kvm
    --hmat-fast-latency-ns "${HMAT_FAST_LATENCY_NS}"
    --hmat-slow-latency-ns "${HMAT_SLOW_LATENCY_NS}"
    --hmat-fast-bandwidth "${HMAT_FAST_BANDWIDTH}"
    --hmat-slow-bandwidth "${HMAT_SLOW_BANDWIDTH}"
  )
  [[ -z "${INITRD:-}" ]] || args+=(--initrd "${INITRD}")
  [[ -z "${CXL_FMW_SIZE:-}" ]] || args+=(--cxl-fmw-size "${CXL_FMW_SIZE}")
  CURRENT_VM_NAME="${name}"
  log "boot ${CURRENT_LOCAL_LABEL}/${config} name=${name} port=${port} fast=${fast_mem}@host[${fast_host_node}] slow=${slow_mem}@host[${slow_host_node}]"
  vmctl_cmd "${args[@]}" > "${HOST_LOG_DIR}/${CURRENT_LOCAL_LABEL}-${config}.boot.log" 2>&1
}

wait_and_verify() {
  local config="$1"
  local port name
  port="$(config_port "${config}")"
  name="${CURRENT_VM_NAME}"

  SSH_TIMEOUT="${WAIT_TIMEOUT:-300}" vmctl_cmd wait-ssh \
    --host "${HOST}" --ssh-key "${SSH_KEY}" --ssh-port "${port}" --name "${name}" \
    > "${HOST_LOG_DIR}/${CURRENT_LOCAL_LABEL}-${config}.wait-ssh.log" 2>&1 || return $?

  vmctl_cmd verify-placement \
    --host "${HOST}" --name "${name}" --ssh-key "${SSH_KEY}" --ssh-port "${port}" \
    > "${HOST_LOG_DIR}/${CURRENT_LOCAL_LABEL}-${config}.placement.log" 2>&1 || true
}

grow_guest_rootfs_once() {
  local config="$1"
  ssh_vm "${config}" \
    "ROOT_DISK='${ROOT_DISK}' ROOT_PARTITION_NUMBER='${ROOT_PARTITION_NUMBER}' ROOT_DEVICE='${ROOT_DEVICE}' bash -s" <<'EOF'
set -euo pipefail
echo "[grow-rootfs] before"
df -h /
lsblk "${ROOT_DISK}" || true

if command -v growpart >/dev/null 2>&1; then
  growpart "${ROOT_DISK}" "${ROOT_PARTITION_NUMBER}" || true
elif command -v parted >/dev/null 2>&1; then
  parted -s "${ROOT_DISK}" "resizepart" "${ROOT_PARTITION_NUMBER}" "100%" || true
else
  echo "missing growpart or parted in guest" >&2
  exit 77
fi

resize2fs "${ROOT_DEVICE}"
echo "[grow-rootfs] after"
df -h /
lsblk "${ROOT_DISK}" || true
EOF
}

grow_guest_rootfs() {
  local config="$1"
  log "grow guest rootfs for ${config}"
  retry_vm_cmd "grow-rootfs ${CURRENT_LOCAL_LABEL}/${config}" grow_guest_rootfs_once "${config}" \
    > "${HOST_LOG_DIR}/${CURRENT_LOCAL_LABEL}-${config}.grow-rootfs.log" 2>&1
}

ssh_vm() {
  local config="$1"
  shift
  vmctl_cmd ssh --host "${HOST}" --ssh-key "${SSH_KEY}" --ssh-port "$(config_port "${config}")" -- "$@"
}

copy_to_vm() {
  local config="$1"
  shift
  vmctl_cmd copy-to --host "${HOST}" --ssh-key "${SSH_KEY}" --ssh-port "$(config_port "${config}")" -- "$@"
}

copy_from_vm() {
  local config="$1"
  shift
  vmctl_cmd copy-from --host "${HOST}" --ssh-key "${SSH_KEY}" --ssh-port "$(config_port "${config}")" -- "$@"
}

retry_vm_cmd() {
  local label="$1"
  shift
  local attempt rc=0

  for ((attempt = 1; attempt <= SSH_RETRY_ATTEMPTS; attempt++)); do
    if "$@"; then
      return 0
    else
      rc=$?
    fi
    log "${label} failed attempt ${attempt}/${SSH_RETRY_ATTEMPTS} rc=${rc}"
    if ((attempt < SSH_RETRY_ATTEMPTS)); then
      sleep "${SSH_RETRY_DELAY_SEC}"
    fi
  done

  return "${rc}"
}

ssh_vm_retry() {
  local config="$1"
  shift
  retry_vm_cmd "ssh ${CURRENT_LOCAL_LABEL}/${config}" ssh_vm "${config}" "$@"
}

copy_to_vm_retry() {
  local config="$1"
  shift
  retry_vm_cmd "copy-to ${CURRENT_LOCAL_LABEL}/${config}" copy_to_vm "${config}" "$@"
}

copy_from_vm_retry() {
  local config="$1"
  shift
  retry_vm_cmd "copy-from ${CURRENT_LOCAL_LABEL}/${config}" copy_from_vm "${config}" "$@"
}

ssh_stream_vm() {
  local config="$1" remote_cmd="$2"
  local -a cmd=(
    ssh
    -p "$(config_port "${config}")"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=5
  )
  if [[ -n "${SSH_KEY}" ]]; then
    cmd+=(-i "${SSH_KEY}" -o IdentitiesOnly=yes)
  fi
  cmd+=("root@${HOST}" "${remote_cmd}")
  "${cmd[@]}"
}

wait_guest_ssh_ready() {
  local config="$1" log_file="$2"
  local attempt rc=0

  {
    printf '[vm32-host] wait guest ssh ready for %s/%s\n' "${CURRENT_LOCAL_LABEL}" "${config}"
    if ((POST_STAGE_SSH_SETTLE_SEC > 0)); then
      printf '[vm32-host] settle %ss before readiness probes\n' "${POST_STAGE_SSH_SETTLE_SEC}"
      sleep "${POST_STAGE_SSH_SETTLE_SEC}"
    fi
  } >> "${log_file}"

  for ((attempt = 1; attempt <= SSH_READY_ATTEMPTS; attempt++)); do
    set +e
    ssh_vm "${config}" "true" >> "${log_file}" 2>&1
    rc=$?
    set -e
    if [[ "${rc}" == "0" ]]; then
      printf '[vm32-host] guest ssh ready attempt %d/%d\n' "${attempt}" "${SSH_READY_ATTEMPTS}" >> "${log_file}"
      return 0
    fi
    printf '[vm32-host] guest ssh not ready attempt %d/%d rc=%s\n' "${attempt}" "${SSH_READY_ATTEMPTS}" "${rc}" >> "${log_file}"
    if ((attempt < SSH_READY_ATTEMPTS)); then
      sleep "${SSH_READY_DELAY_SEC}"
    fi
  done

  return "${rc}"
}

workload_needs_common_stage() {
  case "$1" in
    pr|bc|gups|graph500|btree|redis_uniform|redis_ycsb_a|faster_uniform|faster_ycsb_a|silo|liblinear)
      return 0
      ;;
  esac
  return 1
}

common_stage_workloads() {
  local workload
  expand_workloads ${WORKLOADS} | while read -r workload; do
    workload_needs_common_stage "${workload}" && printf '%s\n' "${workload}"
  done | awk '!seen[$0]++'
}

has_workload() {
  local want="$1" workload
  while read -r workload; do
    [[ "${workload}" == "${want}" ]] && return 0
  done < <(expand_workloads ${WORKLOADS})
  return 1
}

stage_extra_workloads() {
  return 0
}

stage_common_workloads_once() {
  local config="$1" common_workloads="$2"
  local stage_gapbs_graph=0
  if use_gapbs_data_disk; then
    stage_gapbs_graph=0
  fi
  env \
    VM_ACTION=stage \
    VMCTL="${VMCTL}" \
    PORT="$(config_port "${config}")" \
    HOST="${HOST}" \
    SSH_KEY="${SSH_KEY}" \
    WORKLOADS="${common_workloads}" \
    BENCHMARK_DIR="${BENCHMARK_DIR}" \
    GAPBS_GRAPH_SCALE="${GAPBS_GRAPH_SCALE}" \
    STAGE_GAPBS_GRAPH="${stage_gapbs_graph}" \
    LIBLINEAR_DATASET="${LIBLINEAR_DATASET}" \
    CLEAN="${CLEAN_STAGE}" \
    CLEAN_SCRIPTS="${CLEAN_SCRIPTS}" \
    VERIFY_PLACEMENT=0 \
    "${REPO_ROOT}/scripts/stage_workloads_to_vm.sh"
}

stage_workloads() {
  local config="$1"
  local common_workloads

  if [[ "${STAGE_WORKLOADS}" != "1" ]]; then
    log "skip workload staging for ${config}"
    return 0
  fi

  common_workloads="$(common_stage_workloads | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  if [[ -n "${common_workloads}" ]]; then
    log "stage common workloads for ${CURRENT_LOCAL_LABEL}/${config}: ${common_workloads}"
    retry_vm_cmd "stage-common ${CURRENT_LOCAL_LABEL}/${config}" \
      stage_common_workloads_once "${config}" "${common_workloads}" \
      > "${HOST_LOG_DIR}/${CURRENT_LOCAL_LABEL}-${config}.stage-workloads.log" 2>&1 || return $?
  else
    log "skip common workload staging for ${CURRENT_LOCAL_LABEL}/${config}; no common workloads selected"
  fi
  stage_extra_workloads "${config}" || return $?
}

stage_experiment_scripts() {
  local config="$1"
  log "stage experiment scripts for ${config}"
  if [[ "${EXPERIMENT_SCRIPTS_STAGED}" == "1" ]]; then
    printf 'already staged by workload staging step\n' \
      > "${HOST_LOG_DIR}/${CURRENT_LOCAL_LABEL}-${config}.stage-experiment-scripts.log"
    return 0
  fi
  {
    ssh_vm_retry "${config}" "mkdir -p /root/vm32_realworld/scripts /root/design/fault_bucket_controller" || return $?
    copy_to_vm_retry "${config}" \
      "${SCRIPT_DIR}/run_vm_sweep_guest.sh" \
      "${SCRIPT_DIR}/run_workload_case_guest.sh" \
      "${SCRIPT_DIR}/trace_gapbs_trial_promotions.sh" \
      "${SCRIPT_DIR}/summarize_vm_results.py" \
      /root/vm32_realworld/scripts/ || return $?
    if [[ -d "${FAULT_BUCKET_CONTROLLER_DIR}" ]]; then
      copy_to_vm_retry "${config}" \
        "${FAULT_BUCKET_CONTROLLER_DIR}/bucket_latency_controller.py" \
        "${FAULT_BUCKET_CONTROLLER_DIR}/plot_controller.py" \
        "${FAULT_BUCKET_CONTROLLER_DIR}/run_guest.sh" \
        /root/design/fault_bucket_controller/ || return $?
    fi
    ssh_vm_retry "${config}" "chmod +x /root/vm32_realworld/scripts/run_vm_sweep_guest.sh /root/vm32_realworld/scripts/run_workload_case_guest.sh /root/vm32_realworld/scripts/trace_gapbs_trial_promotions.sh; find /root/design/fault_bucket_controller -maxdepth 1 -type f \\( -name '*.py' -o -name 'run_guest.sh' \\) -exec chmod +x {} +" || return $?
  } > "${HOST_LOG_DIR}/${CURRENT_LOCAL_LABEL}-${config}.stage-experiment-scripts.log" 2>&1
}

flush_guest_filesystems() {
  local config="$1"
  log "flush guest filesystems for ${CURRENT_LOCAL_LABEL}/${config}"
  retry_vm_cmd "flush ${CURRENT_LOCAL_LABEL}/${config}" \
    ssh_vm "${config}" "sync; blockdev --flushbufs '${ROOT_DISK}' 2>/dev/null || true; sleep 2; sync" \
    > "${HOST_LOG_DIR}/${CURRENT_LOCAL_LABEL}-${config}.flush.log" 2>&1
}

run_guest_config() {
  local config="$1"
  local guest_base="/root/vm32_realworld/${RUN_ID}/${CURRENT_LOCAL_LABEL}"
  local guest_out="${guest_base}/${config}"
  local guest_cmd rc attempt

  printf -v guest_cmd \
    'OUTROOT=%q LOCAL_SIZE_GIB=%q CONFIGS=%q WORKLOADS=%q PROGRESS_BASE=%q PROGRESS_TOTAL=%q TIMEOUT_SEC=%q SAMPLE_INTERVAL_SEC=%q OMP_THREADS=%q MGLRU_ENABLED=%q NUMA_SCAN_SIZE_MB=%q NUMA_SCAN_PERIOD_MIN_MS=%q LOCAL_FAULT_RATE=%q REMOTE_FAULT_RATE=%q LOCAL_FAULT_SCAN_PERIOD_MS=%q LOCAL_FAULT_SCAN_SIZE_MB=%q REMOTE_FAULT_SCAN_PERIOD_MS=%q REMOTE_FAULT_SCAN_SIZE_MB=%q THP_MODE=%q THP_DEFRAG=%q REALWORLD_SIZE_PROFILE=%q VERIFY_REQUIRED_STATE=%q TRACE_BC_TRIAL_PROMOTIONS=%q RESUME=%q BENCHMARK_DIR=%q REALWORLD_CASE_RUNNER=%q GAPBS_GRAPH_SCALE=%q DROP_GUEST_CACHES=%q COMPACT_GUEST_MEMORY=%q PR_ITERATIONS=%q PR_TOLERANCE=%q PR_TRIALS=%q BC_ITERATIONS=%q BC_TRIALS=%q GUPS_MEMORY_GB=%q GRAPH500_SCALE=%q XSBENCH_GRID=%q XSBENCH_PARTICLES=%q SILO_SCALE_FACTOR=%q SILO_OPS_PER_WORKER=%q LIBLINEAR_DATASET=%q CONTROLLER_WINDOW_SEC=%q CONTROLLER_LOCAL_RATE=%q CONTROLLER_REMOTE_RATE=%q CONTROLLER_LOCAL_FAULT_SCAN_PERIOD_MS=%q CONTROLLER_LOCAL_FAULT_SCAN_SIZE_MB=%q CONTROLLER_REMOTE_FAULT_SCAN_PERIOD_MS=%q CONTROLLER_REMOTE_FAULT_SCAN_SIZE_MB=%q CONTROLLER_MIN_LOCAL_PAGES=%q CONTROLLER_MIN_REMOTE_PAGES=%q CONTROLLER_CONSECUTIVE_EFFECTIVE=%q CONTROLLER_CONSECUTIVE_NO_IMPROVE=%q CONTROLLER_RESTART_REMOTE_SHARE_THRESHOLD=%q CONTROLLER_CONSECUTIVE_RESTART=%q CONTROLLER_RESTART_GRACE_WINDOWS=%q CONTROLLER_NUMA_BALANCING_ON=%q CONTROLLER_NUMA_BALANCING_OFF=%q /root/vm32_realworld/scripts/run_vm_sweep_guest.sh' \
    "${guest_base}" "${CURRENT_LOCAL_SIZE_GIB}" "${config}" "${WORKLOADS}" "${CURRENT_PROGRESS_BASE}" "${TOTAL_WORKLOAD_CASES}" \
    "${TIMEOUT_SEC}" "${SAMPLE_INTERVAL_SEC}" "${OMP_THREADS}" "${MGLRU_ENABLED}" "${NUMA_SCAN_SIZE_MB}" "${NUMA_SCAN_PERIOD_MIN_MS}" \
    "${LOCAL_FAULT_RATE}" "${REMOTE_FAULT_RATE}" "${LOCAL_FAULT_SCAN_PERIOD_MS}" "${LOCAL_FAULT_SCAN_SIZE_MB}" \
    "${REMOTE_FAULT_SCAN_PERIOD_MS}" "${REMOTE_FAULT_SCAN_SIZE_MB}" \
    "${THP_MODE}" "${THP_DEFRAG}" "${REALWORLD_SIZE_PROFILE}" "${VERIFY_REQUIRED_STATE}" "${TRACE_BC_TRIAL_PROMOTIONS}" "${RESUME}" "/root/benchmark" \
    "/root/scripts/run_workload_case_guest.sh" "${GAPBS_GRAPH_SCALE}" "${DROP_GUEST_CACHES}" "${COMPACT_GUEST_MEMORY}" \
    "${PR_ITERATIONS}" "${PR_TOLERANCE}" "${PR_TRIALS}" "${BC_ITERATIONS}" "${BC_TRIALS}" \
    "${GUPS_MEMORY_GB}" "${GRAPH500_SCALE}" "${XSBENCH_GRID}" "${XSBENCH_PARTICLES}" \
    "${SILO_SCALE_FACTOR:-800000}" "${SILO_OPS_PER_WORKER:-100000000}" "${LIBLINEAR_DATASET}" \
    "${CONTROLLER_WINDOW_SEC}" "${CONTROLLER_LOCAL_RATE}" "${CONTROLLER_REMOTE_RATE}" \
    "${CONTROLLER_LOCAL_FAULT_SCAN_PERIOD_MS}" "${CONTROLLER_LOCAL_FAULT_SCAN_SIZE_MB}" \
    "${CONTROLLER_REMOTE_FAULT_SCAN_PERIOD_MS}" "${CONTROLLER_REMOTE_FAULT_SCAN_SIZE_MB}" \
    "${CONTROLLER_MIN_LOCAL_PAGES}" "${CONTROLLER_MIN_REMOTE_PAGES}" \
    "${CONTROLLER_CONSECUTIVE_EFFECTIVE}" "${CONTROLLER_CONSECUTIVE_NO_IMPROVE}" \
    "${CONTROLLER_RESTART_REMOTE_SHARE_THRESHOLD}" "${CONTROLLER_CONSECUTIVE_RESTART}" \
    "${CONTROLLER_RESTART_GRACE_WINDOWS}" "${CONTROLLER_NUMA_BALANCING_ON}" \
    "${CONTROLLER_NUMA_BALANCING_OFF}"

  log "run guest matrix for ${config}"
  : > "${HOST_LOG_DIR}/${CURRENT_LOCAL_LABEL}-${config}.guest-run.log"
  rc=0
  for ((attempt = 1; attempt <= SSH_RETRY_ATTEMPTS; attempt++)); do
    if ((attempt > 1)); then
      {
        printf '\n[vm32-host] retry guest matrix ssh attempt %d/%d\n' "${attempt}" "${SSH_RETRY_ATTEMPTS}"
        sleep "${SSH_RETRY_DELAY_SEC}"
      } >> "${HOST_LOG_DIR}/${CURRENT_LOCAL_LABEL}-${config}.guest-run.log"
    fi
    set +e
    ssh_vm "${config}" "${guest_cmd}" 2>&1 | tee -a "${HOST_LOG_DIR}/${CURRENT_LOCAL_LABEL}-${config}.guest-run.log"
    rc=${PIPESTATUS[0]}
    set -e
    if [[ "${rc}" == "0" ]]; then
      break
    fi
    if ! tail -80 "${HOST_LOG_DIR}/${CURRENT_LOCAL_LABEL}-${config}.guest-run.log" |
        grep -Eq 'kex_exchange_identification|Connection closed by remote host|Connection reset by peer'; then
      break
    fi
  done
  printf '%s\n' "${rc}" > "${HOST_LOG_DIR}/${CURRENT_LOCAL_LABEL}-${config}.guest-run.rc"

  local host_out="${GUEST_RESULTS_DIR}/${CURRENT_LOCAL_LABEL}/${config}"
  rm -rf "${host_out}"
  mkdir -p "$(dirname -- "${host_out}")"
  log "copy guest results for ${config}"
  if ! copy_from_vm_retry "${config}" "${guest_out}" "${host_out}" \
      > "${HOST_LOG_DIR}/${CURRENT_LOCAL_LABEL}-${config}.copy-results.log" 2>&1; then
    log "copy results failed for ${config}; see ${HOST_LOG_DIR}/${CURRENT_LOCAL_LABEL}-${config}.copy-results.log"
    return 1
  fi
  return "${rc}"
}

stop_vm_for_config() {
  local config="$1" rc="$2"
  local should_stop=0
  if [[ "${rc}" == "0" && "${STOP_VM_ON_SUCCESS}" == "1" ]]; then
    should_stop=1
  elif [[ "${rc}" != "0" && "${STOP_VM_ON_FAILURE}" == "1" ]]; then
    should_stop=1
  fi
  if [[ "${should_stop}" == "1" && -n "${CURRENT_VM_NAME}" ]]; then
    log "stop ${config} name=${CURRENT_VM_NAME}"
    vmctl_cmd stop --name "${CURRENT_VM_NAME}" > "${HOST_LOG_DIR}/${CURRENT_LOCAL_LABEL}-${config}.stop.log" 2>&1 || true
    CURRENT_VM_NAME=""
  fi
}

restart_vm_after_stage() {
  local config="$1" overlay="$2"

  [[ "${REBOOT_AFTER_STAGE}" == "1" ]] || return 0
  [[ -n "${CURRENT_VM_NAME}" ]] || return 0

  log "reboot ${config} after staging name=${CURRENT_VM_NAME}"
  flush_guest_filesystems "${config}" || return $?
  vmctl_cmd stop --name "${CURRENT_VM_NAME}" > "${HOST_LOG_DIR}/${CURRENT_LOCAL_LABEL}-${config}.restart-stop.log" 2>&1 || true
  CURRENT_VM_NAME=""
  sleep 5
  boot_vm "${config}" "${overlay}"
  wait_and_verify "${config}"
}

delete_overlay_for_config() {
  local config="$1" overlay="$2"
  [[ "${DELETE_VM_IMAGES}" == "1" ]] || return 0
  if [[ -n "${CURRENT_VM_NAME}" ]]; then
    log "skip image delete for ${config}; VM is still marked active (${CURRENT_VM_NAME})"
    return 0
  fi
  if [[ -e "${overlay}" ]]; then
    log "delete image for ${config}: ${overlay}"
    rm -f "${overlay}"
  fi
}

run_one_config() {
  local config="$1" overlay="" rc=0

  EXPERIMENT_SCRIPTS_STAGED=0
  overlay="$(create_overlay "${config}")" || rc=$?
  if [[ "${rc}" == "0" ]]; then
    boot_vm "${config}" "${overlay}" || rc=$?
  fi
  if [[ "${rc}" == "0" ]]; then
    wait_and_verify "${config}" || rc=$?
  fi
  if [[ "${rc}" == "0" ]]; then
    grow_guest_rootfs "${config}" || rc=$?
  fi
  if [[ "${rc}" == "0" ]]; then
    stage_workloads "${config}" || rc=$?
  fi
  if [[ "${rc}" == "0" ]]; then
    stage_experiment_scripts "${config}" || rc=$?
  fi
  if [[ "${rc}" == "0" ]]; then
    restart_vm_after_stage "${config}" "${overlay}" || rc=$?
  fi
  if [[ "${rc}" == "0" ]]; then
    wait_guest_ssh_ready "${config}" "${HOST_LOG_DIR}/${CURRENT_LOCAL_LABEL}-${config}.ssh-ready.log" || rc=$?
  fi
  if [[ "${rc}" == "0" ]]; then
    mount_gapbs_data_disk_guest "${config}" || rc=$?
  fi
  if [[ "${rc}" == "0" ]]; then
    set +e
    run_guest_config "${config}"
    rc=$?
    set -e
  fi

  if [[ "${rc}" != "0" ]]; then
    log "config reported failure for ${config} rc=${rc}"
  fi
  unmount_gapbs_data_disk_guest "${config}"
  stop_vm_for_config "${config}" "${rc}"
  [[ -z "${overlay}" ]] || delete_overlay_for_config "${config}" "${overlay}"
  return "${rc}"
}

summarize() {
  log "summarize results"
  python3 "${SCRIPT_DIR}/summarize_vm_results.py" \
    --guest-results "${GUEST_RESULTS_DIR}" \
    --outdir "${SUMMARY_DIR}" \
    > "${HOST_LOG_DIR}/summarize.log" 2>&1
}

main() {
  local -a config_list=()
  local -a local_size_list=()
  local -a workload_list=()
  mapfile -t config_list < <(expand_configs ${CONFIGS})
  mapfile -t local_size_list < <(expand_local_sizes ${LOCAL_SIZES_GIB})
  mapfile -t workload_list < <(expand_workloads ${WORKLOADS})
  TOTAL_WORKLOAD_CASES=$((${#local_size_list[@]} * ${#config_list[@]} * ${#workload_list[@]}))

  if [[ "${DRY_RUN}" == "1" ]]; then
    validate_no_host_node1_use
    print_dry_run "${config_list[@]}"
    return 0
  fi

  preflight
  disable_smt_if_requested
  write_host_config

  local failed=0 config local_size rc local_idx=0 config_idx=0
  for local_size in "${local_size_list[@]}"; do
    CURRENT_LOCAL_SIZE_GIB="${local_size}"
    CURRENT_LOCAL_LABEL="local${local_size}"
    CURRENT_FAST_MEM="${local_size}G"
    log "start local size ${CURRENT_LOCAL_LABEL} fast_mem=${CURRENT_FAST_MEM}"
    config_idx=0
    for config in "${config_list[@]}"; do
      CURRENT_PROGRESS_BASE=$((((local_idx * ${#config_list[@]}) + config_idx) * ${#workload_list[@]}))
      log "progress config $((CURRENT_PROGRESS_BASE + 1))-$((CURRENT_PROGRESS_BASE + ${#workload_list[@]}))/${TOTAL_WORKLOAD_CASES} local=${CURRENT_LOCAL_LABEL} config=${config}"
      set +e
      run_one_config "${config}"
      rc=$?
      set -e
      if [[ "${rc}" != "0" ]]; then
        failed=1
      fi
      config_idx=$((config_idx + 1))
    done
    local_idx=$((local_idx + 1))
  done

  summarize || failed=1

  log "results: ${RUN_ROOT}"
  return "${failed}"
}

main "$@"
