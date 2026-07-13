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
KERNEL_CMDLINE_EXTRA="${KERNEL_CMDLINE_EXTRA:-systemd.mask=systemd-networkd-wait-online.service}"
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
CONFIGS="${CONFIGS:-off on tpp ours}"
WORKLOADS="${WORKLOADS:-pr bc gups btree graph500 silo}"
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
MIGRATION_FAST_MEM="${MIGRATION_FAST_MEM:-16G}"
MIGRATION_SLOW_MEM="${MIGRATION_SLOW_MEM:-128G}"
MIGRATION_FAST_HOST_NODE="${MIGRATION_FAST_HOST_NODE:-${FAST_HOST_NODE}}"
MIGRATION_SLOW_HOST_NODE="${MIGRATION_SLOW_HOST_NODE:-${SLOW_HOST_NODE}}"

OFF_PORT="${OFF_PORT:-10160}"
ON_PORT="${ON_PORT:-10161}"
TPP_PORT="${TPP_PORT:-10164}"
OURS_PORT="${OURS_PORT:-10165}"

BENCHMARK_DIR="${BENCHMARK_DIR:-/Serverless/benchmark}"
TIMEOUT_SEC="${TIMEOUT_SEC:-21600}"
TIMEOUT_KILL_AFTER_SEC="${TIMEOUT_KILL_AFTER_SEC:-60}"
OMP_THREADS="${OMP_THREADS:-32}"
MGLRU_ENABLED="${MGLRU_ENABLED:-0x0007}"
NUMA_SCAN_SIZE_MB="${NUMA_SCAN_SIZE_MB:-256}"
NUMA_SCAN_PERIOD_MIN_MS="${NUMA_SCAN_PERIOD_MIN_MS:-1000}"
NUMA_SCAN_PERIOD_MAX_MS="${NUMA_SCAN_PERIOD_MAX_MS:-}"
NUMA_SCAN_DELAY_MS="${NUMA_SCAN_DELAY_MS:-}"
LOCAL_FAULT_SCAN_PERIOD_MS="${LOCAL_FAULT_SCAN_PERIOD_MS:-1000}"
LOCAL_FAULT_SCAN_SIZE_MB="${LOCAL_FAULT_SCAN_SIZE_MB:-64}"
THP_MODE="${THP_MODE:-}"
THP_DEFRAG="${THP_DEFRAG:-${THP_MODE}}"
REALWORLD_SIZE_PROFILE="${REALWORLD_SIZE_PROFILE:-rss60}"
VERIFY_REQUIRED_STATE="${VERIFY_REQUIRED_STATE:-1}"
DISABLE_SWAP="${DISABLE_SWAP:-1}"
FORBID_HOST_NODE1="${FORBID_HOST_NODE1:-0}"

WINDOW_SEC="${WINDOW_SEC:-1}"
CYCLE_WINDOW_MIN_SEC="${CYCLE_WINDOW_MIN_SEC:-5}"
CYCLE_WINDOW_MAX_SEC="${CYCLE_WINDOW_MAX_SEC:-20}"
LOCAL_RATE="${LOCAL_RATE:-5}"
MIN_LOCAL_PAGES="${MIN_LOCAL_PAGES:-1024}"
MIN_REMOTE_PAGES="${MIN_REMOTE_PAGES:-1024}"
START_CONSECUTIVE="${START_CONSECUTIVE:-2}"
START_CAPACITY_MARGIN_PCT="${START_CAPACITY_MARGIN_PCT:-10}"
STOP_CAPACITY_RATIO_THRESHOLD="${STOP_CAPACITY_RATIO_THRESHOLD:-0.9}"
P75_STAGNATION_REQUIRED_DECREASE_PCT="${P75_STAGNATION_REQUIRED_DECREASE_PCT:-10}"
P75_STAGNATION_REQUIRED_WINDOWS="${P75_STAGNATION_REQUIRED_WINDOWS:-3}"
P75_STAGNATION_RESTART_DEGRADATION_PCT="${P75_STAGNATION_RESTART_DEGRADATION_PCT:-10}"
P75_STAGNATION_RESTART_REQUIRED_WINDOWS="${P75_STAGNATION_RESTART_REQUIRED_WINDOWS:-3}"
REMOTE_RESTART_IMPROVEMENT_PCT="${REMOTE_RESTART_IMPROVEMENT_PCT:-10}"
LOCAL_NODE="${LOCAL_NODE:-0}"
REMOTE_NODE="${REMOTE_NODE:-1}"
MIGRATION_ENABLED_PATH="${MIGRATION_ENABLED_PATH:-/sys/kernel/mm/numa_balancing/migration_enabled}"
RESUME="${RESUME:-1}"
CLEAN_STAGE="${CLEAN_STAGE:-0}"
CLEAN_SCRIPTS="${CLEAN_SCRIPTS:-1}"
STAGE_WORKLOADS="${STAGE_WORKLOADS:-1}"
SSH_RETRY_ATTEMPTS="${SSH_RETRY_ATTEMPTS:-30}"
SSH_RETRY_DELAY_SEC="${SSH_RETRY_DELAY_SEC:-10}"
SSH_READY_ATTEMPTS="${SSH_READY_ATTEMPTS:-30}"
SSH_READY_DELAY_SEC="${SSH_READY_DELAY_SEC:-10}"
POST_STAGE_SSH_SETTLE_SEC="${POST_STAGE_SSH_SETTLE_SEC:-30}"
REBOOT_AFTER_STAGE="${REBOOT_AFTER_STAGE:-0}"
STOP_VM_ON_SUCCESS="${STOP_VM_ON_SUCCESS:-1}"
STOP_VM_ON_FAILURE="${STOP_VM_ON_FAILURE:-1}"
STOP_VM_ON_EXIT="${STOP_VM_ON_EXIT:-1}"
STOP_VM_WAIT_SEC="${STOP_VM_WAIT_SEC:-90}"
DRY_RUN="${DRY_RUN:-0}"

PR_ITERATIONS="${PR_ITERATIONS:-20}"
PR_TOLERANCE="${PR_TOLERANCE:-1e-4}"
PR_TRIALS="${PR_TRIALS:-8}"
BC_ITERATIONS="${BC_ITERATIONS:-1}"
BC_TRIALS="${BC_TRIALS:-8}"
GAPBS_GRAPH_SCALE="${GAPBS_GRAPH_SCALE:-29}"
DROP_GUEST_CACHES="${DROP_GUEST_CACHES:-1}"
COMPACT_GUEST_MEMORY="${COMPACT_GUEST_MEMORY:-1}"
DROP_HOST_CACHES_BEFORE_VM_BOOT="${DROP_HOST_CACHES_BEFORE_VM_BOOT:-1}"
DROP_HOST_CACHES_BEFORE_GUEST_RUN="${DROP_HOST_CACHES_BEFORE_GUEST_RUN:-1}"
GUPS_MEMORY_GB="${GUPS_MEMORY_GB:-64}"
GRAPH500_SCALE="${GRAPH500_SCALE:-28}"
XSBENCH_GRID="${XSBENCH_GRID:-130000}"
XSBENCH_PARTICLES="${XSBENCH_PARTICLES:-90000000}"
DELETE_VM_IMAGES="${DELETE_VM_IMAGES:-1}"
DISABLE_SMT="${DISABLE_SMT:-0}"
RESTORE_SMT="${RESTORE_SMT:-0}"
SILO_BIN_HOST="${SILO_BIN_HOST:-${BENCHMARK_DIR}/silo/out-perf.masstree/benchmarks/dbtest}"
SILO_LZ4_HOST="${SILO_LZ4_HOST:-${BENCHMARK_DIR}/silo/third-party/lz4/liblz4.so}"
SILO_ZIPF_THETA="${SILO_ZIPF_THETA:-}"
SILO_ZIPF_REVERSE="${SILO_ZIPF_REVERSE:-1}"
SILO_WORKLOAD_MIX="${SILO_WORKLOAD_MIX:-}"
LIBLINEAR_ROOT_HOST="${LIBLINEAR_ROOT_HOST:-${BENCHMARK_DIR}/liblinear-multicore-2.47}"
LIBLINEAR_DATASET="${LIBLINEAR_DATASET:-kdd12}"
LIBLINEAR_TRAIN_HOST="${LIBLINEAR_TRAIN_HOST:-${LIBLINEAR_ROOT_HOST}/train}"
LIBLINEAR_DATASET_HOST="${LIBLINEAR_DATASET_HOST:-${LIBLINEAR_ROOT_HOST}/datasets/${LIBLINEAR_DATASET}}"
LIBLINEAR_SOLVER="${LIBLINEAR_SOLVER:-6}"
LIBLINEAR_THREADS="${LIBLINEAR_THREADS:-${OMP_THREADS}}"

CURRENT_VM_NAME=""
CURRENT_LOCAL_SIZE_GIB=""
CURRENT_LOCAL_LABEL=""
CURRENT_FAST_MEM=""
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
  local subcmd="${1:-}"
  if VM_RUN_DIR="${VM_RUN_DIR_HOST}" "${VMCTL}" "$@"; then
    return 0
  fi
  local rc=$?
  case "${subcmd}" in
    boot|stop)
      if [[ "$(id -u)" != "0" ]]; then
        log "vmctl ${subcmd} failed, retrying with sudo -n"
        sudo -n env VM_RUN_DIR="${VM_RUN_DIR_HOST}" "${VMCTL}" "$@"
        return $?
      fi
      ;;
  esac
  return "${rc}"
}

qemu_active_pids_for_name() {
  local name="$1"
  ps -eo pid=,stat=,args= |
    awk -v name="${name}" '
      index($0, "qemu-system-") && index($0, "-name " name) {
        if ($2 !~ /^Z/) {
          print $1
        }
      }'
}

wait_qemu_stopped() {
  local name="$1" timeout="${2:-${STOP_VM_WAIT_SEC}}" elapsed=0
  local -a pids=()

  while ((elapsed < timeout)); do
    mapfile -t pids < <(qemu_active_pids_for_name "${name}")
    if ((${#pids[@]} == 0)); then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  mapfile -t pids < <(qemu_active_pids_for_name "${name}")
  printf 'active qemu pids after %ss for %s: %s\n' "${timeout}" "${name}" "${pids[*]:-none}" >&2
  return 1
}

kill_qemu_pids() {
  local signal="$1"
  shift
  (($# > 0)) || return 0

  if kill "-${signal}" "$@" 2>/dev/null; then
    return 0
  fi
  if [[ "$(id -u)" != "0" ]]; then
    sudo -n kill "-${signal}" "$@" 2>/dev/null
    return $?
  fi
  return 1
}

force_stop_qemu_name() {
  local name="$1"
  local -a pids=()

  mapfile -t pids < <(qemu_active_pids_for_name "${name}")
  if ((${#pids[@]} == 0)); then
    return 0
  fi

  printf 'force TERM qemu name=%s pids=%s\n' "${name}" "${pids[*]}"
  kill_qemu_pids TERM "${pids[@]}" || true
  if wait_qemu_stopped "${name}" 15; then
    return 0
  fi

  mapfile -t pids < <(qemu_active_pids_for_name "${name}")
  if ((${#pids[@]} == 0)); then
    return 0
  fi

  printf 'force KILL qemu name=%s pids=%s\n' "${name}" "${pids[*]}"
  kill_qemu_pids KILL "${pids[@]}" || true
  wait_qemu_stopped "${name}" 15
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
        printf '%s\n' off on tpp ours
        ;;
      off|on|tpp|ours)
        printf '%s\n' "${item}"
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
          pr bc gups btree graph500 silo
        ;;
      *)
        printf '%s\n' "${item}"
        ;;
    esac
  done | awk '!seen[$0]++'
}

configs_need_ours() {
  local config
  while read -r config; do
    [[ "${config}" == "ours" ]] && return 0
  done < <(expand_configs ${CONFIGS})
  return 1
}

drop_host_page_cache() {
  log "drop host page cache"
  sync || true
  as_root sh -c 'echo 3 > /proc/sys/vm/drop_caches'
}

config_fast_mem() {
  case "$1" in
    off|on|tpp|ours) printf '%s\n' "${CURRENT_FAST_MEM:-${MIGRATION_FAST_MEM}}" ;;
    *) die "unknown config '$1'" ;;
  esac
}

config_slow_mem() {
  case "$1" in
    off|on|tpp|ours) printf '%s\n' "${MIGRATION_SLOW_MEM}" ;;
    *) die "unknown config '$1'" ;;
  esac
}

config_fast_host_node() {
  case "$1" in
    off|on|tpp|ours) printf '%s\n' "${MIGRATION_FAST_HOST_NODE}" ;;
    *) die "unknown config '$1'" ;;
  esac
}

config_slow_host_node() {
  case "$1" in
    off|on|tpp|ours) printf '%s\n' "${MIGRATION_SLOW_HOST_NODE}" ;;
    *) die "unknown config '$1'" ;;
  esac
}

config_port() {
  case "$1" in
    off) printf '%s\n' "${OFF_PORT}" ;;
    on) printf '%s\n' "${ON_PORT}" ;;
    tpp) printf '%s\n' "${TPP_PORT}" ;;
    ours) printf '%s\n' "${OURS_PORT}" ;;
    *) die "unknown config '$1'" ;;
  esac
}

config_numa_balancing() {
  case "$1" in
    off) printf '0\n' ;;
    on|ours) printf '2\n' ;;
    tpp) printf '4\n' ;;
    *) die "unknown config '$1'" ;;
  esac
}

config_migration_enabled() {
  case "$1" in
    off) printf '0\n' ;;
    on|tpp|ours) printf '1\n' ;;
    *) die "unknown config '$1'" ;;
  esac
}

config_demotion_enabled() {
  case "$1" in
    off) printf 'false\n' ;;
    on|tpp|ours) printf 'true\n' ;;
    *) die "unknown config '$1'" ;;
  esac
}

config_placement() {
  case "$1" in
    off|on|tpp|ours) printf 'numactl --cpunodebind=0\n' ;;
    *) die "unknown config '$1'" ;;
  esac
}

cleanup_current_vm() {
  if [[ -n "${CURRENT_VM_NAME}" && "${STOP_VM_ON_EXIT}" == "1" && -x "${VMCTL}" ]]; then
    log "cleanup stop ${CURRENT_VM_NAME}"
    vmctl_cmd stop --name "${CURRENT_VM_NAME}" >/dev/null 2>&1 || true
    force_stop_qemu_name "${CURRENT_VM_NAME}" >/dev/null 2>&1 || true
    CURRENT_VM_NAME=""
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
NUMA scan:       ${NUMA_SCAN_SIZE_MB}MB, min period ${NUMA_SCAN_PERIOD_MIN_MS}ms
Local sample:    ${LOCAL_FAULT_SCAN_SIZE_MB}MB/${LOCAL_FAULT_SCAN_PERIOD_MS}ms
THP:             mode=${THP_MODE:-default} defrag=${THP_DEFRAG:-default}
Delete images:   ${DELETE_VM_IMAGES}
Forbid host n1:  ${FORBID_HOST_NODE1}
Ours controller: window=${WINDOW_SEC}s cycle=${CYCLE_WINDOW_MIN_SEC}-${CYCLE_WINDOW_MAX_SEC}s local_rate=${LOCAL_RATE} min_pages=${MIN_LOCAL_PAGES}/${MIN_REMOTE_PAGES} start_consecutive=${START_CONSECUTIVE} start_margin_pct=${START_CAPACITY_MARGIN_PCT} stop_capacity_ratio=${STOP_CAPACITY_RATIO_THRESHOLD} p75_stagnation=${P75_STAGNATION_REQUIRED_DECREASE_PCT}%/${P75_STAGNATION_REQUIRED_WINDOWS}windows restart=local+${P75_STAGNATION_RESTART_DEGRADATION_PCT}%+remote-${REMOTE_RESTART_IMPROVEMENT_PCT}%/${P75_STAGNATION_RESTART_REQUIRED_WINDOWS}windows nodes=${LOCAL_NODE}/${REMOTE_NODE}

VM plan:
EOF
  local config local_size
  for local_size in "${local_size_list[@]}"; do
    CURRENT_LOCAL_SIZE_GIB="${local_size}"
    CURRENT_LOCAL_LABEL="local${local_size}"
    CURRENT_FAST_MEM="${local_size}G"
    for config in "${config_list[@]}"; do
      printf '  %-7s %-5s port=%s fast=%s@host[%s] slow=%s@host[%s] numa=%s migration=%s demotion=%s placement="%s"\n' \
        "${CURRENT_LOCAL_LABEL}" "${config}" "$(config_port "${config}")" "$(config_fast_mem "${config}")" \
        "$(config_fast_host_node "${config}")" "$(config_slow_mem "${config}")" \
        "$(config_slow_host_node "${config}")" "$(config_numa_balancing "${config}")" \
        "$(config_migration_enabled "${config}")" "$(config_demotion_enabled "${config}")" \
        "$(config_placement "${config}")"
    done
  done

  printf '\nRun matrix:\n'
  local total=0 workload
  for local_size in "${local_size_list[@]}"; do
    for config in "${config_list[@]}"; do
      for workload in "${workload_list[@]}"; do
        printf '  local%-3s %-5s %s\n' "${local_size}" "${config}" "${workload}"
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
  if configs_need_ours; then
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
  if expand_workloads ${WORKLOADS} | grep -qx silo; then
    [[ -d "${BENCHMARK_DIR}/silo" ]] || die "missing Silo source tree: ${BENCHMARK_DIR}/silo"
  fi
  if expand_workloads ${WORKLOADS} | grep -qx liblinear; then
    [[ -d "${LIBLINEAR_ROOT_HOST}" ]] || die "missing Liblinear source tree: ${LIBLINEAR_ROOT_HOST}"
    [[ -f "${LIBLINEAR_DATASET_HOST}" ]] || die "missing Liblinear dataset: ${LIBLINEAR_DATASET_HOST}"
  fi
}

write_host_config() {
  mkdir -p "${IMAGES_DIR}" "${HOST_LOG_DIR}" "${GUEST_RESULTS_DIR}" "${SUMMARY_DIR}" "${VM_RUN_DIR_HOST}"
  {
    printf 'date_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'run_id=%s\n' "${RUN_ID}"
    printf 'required_protocol_doc=%s\n' "${ICCD_REQUIRED_PROTOCOL_DOC:-}"
    printf 'baseline_reference_doc=%s\n' "${ICCD_BASELINE_REFERENCE_DOC:-}"
    printf 'repo_root=%s\n' "${REPO_ROOT}"
    printf 'experiment_root=%s\n' "${EXP_ROOT}"
    printf 'kernel=%s\n' "${KERNEL}"
    printf 'kernel_cmdline_extra=%s\n' "${KERNEL_CMDLINE_EXTRA}"
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
    printf 'timeout_kill_after_sec=%s\n' "${TIMEOUT_KILL_AFTER_SEC}"
    printf 'omp_threads=%s\n' "${OMP_THREADS}"
    printf 'mglru_enabled=%s\n' "${MGLRU_ENABLED}"
    printf 'numa_scan_size_mb=%s\n' "${NUMA_SCAN_SIZE_MB}"
    printf 'numa_scan_period_min_ms=%s\n' "${NUMA_SCAN_PERIOD_MIN_MS}"
    printf 'numa_scan_period_max_ms=%s\n' "${NUMA_SCAN_PERIOD_MAX_MS}"
    printf 'numa_scan_delay_ms=%s\n' "${NUMA_SCAN_DELAY_MS}"
    printf 'local_fault_scan_period_ms=%s\n' "${LOCAL_FAULT_SCAN_PERIOD_MS}"
    printf 'local_fault_scan_size_mb=%s\n' "${LOCAL_FAULT_SCAN_SIZE_MB}"
    printf 'thp_mode=%s\n' "${THP_MODE}"
    printf 'thp_defrag=%s\n' "${THP_DEFRAG}"
    printf 'realworld_size_profile=%s\n' "${REALWORLD_SIZE_PROFILE}"
    printf 'verify_required_state=%s\n' "${VERIFY_REQUIRED_STATE}"
    printf 'disable_swap=%s\n' "${DISABLE_SWAP}"
    printf 'forbid_host_node1=%s\n' "${FORBID_HOST_NODE1}"
    printf 'fault_bucket_controller_dir=%s\n' "${FAULT_BUCKET_CONTROLLER_DIR}"
    printf 'window_sec=%s\n' "${WINDOW_SEC}"
    printf 'cycle_window_min_sec=%s\n' "${CYCLE_WINDOW_MIN_SEC}"
    printf 'cycle_window_max_sec=%s\n' "${CYCLE_WINDOW_MAX_SEC}"
    printf 'local_rate=%s\n' "${LOCAL_RATE}"
    printf 'min_local_pages=%s\n' "${MIN_LOCAL_PAGES}"
    printf 'min_remote_pages=%s\n' "${MIN_REMOTE_PAGES}"
    printf 'start_consecutive=%s\n' "${START_CONSECUTIVE}"
    printf 'start_capacity_margin_pct=%s\n' "${START_CAPACITY_MARGIN_PCT}"
    printf 'stop_capacity_ratio_threshold=%s\n' "${STOP_CAPACITY_RATIO_THRESHOLD}"
    printf 'p75_stagnation_required_decrease_pct=%s\n' "${P75_STAGNATION_REQUIRED_DECREASE_PCT}"
    printf 'p75_stagnation_required_windows=%s\n' "${P75_STAGNATION_REQUIRED_WINDOWS}"
    printf 'p75_stagnation_restart_degradation_pct=%s\n' "${P75_STAGNATION_RESTART_DEGRADATION_PCT}"
    printf 'p75_stagnation_restart_required_windows=%s\n' "${P75_STAGNATION_RESTART_REQUIRED_WINDOWS}"
    printf 'remote_restart_improvement_pct=%s\n' "${REMOTE_RESTART_IMPROVEMENT_PCT}"
    printf 'local_node=%s\n' "${LOCAL_NODE}"
    printf 'remote_node=%s\n' "${REMOTE_NODE}"
    printf 'migration_enabled_path=%s\n' "${MIGRATION_ENABLED_PATH}"
    printf 'gapbs_graph_mode=generated\n'
    printf 'gapbs_graph_scale=%s\n' "${GAPBS_GRAPH_SCALE}"
    printf 'gapbs_graph_path=generated:g%s\n' "${GAPBS_GRAPH_SCALE}"
    printf 'gapbs_data_disk=0\n'
    printf 'drop_guest_caches=%s\n' "${DROP_GUEST_CACHES}"
    printf 'compact_guest_memory=%s\n' "${COMPACT_GUEST_MEMORY}"
    printf 'drop_host_caches_before_vm_boot=%s\n' "${DROP_HOST_CACHES_BEFORE_VM_BOOT}"
    printf 'drop_host_caches_before_guest_run=%s\n' "${DROP_HOST_CACHES_BEFORE_GUEST_RUN}"
    printf 'graph_build_included=1\n'
    printf 'pr_trials=%s\n' "${PR_TRIALS}"
    printf 'bc_trials=%s\n' "${BC_TRIALS}"
    printf 'silo_bin_host=%s\n' "${SILO_BIN_HOST}"
    printf 'silo_zipf_theta=%s\n' "${SILO_ZIPF_THETA}"
    printf 'silo_zipf_reverse=%s\n' "${SILO_ZIPF_REVERSE}"
    printf 'silo_workload_mix=%s\n' "${SILO_WORKLOAD_MIX}"
    printf 'liblinear_train_host=%s\n' "${LIBLINEAR_TRAIN_HOST}"
    printf 'liblinear_dataset_host=%s\n' "${LIBLINEAR_DATASET_HOST}"
    printf 'liblinear_solver=%s\n' "${LIBLINEAR_SOLVER}"
    printf 'liblinear_threads=%s\n' "${LIBLINEAR_THREADS}"
    printf 'disable_smt=%s\n' "${DISABLE_SMT}"
    printf 'smt_control=%s\n' "$(read_smt_control)"
    printf 'delete_vm_images=%s\n' "${DELETE_VM_IMAGES}"
    printf 'stop_vm_wait_sec=%s\n' "${STOP_VM_WAIT_SEC}"
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
    --cmdline-extra "${KERNEL_CMDLINE_EXTRA}"
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
  if [[ "${DROP_HOST_CACHES_BEFORE_VM_BOOT}" == "1" ]]; then
    drop_host_page_cache
  fi
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
  env \
    VM_ACTION=stage \
    VMCTL="${VMCTL}" \
    PORT="$(config_port "${config}")" \
    HOST="${HOST}" \
    SSH_KEY="${SSH_KEY}" \
    WORKLOADS="${common_workloads}" \
    BENCHMARK_DIR="${BENCHMARK_DIR}" \
    GAPBS_GRAPH_SCALE="${GAPBS_GRAPH_SCALE}" \
    STAGE_GAPBS_GRAPH=0 \
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
  {
    ssh_vm_retry "${config}" "mkdir -p /root/vm32_realworld/scripts /root/design/fault_bucket_controller" || return $?
    copy_to_vm_retry "${config}" \
      "${SCRIPT_DIR}/run_vm_sweep_guest.sh" \
      "${SCRIPT_DIR}/run_workload_case_guest.sh" \
      /root/vm32_realworld/scripts/ || return $?
    if [[ "${config}" == "ours" ]]; then
      copy_to_vm_retry "${config}" \
        "${FAULT_BUCKET_CONTROLLER_DIR}/bucket_latency_controller.py" \
        "${FAULT_BUCKET_CONTROLLER_DIR}/run_guest.sh" \
        /root/design/fault_bucket_controller/ || return $?
    fi
    ssh_vm_retry "${config}" "chmod +x /root/vm32_realworld/scripts/run_vm_sweep_guest.sh /root/vm32_realworld/scripts/run_workload_case_guest.sh; find /root/design/fault_bucket_controller -maxdepth 1 -type f \\( -name '*.py' -o -name 'run_guest.sh' \\) -exec chmod +x {} +" || return $?
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
  local -a guest_env=(
    "OUTROOT=${guest_base}"
    "LOCAL_SIZE_GIB=${CURRENT_LOCAL_SIZE_GIB}"
    "CONFIGS=${config}"
    "WORKLOADS=${WORKLOADS}"
    "PROGRESS_BASE=${CURRENT_PROGRESS_BASE}"
    "PROGRESS_TOTAL=${TOTAL_WORKLOAD_CASES}"
    "TIMEOUT_SEC=${TIMEOUT_SEC}"
    "TIMEOUT_KILL_AFTER_SEC=${TIMEOUT_KILL_AFTER_SEC}"
    "OMP_THREADS=${OMP_THREADS}"
    "MGLRU_ENABLED=${MGLRU_ENABLED}"
    "NUMA_SCAN_SIZE_MB=${NUMA_SCAN_SIZE_MB}"
    "NUMA_SCAN_PERIOD_MIN_MS=${NUMA_SCAN_PERIOD_MIN_MS}"
    "NUMA_SCAN_PERIOD_MAX_MS=${NUMA_SCAN_PERIOD_MAX_MS}"
    "NUMA_SCAN_DELAY_MS=${NUMA_SCAN_DELAY_MS}"
    "LOCAL_FAULT_SCAN_PERIOD_MS=${LOCAL_FAULT_SCAN_PERIOD_MS}"
    "LOCAL_FAULT_SCAN_SIZE_MB=${LOCAL_FAULT_SCAN_SIZE_MB}"
    "THP_MODE=${THP_MODE}"
    "THP_DEFRAG=${THP_DEFRAG}"
    "REALWORLD_SIZE_PROFILE=${REALWORLD_SIZE_PROFILE}"
    "VERIFY_REQUIRED_STATE=${VERIFY_REQUIRED_STATE}"
    "DISABLE_SWAP=${DISABLE_SWAP}"
    "RESUME=${RESUME}"
    "BENCHMARK_DIR=/root/benchmark"
    "REALWORLD_CASE_RUNNER=/root/scripts/run_workload_case_guest.sh"
    "GAPBS_GRAPH_MODE=generated"
    "GAPBS_GRAPH_SCALE=${GAPBS_GRAPH_SCALE}"
    "DROP_GUEST_CACHES=${DROP_GUEST_CACHES}"
    "COMPACT_GUEST_MEMORY=${COMPACT_GUEST_MEMORY}"
    "PR_ITERATIONS=${PR_ITERATIONS}"
    "PR_TOLERANCE=${PR_TOLERANCE}"
    "PR_TRIALS=${PR_TRIALS}"
    "BC_ITERATIONS=${BC_ITERATIONS}"
    "BC_TRIALS=${BC_TRIALS}"
    "GUPS_MEMORY_GB=${GUPS_MEMORY_GB}"
    "GRAPH500_SCALE=${GRAPH500_SCALE}"
    "XSBENCH_GRID=${XSBENCH_GRID}"
    "XSBENCH_PARTICLES=${XSBENCH_PARTICLES}"
    "SILO_SCALE_FACTOR=${SILO_SCALE_FACTOR:-800000}"
    "SILO_OPS_PER_WORKER=${SILO_OPS_PER_WORKER:-100000000}"
    "SILO_ZIPF_THETA=${SILO_ZIPF_THETA}"
    "SILO_ZIPF_REVERSE=${SILO_ZIPF_REVERSE}"
    "SILO_WORKLOAD_MIX=${SILO_WORKLOAD_MIX}"
    "LIBLINEAR_DATASET=${LIBLINEAR_DATASET}"
    "LIBLINEAR_SOLVER=${LIBLINEAR_SOLVER}"
    "LIBLINEAR_THREADS=${LIBLINEAR_THREADS}"
    "WINDOW_SEC=${WINDOW_SEC}"
    "CYCLE_WINDOW_MIN_SEC=${CYCLE_WINDOW_MIN_SEC}"
    "CYCLE_WINDOW_MAX_SEC=${CYCLE_WINDOW_MAX_SEC}"
    "LOCAL_RATE=${LOCAL_RATE}"
    "MIN_LOCAL_PAGES=${MIN_LOCAL_PAGES}"
    "MIN_REMOTE_PAGES=${MIN_REMOTE_PAGES}"
    "START_CONSECUTIVE=${START_CONSECUTIVE}"
    "START_CAPACITY_MARGIN_PCT=${START_CAPACITY_MARGIN_PCT}"
    "STOP_CAPACITY_RATIO_THRESHOLD=${STOP_CAPACITY_RATIO_THRESHOLD}"
    "P75_STAGNATION_REQUIRED_DECREASE_PCT=${P75_STAGNATION_REQUIRED_DECREASE_PCT}"
    "P75_STAGNATION_REQUIRED_WINDOWS=${P75_STAGNATION_REQUIRED_WINDOWS}"
    "P75_STAGNATION_RESTART_DEGRADATION_PCT=${P75_STAGNATION_RESTART_DEGRADATION_PCT}"
    "P75_STAGNATION_RESTART_REQUIRED_WINDOWS=${P75_STAGNATION_RESTART_REQUIRED_WINDOWS}"
    "REMOTE_RESTART_IMPROVEMENT_PCT=${REMOTE_RESTART_IMPROVEMENT_PCT}"
    "LOCAL_NODE=${LOCAL_NODE}"
    "REMOTE_NODE=${REMOTE_NODE}"
    "MIGRATION_ENABLED_PATH=${MIGRATION_ENABLED_PATH}"
  )
  printf -v guest_cmd '%q ' env "${guest_env[@]}" \
    /root/vm32_realworld/scripts/run_vm_sweep_guest.sh

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
  local should_stop=0 vm_name="" stop_log=""
  if [[ "${rc}" == "0" && "${STOP_VM_ON_SUCCESS}" == "1" ]]; then
    should_stop=1
  elif [[ "${rc}" != "0" && "${STOP_VM_ON_FAILURE}" == "1" ]]; then
    should_stop=1
  fi
  if [[ "${should_stop}" == "1" && -n "${CURRENT_VM_NAME}" ]]; then
    vm_name="${CURRENT_VM_NAME}"
    stop_log="${HOST_LOG_DIR}/${CURRENT_LOCAL_LABEL}-${config}.stop.log"
    log "stop ${config} name=${vm_name}"
    vmctl_cmd stop --name "${vm_name}" > "${stop_log}" 2>&1 || true
    if ! wait_qemu_stopped "${vm_name}" "${STOP_VM_WAIT_SEC}" >> "${stop_log}" 2>&1; then
      log "force stop ${config} name=${vm_name}; previous QEMU still active"
      force_stop_qemu_name "${vm_name}" >> "${stop_log}" 2>&1 || {
        log "failed to stop ${config} name=${vm_name}; refusing to start next config"
        return 1
      }
    fi
    CURRENT_VM_NAME=""
  fi
}

restart_vm_after_stage() {
  local config="$1" overlay="$2" vm_name="" stop_log=""

  [[ "${REBOOT_AFTER_STAGE}" == "1" ]] || return 0
  [[ -n "${CURRENT_VM_NAME}" ]] || return 0

  vm_name="${CURRENT_VM_NAME}"
  stop_log="${HOST_LOG_DIR}/${CURRENT_LOCAL_LABEL}-${config}.restart-stop.log"
  log "reboot ${config} after staging name=${vm_name}"
  flush_guest_filesystems "${config}" || return $?
  vmctl_cmd stop --name "${vm_name}" > "${stop_log}" 2>&1 || true
  if ! wait_qemu_stopped "${vm_name}" "${STOP_VM_WAIT_SEC}" >> "${stop_log}" 2>&1; then
    log "force stop ${config} before reboot name=${vm_name}; previous QEMU still active"
    force_stop_qemu_name "${vm_name}" >> "${stop_log}" 2>&1 || {
      log "failed to stop ${config} before reboot name=${vm_name}"
      return 1
    }
  fi
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
  if [[ "${rc}" == "0" && "${DROP_HOST_CACHES_BEFORE_GUEST_RUN}" == "1" ]]; then
    drop_host_page_cache > "${HOST_LOG_DIR}/${CURRENT_LOCAL_LABEL}-${config}.drop-host-caches-before-run.log" 2>&1 || rc=$?
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

  log "plot controller results"
  : > "${HOST_LOG_DIR}/plot-controller.log"
  local controller_csv controller_dir
  while IFS= read -r -d '' controller_csv; do
    controller_dir="$(dirname "${controller_csv}")"
    if ! python3 "${FAULT_BUCKET_CONTROLLER_DIR}/plot_controller.py" \
      "${controller_csv}" \
      --out-dir "${controller_dir}/figures" \
      --prefix controller >> "${HOST_LOG_DIR}/plot-controller.log" 2>&1; then
      log "controller plot failed: ${controller_csv}"
    fi
  done < <(find "${GUEST_RESULTS_DIR}" -type f -path '*/controller/controller.csv' -print0)
}

main() {
  local -a config_list=()
  local -a local_size_list=()
  local -a workload_list=()
  local expanded_configs expanded_local_sizes expanded_workloads
  expanded_configs="$(expand_configs ${CONFIGS})"
  expanded_local_sizes="$(expand_local_sizes ${LOCAL_SIZES_GIB})"
  expanded_workloads="$(expand_workloads ${WORKLOADS})"
  mapfile -t config_list <<< "${expanded_configs}"
  mapfile -t local_size_list <<< "${expanded_local_sizes}"
  mapfile -t workload_list <<< "${expanded_workloads}"
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
