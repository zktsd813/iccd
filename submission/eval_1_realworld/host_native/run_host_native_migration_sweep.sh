#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename -- "${BASH_SOURCE[0]}")"
REPO_ROOT="${REPO_ROOT:-/Serverless/iccd-git}"

HOST_BOOT_SCRIPT="${HOST_BOOT_SCRIPT:-${SCRIPT_DIR}/host_boot_target.sh}"
STATE_ROOT="${STATE_ROOT:-/var/lib/iccd/eval1-host-native-migration-sweep}"
LOG_ROOT="${LOG_ROOT:-/var/log/iccd/eval1-host-native-migration-sweep}"
RESULTS_ROOT="${RESULTS_ROOT:-${SCRIPT_DIR}/results}"
STATE_FILE="${STATE_FILE:-${STATE_ROOT}/state.env}"
LOCK_FILE="${LOCK_FILE:-${STATE_ROOT}/runner.lock}"

LOCAL_NODE="${LOCAL_NODE:-0}"
REMOTE_NODE="${REMOTE_NODE:-1}"
KEEP_MEMORY_NODES="${KEEP_MEMORY_NODES:-1}"
OFFLINE_CPU_NODE="${OFFLINE_CPU_NODE:-1}"
CPU_NODE="${CPU_NODE:-0}"
TARGET_TOLERANCE_GIB="${TARGET_TOLERANCE_GIB:-1}"
TARGETS="${TARGETS:-16 32 48}"
MIGRATION_MODES="${MIGRATION_MODES:-off on tpp ours}"
WORKLOADS="${WORKLOADS:-pr bc gups btree graph500 silo liblinear}"

GAPBS_GRAPH_SCALE="${GAPBS_GRAPH_SCALE:-29}"
PR_BIN="${PR_BIN:-/Serverless/benchmark/gapbs/pr}"
BC_BIN="${BC_BIN:-/Serverless/benchmark/gapbs/bc}"
GUPS_BIN="${GUPS_BIN:-/Serverless/benchmark/vmitosis-workloads/bin/bench_gups_mt}"
BTREE_BIN="${BTREE_BIN:-/Serverless/benchmark/vmitosis-workloads/bin/bench_btree_mt}"
GRAPH500_BIN="${GRAPH500_BIN:-/Serverless/benchmark/vmitosis-workloads/bin/bench_graph500_mt}"
SILO_BIN="${SILO_BIN:-/Serverless/benchmark/silo/out-perf.masstree/benchmarks/dbtest}"
LIBLINEAR_TRAIN_BIN="${LIBLINEAR_TRAIN_BIN:-/Serverless/benchmark/liblinear-multicore-2.47/train}"
LIBLINEAR_DATASET="${LIBLINEAR_DATASET:-/Serverless/benchmark/liblinear-multicore-2.47/datasets/kdd12}"
NUMACTL_BIN="${NUMACTL_BIN:-/usr/bin/numactl}"
TIME_BIN="${TIME_BIN:-/usr/bin/time}"
IPMI_BIN="${IPMI_BIN:-/usr/bin/ipmitool}"
TMUX_BIN="${TMUX_BIN:-/usr/bin/tmux}"
TMUX_SESSION="${TMUX_SESSION:-eval1-host-native-sweep}"
TMUX_LOG="${TMUX_LOG:-${LOG_ROOT}/tmux-session.log}"

OMP_THREADS="${OMP_THREADS:-32}"
PR_ITERATIONS="${PR_ITERATIONS:-1000}"
PR_TOLERANCE="${PR_TOLERANCE:-1e-4}"
PR_TRIALS="${PR_TRIALS:-4}"
BC_ITERATIONS="${BC_ITERATIONS:-1}"
BC_TRIALS="${BC_TRIALS:-4}"
GRAPH500_SCALE="${GRAPH500_SCALE:-28}"
SILO_THREADS="${SILO_THREADS:-32}"
SILO_SCALE_FACTOR="${SILO_SCALE_FACTOR:-800000}"
SILO_OPS_PER_WORKER="${SILO_OPS_PER_WORKER:-100000000}"
LIBLINEAR_SOLVER="${LIBLINEAR_SOLVER:-6}"
LIBLINEAR_THREADS="${LIBLINEAR_THREADS:-32}"
POST_WORKLOAD_SLEEP_SEC="${POST_WORKLOAD_SLEEP_SEC:-5}"
RESUME_WAIT_SEC="${RESUME_WAIT_SEC:-90}"
VERIFY_RETRIES="${VERIFY_RETRIES:-6}"
VERIFY_RETRY_SLEEP_SEC="${VERIFY_RETRY_SLEEP_SEC:-30}"
RAPL_PACKAGE_DOMAIN="${RAPL_PACKAGE_DOMAIN:-package-0}"
RAPL_DRAM_DOMAIN="${RAPL_DRAM_DOMAIN:-dram}"
IPMI_POWER_SAMPLING="${IPMI_POWER_SAMPLING:-1}"
IPMI_POWER_INTERVAL_SEC="${IPMI_POWER_INTERVAL_SEC:-1}"
NUMA_SCAN_SIZE_MB="${NUMA_SCAN_SIZE_MB:-256}"
NUMA_SCAN_PERIOD_MIN_MS="${NUMA_SCAN_PERIOD_MIN_MS:-1000}"
LOCAL_FAULT_RATE="${LOCAL_FAULT_RATE:-5}"
LOCAL_FAULT_SCAN_PERIOD_MS="${LOCAL_FAULT_SCAN_PERIOD_MS:-1000}"
LOCAL_FAULT_SCAN_SIZE_MB="${LOCAL_FAULT_SCAN_SIZE_MB:-64}"
MGLRU_ENABLED="${MGLRU_ENABLED:-0x0007}"
THP_MODE="${THP_MODE:-never}"
THP_DEFRAG="${THP_DEFRAG:-never}"
DEMOTION_TARGETS="${DEMOTION_TARGETS:-0:1}"
FAULT_BUCKET_CONTROLLER_DIR="${FAULT_BUCKET_CONTROLLER_DIR:-${REPO_ROOT}/design/fault_bucket_controller}"
FAULT_BUCKET_CONTROLLER_RUNNER="${FAULT_BUCKET_CONTROLLER_RUNNER:-${FAULT_BUCKET_CONTROLLER_DIR}/run_guest.sh}"
OURS_WINDOW_SEC="${OURS_WINDOW_SEC:-1}"
OURS_CYCLE_WINDOW_MIN_SEC="${OURS_CYCLE_WINDOW_MIN_SEC:-5}"
OURS_CYCLE_WINDOW_MAX_SEC="${OURS_CYCLE_WINDOW_MAX_SEC:-20}"
OURS_MIGRATION_ENABLED_PATH="${OURS_MIGRATION_ENABLED_PATH:-/sys/kernel/mm/numa_balancing/migration_enabled}"
DISABLE_SWAP="${DISABLE_SWAP:-1}"
OURS_MIN_LOCAL_PAGES="${OURS_MIN_LOCAL_PAGES:-1024}"
OURS_MIN_REMOTE_PAGES="${OURS_MIN_REMOTE_PAGES:-1024}"
OURS_START_CONSECUTIVE="${OURS_START_CONSECUTIVE:-2}"
OURS_START_CAPACITY_MARGIN_PCT="${OURS_START_CAPACITY_MARGIN_PCT:-10}"
OURS_STOP_CAPACITY_RATIO_THRESHOLD="${OURS_STOP_CAPACITY_RATIO_THRESHOLD:-0.9}"
HOST_BOOT_CMDLINE_16G="${HOST_BOOT_CMDLINE_16G:-}"
HOST_BOOT_NODE0_ONLINE_16G="${HOST_BOOT_NODE0_ONLINE_16G:-}"
HOST_BOOT_CMDLINE_32G="${HOST_BOOT_CMDLINE_32G:-}"
HOST_BOOT_NODE0_ONLINE_32G="${HOST_BOOT_NODE0_ONLINE_32G:-}"
HOST_BOOT_CMDLINE_48G="${HOST_BOOT_CMDLINE_48G:-}"
HOST_BOOT_NODE0_ONLINE_48G="${HOST_BOOT_NODE0_ONLINE_48G:-}"

RUN_ID="${RUN_ID:-}"
TARGET_INDEX="${TARGET_INDEX:-0}"
MIGRATION_INDEX="${MIGRATION_INDEX:-0}"
WORKLOAD_INDEX="${WORKLOAD_INDEX:-0}"
IPMI_POWER_PID=""

usage() {
  cat <<'EOF'
Usage:
  run_host_native_migration_sweep.sh start
  run_host_native_migration_sweep.sh start-tmux
  run_host_native_migration_sweep.sh resume
  run_host_native_migration_sweep.sh resume-tmux
  run_host_native_migration_sweep.sh status
  run_host_native_migration_sweep.sh remove-hook

Runs host-native eval_1 workloads for memory targets 16G, 32G, and 48G, with
migration modes off/on/tpp/ours, minimizing reboots by finishing every workload for
a target before switching memory target.  By default the boot cmdline is
generated from the current host topology when switching targets;
HOST_BOOT_CMDLINE_<target>G may still be set to force a known-good static
cmdline.
EOF
}

log() {
  mkdir -p "${LOG_ROOT}" 2>/dev/null || true
  printf '[host-native-sweep] %s\n' "$*" >&2
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "${LOG_ROOT}/runner.log" 2>/dev/null || true
}

die() {
  log "error: $*"
  exit 2
}

require_root() {
  [[ "${EUID}" == "0" ]] || die "run as root"
}

split_words() {
  local value="$1"
  # shellcheck disable=SC2206
  SPLIT_WORDS=(${value})
}

validate_run_configuration() {
  local mode
  [[ "${GAPBS_GRAPH_SCALE}" == "29" ]] || die "GAPBS graph scale must be 29"
  split_words "${MIGRATION_MODES}"
  ((${#SPLIT_WORDS[@]} > 0)) || die "MIGRATION_MODES is empty"
  for mode in "${SPLIT_WORDS[@]}"; do
    case "${mode}" in
      off|on|tpp|ours) ;;
      *) die "unknown migration mode: ${mode}" ;;
    esac
  done
}

require_kernel_abi() {
  [[ -r /sys/kernel/mm/numa_balancing/fault_latency_quantiles ]] ||
    die "missing fault_latency_quantiles"
  [[ -r /sys/kernel/mm/numa_balancing/remote_scan_cycles ]] ||
    die "missing remote_scan_cycles"
  [[ -w /proc/sys/kernel/numa_balancing ]] ||
    die "kernel.numa_balancing is not writable"
  [[ -w "${OURS_MIGRATION_ENABLED_PATH}" ]] ||
    die "migration knob is not writable: ${OURS_MIGRATION_ENABLED_PATH}"
  [[ -w /sys/kernel/mm/numa/demotion_enabled ]] ||
    die "demotion_enabled is not writable"
}

save_state() {
  mkdir -p "${STATE_ROOT}" "${LOG_ROOT}" "${RESULTS_ROOT}"
  {
    printf 'RUN_ID=%q\n' "${RUN_ID}"
    printf 'TARGET_INDEX=%q\n' "${TARGET_INDEX}"
    printf 'MIGRATION_INDEX=%q\n' "${MIGRATION_INDEX}"
    printf 'WORKLOAD_INDEX=%q\n' "${WORKLOAD_INDEX}"
    printf 'LOCAL_NODE=%q\n' "${LOCAL_NODE}"
    printf 'REMOTE_NODE=%q\n' "${REMOTE_NODE}"
    printf 'KEEP_MEMORY_NODES=%q\n' "${KEEP_MEMORY_NODES}"
    printf 'OFFLINE_CPU_NODE=%q\n' "${OFFLINE_CPU_NODE}"
    printf 'CPU_NODE=%q\n' "${CPU_NODE}"
    printf 'TARGETS=%q\n' "${TARGETS}"
    printf 'MIGRATION_MODES=%q\n' "${MIGRATION_MODES}"
    printf 'WORKLOADS=%q\n' "${WORKLOADS}"
    printf 'RESULTS_ROOT=%q\n' "${RESULTS_ROOT}"
    printf 'GAPBS_GRAPH_SCALE=%q\n' "${GAPBS_GRAPH_SCALE}"
    printf 'PR_ITERATIONS=%q\n' "${PR_ITERATIONS}"
    printf 'PR_TOLERANCE=%q\n' "${PR_TOLERANCE}"
    printf 'PR_TRIALS=%q\n' "${PR_TRIALS}"
    printf 'BC_ITERATIONS=%q\n' "${BC_ITERATIONS}"
    printf 'BC_TRIALS=%q\n' "${BC_TRIALS}"
    printf 'GRAPH500_BIN=%q\n' "${GRAPH500_BIN}"
    printf 'GRAPH500_SCALE=%q\n' "${GRAPH500_SCALE}"
    printf 'VERIFY_RETRIES=%q\n' "${VERIFY_RETRIES}"
    printf 'VERIFY_RETRY_SLEEP_SEC=%q\n' "${VERIFY_RETRY_SLEEP_SEC}"
    printf 'HOST_BOOT_CMDLINE_16G=%q\n' "${HOST_BOOT_CMDLINE_16G}"
    printf 'HOST_BOOT_NODE0_ONLINE_16G=%q\n' "${HOST_BOOT_NODE0_ONLINE_16G}"
    printf 'HOST_BOOT_CMDLINE_32G=%q\n' "${HOST_BOOT_CMDLINE_32G}"
    printf 'HOST_BOOT_NODE0_ONLINE_32G=%q\n' "${HOST_BOOT_NODE0_ONLINE_32G}"
    printf 'HOST_BOOT_CMDLINE_48G=%q\n' "${HOST_BOOT_CMDLINE_48G}"
    printf 'HOST_BOOT_NODE0_ONLINE_48G=%q\n' "${HOST_BOOT_NODE0_ONLINE_48G}"
    printf 'NUMA_SCAN_SIZE_MB=%q\n' "${NUMA_SCAN_SIZE_MB}"
    printf 'NUMA_SCAN_PERIOD_MIN_MS=%q\n' "${NUMA_SCAN_PERIOD_MIN_MS}"
    printf 'LOCAL_FAULT_RATE=%q\n' "${LOCAL_FAULT_RATE}"
    printf 'LOCAL_FAULT_SCAN_PERIOD_MS=%q\n' "${LOCAL_FAULT_SCAN_PERIOD_MS}"
    printf 'LOCAL_FAULT_SCAN_SIZE_MB=%q\n' "${LOCAL_FAULT_SCAN_SIZE_MB}"
    printf 'MGLRU_ENABLED=%q\n' "${MGLRU_ENABLED}"
    printf 'THP_MODE=%q\n' "${THP_MODE}"
    printf 'THP_DEFRAG=%q\n' "${THP_DEFRAG}"
    printf 'DEMOTION_TARGETS=%q\n' "${DEMOTION_TARGETS}"
    printf 'FAULT_BUCKET_CONTROLLER_DIR=%q\n' "${FAULT_BUCKET_CONTROLLER_DIR}"
    printf 'FAULT_BUCKET_CONTROLLER_RUNNER=%q\n' "${FAULT_BUCKET_CONTROLLER_RUNNER}"
    printf 'OURS_WINDOW_SEC=%q\n' "${OURS_WINDOW_SEC}"
    printf 'OURS_CYCLE_WINDOW_MIN_SEC=%q\n' "${OURS_CYCLE_WINDOW_MIN_SEC}"
    printf 'OURS_CYCLE_WINDOW_MAX_SEC=%q\n' "${OURS_CYCLE_WINDOW_MAX_SEC}"
    printf 'OURS_MIGRATION_ENABLED_PATH=%q\n' "${OURS_MIGRATION_ENABLED_PATH}"
    printf 'DISABLE_SWAP=%q\n' "${DISABLE_SWAP}"
    printf 'OURS_MIN_LOCAL_PAGES=%q\n' "${OURS_MIN_LOCAL_PAGES}"
    printf 'OURS_MIN_REMOTE_PAGES=%q\n' "${OURS_MIN_REMOTE_PAGES}"
    printf 'OURS_START_CONSECUTIVE=%q\n' "${OURS_START_CONSECUTIVE}"
    printf 'OURS_START_CAPACITY_MARGIN_PCT=%q\n' "${OURS_START_CAPACITY_MARGIN_PCT}"
    printf 'OURS_STOP_CAPACITY_RATIO_THRESHOLD=%q\n' "${OURS_STOP_CAPACITY_RATIO_THRESHOLD}"
    printf 'SILO_BIN=%q\n' "${SILO_BIN}"
    printf 'SILO_THREADS=%q\n' "${SILO_THREADS}"
    printf 'SILO_SCALE_FACTOR=%q\n' "${SILO_SCALE_FACTOR}"
    printf 'SILO_OPS_PER_WORKER=%q\n' "${SILO_OPS_PER_WORKER}"
    printf 'LIBLINEAR_TRAIN_BIN=%q\n' "${LIBLINEAR_TRAIN_BIN}"
    printf 'LIBLINEAR_DATASET=%q\n' "${LIBLINEAR_DATASET}"
    printf 'LIBLINEAR_SOLVER=%q\n' "${LIBLINEAR_SOLVER}"
    printf 'LIBLINEAR_THREADS=%q\n' "${LIBLINEAR_THREADS}"
    printf 'updated_utc=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "${STATE_FILE}"
}

load_state() {
  [[ -r "${STATE_FILE}" ]] || die "state not found; run start first"
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
}

run_dir() {
  printf '%s/%s\n' "${RESULTS_ROOT}" "${RUN_ID}"
}

summary_path() {
  printf '%s/summary.tsv\n' "$(run_dir)"
}

install_reboot_hook() {
  require_root
  mkdir -p "${STATE_ROOT}" "${LOG_ROOT}"
  local marker_begin="# ICCD_EVAL1_HOST_NATIVE_SWEEP_BEGIN"
  local marker_end="# ICCD_EVAL1_HOST_NATIVE_SWEEP_END"
  local cmd="cd ${REPO_ROOT@Q} && sleep ${RESUME_WAIT_SEC@Q} && exec env TMUX_BIN=${TMUX_BIN@Q} TMUX_SESSION=${TMUX_SESSION@Q} TMUX_LOG=${TMUX_LOG@Q} ${SCRIPT_PATH@Q} resume-tmux >> ${LOG_ROOT@Q}/reboot-resume.log 2>&1"
  local tmp
  tmp="$(mktemp)"
  {
    crontab -l 2>/dev/null | awk -v begin="${marker_begin}" -v end="${marker_end}" '
      $0 == begin {skip=1; next}
      $0 == end {skip=0; next}
      !skip {print}
    '
    printf '%s\n' "${marker_begin}"
    printf '@reboot /bin/bash -lc %q\n' "${cmd}"
    printf '%s\n' "${marker_end}"
  } > "${tmp}"
  crontab "${tmp}"
  rm -f "${tmp}"
  log "installed @reboot sweep resume hook"
}

remove_reboot_hook() {
  [[ "${EUID}" == "0" ]] || return 0
  local marker_begin="# ICCD_EVAL1_HOST_NATIVE_SWEEP_BEGIN"
  local marker_end="# ICCD_EVAL1_HOST_NATIVE_SWEEP_END"
  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | awk -v begin="${marker_begin}" -v end="${marker_end}" '
    $0 == begin {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
  ' > "${tmp}"
  crontab "${tmp}" || true
  rm -f "${tmp}"
  log "removed @reboot sweep resume hook"
}

tmux_env_prefix() {
  local name
  local -a names=(
    RUN_ID TARGETS MIGRATION_MODES WORKLOADS RESULTS_ROOT
    LOCAL_NODE REMOTE_NODE KEEP_MEMORY_NODES OFFLINE_CPU_NODE CPU_NODE
    GAPBS_GRAPH_SCALE
    PR_ITERATIONS PR_TOLERANCE PR_TRIALS BC_ITERATIONS BC_TRIALS
    GRAPH500_BIN GRAPH500_SCALE
    SILO_BIN SILO_THREADS SILO_SCALE_FACTOR SILO_OPS_PER_WORKER
    LIBLINEAR_TRAIN_BIN LIBLINEAR_DATASET LIBLINEAR_SOLVER LIBLINEAR_THREADS
    TMUX_BIN TMUX_SESSION TMUX_LOG
    HOST_BOOT_CMDLINE_16G HOST_BOOT_NODE0_ONLINE_16G
    HOST_BOOT_CMDLINE_32G HOST_BOOT_NODE0_ONLINE_32G
    HOST_BOOT_CMDLINE_48G HOST_BOOT_NODE0_ONLINE_48G
    NUMA_SCAN_SIZE_MB NUMA_SCAN_PERIOD_MIN_MS
    LOCAL_FAULT_RATE LOCAL_FAULT_SCAN_PERIOD_MS LOCAL_FAULT_SCAN_SIZE_MB
    MGLRU_ENABLED THP_MODE THP_DEFRAG DEMOTION_TARGETS
    FAULT_BUCKET_CONTROLLER_DIR FAULT_BUCKET_CONTROLLER_RUNNER
    OURS_WINDOW_SEC OURS_CYCLE_WINDOW_MIN_SEC OURS_CYCLE_WINDOW_MAX_SEC
    OURS_MIGRATION_ENABLED_PATH DISABLE_SWAP
    OURS_MIN_LOCAL_PAGES OURS_MIN_REMOTE_PAGES
    OURS_START_CONSECUTIVE OURS_START_CAPACITY_MARGIN_PCT
    OURS_STOP_CAPACITY_RATIO_THRESHOLD
  )
  for name in "${names[@]}"; do
    printf '%s=%q ' "${name}" "${!name}"
  done
}

start_tmux_run() {
  local subcmd="$1"
  require_root
  [[ -x "${TMUX_BIN}" ]] || die "missing executable tmux: ${TMUX_BIN}"
  mkdir -p "${STATE_ROOT}" "${LOG_ROOT}" "${RESULTS_ROOT}"
  if "${TMUX_BIN}" has-session -t "${TMUX_SESSION}" 2>/dev/null; then
    log "tmux session already exists: ${TMUX_SESSION}"
    return 0
  fi

  local env_prefix cmd shell_cmd
  env_prefix="$(tmux_env_prefix)"
  cmd="set -o pipefail; cd ${REPO_ROOT@Q} && ${env_prefix}${SCRIPT_PATH@Q} ${subcmd@Q} 2>&1 | tee -a ${TMUX_LOG@Q}"
  printf -v shell_cmd '/bin/bash -lc %q' "${cmd}"
  "${TMUX_BIN}" new-session -d -s "${TMUX_SESSION}" "${shell_cmd}"
  log "started tmux session=${TMUX_SESSION} cmd=${subcmd}"
}

drop_caches() {
  sync || true
  if [[ -w /proc/sys/vm/drop_caches ]]; then
    printf '3\n' > /proc/sys/vm/drop_caches
  fi
}

disable_swap_if_requested() {
  if [[ "${DISABLE_SWAP}" != "1" ]]; then
    return 0
  fi
  if swapon --noheadings --show=NAME 2>/dev/null | grep -q .; then
    log "disable swap before workload"
    swapoff -a || log "warning: swapoff -a failed"
  fi
}

node_memfree_mib() {
  local node="$1"
  awk -v node="${node}" '
    $1 == "Node" && $2 == node && $3 == "MemFree:" {
      print int($4 / 1024); found = 1
    }
    END { if (!found) exit 1 }
  ' "/sys/devices/system/node/node${node}/meminfo"
}

memory_block_mib() {
  local raw
  raw="$(cat /sys/devices/system/memory/block_size_bytes)"
  raw="${raw#0x}"
  printf '%d\n' $((16#${raw} / 1024 / 1024))
}

target_tolerance_mib() {
  local configured_mib block_mib
  configured_mib=$((TARGET_TOLERANCE_GIB * 1024))
  block_mib="$(memory_block_mib)"
  (( configured_mib < block_mib )) && configured_mib="${block_mib}"
  printf '%s\n' "${configured_mib}"
}

target_ok() {
  local target="$1"
  local free_mib tolerance_mib lower upper
  free_mib="$(node_memfree_mib "${LOCAL_NODE}")"
  tolerance_mib="$(target_tolerance_mib)"
  lower=$((target * 1024 - tolerance_mib))
  upper=$((target * 1024 + tolerance_mib))
  (( free_mib >= lower && free_mib <= upper ))
}

write_sysfs_if_writable() {
  local path="$1" value="$2"
  [[ -w "${path}" ]] || return 0
  printf '%s\n' "${value}" > "${path}" || true
}

demotion_target_for_wrapper() {
  local first="${DEMOTION_TARGETS%% *}"
  if [[ "${first}" == *:* ]]; then
    printf '%s %s\n' "${first%%:*}" "${first#*:}"
  else
    printf '%s\n' "${first}"
  fi
}

WRAPPED_RC=""
WRAPPED_ELAPSED=""

run_controller_wrapped_workload() {
  local target="$1" migration="$2" workload="$3" outdir="$4"
  local controller_outdir wrapper_rc status_rc workload_command_quoted
  local -a wrapper_env

  [[ -x "${FAULT_BUCKET_CONTROLLER_RUNNER}" ]] ||
    die "missing executable fault bucket controller runner: ${FAULT_BUCKET_CONTROLLER_RUNNER}"

  controller_outdir="${outdir}/controller"
  mkdir -p "${controller_outdir}"
  printf -v workload_command_quoted '%q ' "${WORKLOAD_CMD[@]}"

  wrapper_env=(
    env
    "OUTDIR=${controller_outdir}"
    "RUN_NAME=${migration}-${workload}"
    "WORKLOAD_COMMAND=${workload_command_quoted}"
    "CPU_NODE=${CPU_NODE}"
    "OMP_THREADS=${OMP_THREADS}"
    "WINDOW_SEC=${OURS_WINDOW_SEC}"
    "CYCLE_WINDOW_MIN_SEC=${OURS_CYCLE_WINDOW_MIN_SEC}"
    "CYCLE_WINDOW_MAX_SEC=${OURS_CYCLE_WINDOW_MAX_SEC}"
    "LOCAL_RATE=${LOCAL_FAULT_RATE}"
    "LOCAL_FAULT_SCAN_PERIOD_MS=${LOCAL_FAULT_SCAN_PERIOD_MS}"
    "LOCAL_FAULT_SCAN_SIZE_MB=${LOCAL_FAULT_SCAN_SIZE_MB}"
    "MIN_LOCAL_PAGES=${OURS_MIN_LOCAL_PAGES}"
    "MIN_REMOTE_PAGES=${OURS_MIN_REMOTE_PAGES}"
    "START_CONSECUTIVE=${OURS_START_CONSECUTIVE}"
    "START_CAPACITY_MARGIN_PCT=${OURS_START_CAPACITY_MARGIN_PCT}"
    "STOP_CAPACITY_RATIO_THRESHOLD=${OURS_STOP_CAPACITY_RATIO_THRESHOLD}"
    "LOCAL_NODE=${LOCAL_NODE}"
    "REMOTE_NODE=${REMOTE_NODE}"
    "MIGRATION_ENABLED_PATH=${OURS_MIGRATION_ENABLED_PATH}"
    "MGLRU_ENABLED=${MGLRU_ENABLED}"
    "DEMOTION_ENABLED=true"
    "DEMOTION_TARGET=$(demotion_target_for_wrapper)"
    "NUMA_SCAN_SIZE_MB=${NUMA_SCAN_SIZE_MB}"
    "NUMA_SCAN_PERIOD_MIN_MS=${NUMA_SCAN_PERIOD_MIN_MS}"
    "THP_MODE=${THP_MODE}"
    "THP_DEFRAG=${THP_DEFRAG}"
    "${FAULT_BUCKET_CONTROLLER_RUNNER}"
  )

  {
    printf 'wrapper_command='
    printf '%q ' "${wrapper_env[@]}"
    printf '\n'
    printf 'controller_outdir=%s\n' "${controller_outdir}"
    printf 'controller_csv=%s\n' "${controller_outdir}/controller.csv"
    printf 'controller_runner=%s\n' "${FAULT_BUCKET_CONTROLLER_RUNNER}"
    printf 'controller_window_sec=%s\n' "${OURS_WINDOW_SEC}"
    printf 'controller_cycle_window_min_sec=%s\n' "${OURS_CYCLE_WINDOW_MIN_SEC}"
    printf 'controller_cycle_window_max_sec=%s\n' "${OURS_CYCLE_WINDOW_MAX_SEC}"
    printf 'controller_local_rate=%s\n' "${LOCAL_FAULT_RATE}"
    printf 'controller_local_fault_scan_period_ms=%s\n' "${LOCAL_FAULT_SCAN_PERIOD_MS}"
    printf 'controller_local_fault_scan_size_mb=%s\n' "${LOCAL_FAULT_SCAN_SIZE_MB}"
    printf 'controller_min_local_pages=%s\n' "${OURS_MIN_LOCAL_PAGES}"
    printf 'controller_min_remote_pages=%s\n' "${OURS_MIN_REMOTE_PAGES}"
    printf 'controller_start_consecutive=%s\n' "${OURS_START_CONSECUTIVE}"
    printf 'controller_start_capacity_margin_pct=%s\n' "${OURS_START_CAPACITY_MARGIN_PCT}"
    printf 'controller_stop_capacity_ratio_threshold=%s\n' "${OURS_STOP_CAPACITY_RATIO_THRESHOLD}"
    printf 'controller_local_node=%s\n' "${LOCAL_NODE}"
    printf 'controller_remote_node=%s\n' "${REMOTE_NODE}"
    printf 'controller_workload_command=%s\n' "${workload_command_quoted}"
    printf 'controller_migration_enabled_path=%s\n' "${OURS_MIGRATION_ENABLED_PATH}"
  } > "${outdir}/controller.env"

  log "run quantile controller target=${target}G mode=${migration} workload=${workload}"
  set +e
  "${wrapper_env[@]}"
  wrapper_rc=$?
  set -e

  status_rc=""
  if [[ -r "${controller_outdir}/exit.status" ]]; then
    status_rc="$(cat "${controller_outdir}/exit.status")"
  fi
  [[ "${status_rc}" =~ ^[0-9]+$ ]] || status_rc="${wrapper_rc}"
  WRAPPED_RC="${status_rc}"
  WRAPPED_ELAPSED=""

  {
    printf '### controller workload stdout\n'
    cat "${controller_outdir}/stdout.txt" 2>/dev/null || true
    printf '\n### controller workload stderr\n'
    cat "${controller_outdir}/stderr.txt" 2>/dev/null || true
    printf '\n### controller time\n'
    cat "${controller_outdir}/time.txt" 2>/dev/null || true
  } > "${outdir}/workload.stdout.txt"
  printf '%s\n' "${wrapper_rc}" > "${outdir}/wrapper.rc"
  ln -sf controller/controller.csv "${outdir}/controller.csv" 2>/dev/null || true
  ln -sf controller/config.meta "${outdir}/controller.config.meta" 2>/dev/null || true
  ln -sf controller/time.txt "${outdir}/controller.time.txt" 2>/dev/null || true
}

apply_runtime_knobs() {
  mkdir -p /sys/kernel/debug
  mountpoint -q /sys/kernel/debug ||
    mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
  write_sysfs_if_writable /sys/kernel/debug/sched/numa_balancing/scan_size_mb "${NUMA_SCAN_SIZE_MB}"
  write_sysfs_if_writable /sys/kernel/debug/sched/numa_balancing/scan_period_min_ms "${NUMA_SCAN_PERIOD_MIN_MS}"
  write_sysfs_if_writable /sys/kernel/mm/transparent_hugepage/enabled "${THP_MODE}"
  write_sysfs_if_writable /sys/kernel/mm/transparent_hugepage/defrag "${THP_DEFRAG}"
  write_sysfs_if_writable /sys/kernel/mm/lru_gen/enabled "${MGLRU_ENABLED}"

  local pair src dst
  if [[ -w /sys/kernel/mm/numa/demotion_target ]]; then
    for pair in ${DEMOTION_TARGETS}; do
      src="${pair%%:*}"
      dst="${pair#*:}"
      [[ -n "${src}" && -n "${dst}" && "${src}" != "${dst}" ]] || continue
      printf '%s %s\n' "${src}" "${dst}" > /sys/kernel/mm/numa/demotion_target || true
    done
  fi
}

wait_for_converge_if_running() {
  local waited=0
  while pgrep -af 'host_boot_target.sh converge' >/dev/null 2>&1; do
    log "host boot convergence is still running; wait ${RESUME_WAIT_SEC}s"
    sleep "${RESUME_WAIT_SEC}"
    waited=$((waited + RESUME_WAIT_SEC))
    if (( waited > 7200 )); then
      die "host boot convergence did not finish within 7200s"
    fi
  done
}

target_static_cmdline() {
  local target="$1" var value
  var="HOST_BOOT_CMDLINE_${target}G"
  value="${!var-}"
  printf '%s\n' "${value}"
}

target_static_online_gib() {
  local target="$1" var value
  var="HOST_BOOT_NODE0_ONLINE_${target}G"
  value="${!var-}"
  printf '%s\n' "${value}"
}

converge_current_target_and_reboot() {
  local target="$1" reason="$2"
  log "${reason}; preserving current boot plan and rebooting for target=${target}G convergence"
  save_state
  LOCAL_NODE="${LOCAL_NODE}" KEEP_MEMORY_NODES="${KEEP_MEMORY_NODES}" \
    OFFLINE_CPU_NODE="${OFFLINE_CPU_NODE}" MAX_REBOOTS=4 \
    ICCD_FROM_REBOOT_HOOK=1 VERIFY_WARMUP_PR_AFTER_REBOOT=0 \
    "${HOST_BOOT_SCRIPT}" converge --target-gib "${target}" --apply --reboot
  exit 0
}

apply_target_boot_and_reboot() {
  local target="$1"
  local cmdline online_gib
  cmdline="$(target_static_cmdline "${target}")"
  online_gib="$(target_static_online_gib "${target}")"
  save_state
  if [[ -n "${cmdline}" && -n "${online_gib}" ]]; then
    log "switching to target=${target}G with current-host boot cmdline and rebooting"
    LOCAL_NODE="${LOCAL_NODE}" KEEP_MEMORY_NODES="${KEEP_MEMORY_NODES}" \
      OFFLINE_CPU_NODE="${OFFLINE_CPU_NODE}" MAX_REBOOTS=4 \
      VERIFY_WARMUP_PR_AFTER_REBOOT=0 \
      BOOT_CMDLINE_OVERRIDE="${cmdline}" \
      "${HOST_BOOT_SCRIPT}" apply --target-gib "${target}" --node0-online-gib "${online_gib}" --apply --reboot
  else
    log "switching to target=${target}G; no static cmdline configured, starting convergence and reboot"
    LOCAL_NODE="${LOCAL_NODE}" KEEP_MEMORY_NODES="${KEEP_MEMORY_NODES}" \
      OFFLINE_CPU_NODE="${OFFLINE_CPU_NODE}" MAX_REBOOTS=4 \
      VERIFY_WARMUP_PR_AFTER_REBOOT=0 \
      "${HOST_BOOT_SCRIPT}" converge --target-gib "${target}" --apply --reboot
  fi
  exit 0
}

verify_target_or_reboot() {
  local target="$1"
  local outdir="$2"
  local attempt verify_log
  mkdir -p "${outdir}"

  wait_for_converge_if_running
  for attempt in $(seq 1 "${VERIFY_RETRIES}"); do
    drop_caches
    verify_log="${outdir}/verify.target${target}g.attempt${attempt}.txt"
    if DROP_CACHES_BEFORE_VERIFY=1 TARGET_TOLERANCE_GIB="${TARGET_TOLERANCE_GIB}" \
        LOCAL_NODE="${LOCAL_NODE}" KEEP_MEMORY_NODES="${KEEP_MEMORY_NODES}" \
        OFFLINE_CPU_NODE="${OFFLINE_CPU_NODE}" \
        "${HOST_BOOT_SCRIPT}" verify --target-gib "${target}" > "${verify_log}" 2>&1; then
      cp /proc/cmdline "${outdir}/proc.cmdline.txt" 2>/dev/null || true
      return 0
    fi
    log "target ${target}G not ready before workload; attempt=${attempt}; see ${verify_log}"
    if (( attempt < VERIFY_RETRIES )); then
      sleep "${VERIFY_RETRY_SLEEP_SEC}"
    fi
  done

  converge_current_target_and_reboot "${target}" "target ${target}G is not in window after ${VERIFY_RETRIES} verify attempts"
}

set_migration_mode() {
  local mode="$1"
  local expected_numa expected_migration expected_demotion
  local actual_numa actual_migration actual_demotion
  case "${mode}" in
    off)
      expected_numa=0
      expected_migration=0
      expected_demotion=false
      ;;
    on)
      expected_numa=2
      expected_migration=1
      expected_demotion=true
      ;;
    tpp)
      expected_numa=4
      expected_migration=1
      expected_demotion=true
      ;;
    ours)
      expected_numa=2
      expected_migration=1
      expected_demotion=true
      write_sysfs_if_writable /sys/kernel/mm/numa_balancing/local_fault_scan_period_ms "${LOCAL_FAULT_SCAN_PERIOD_MS}"
      write_sysfs_if_writable /sys/kernel/mm/numa_balancing/local_fault_scan_size_mb "${LOCAL_FAULT_SCAN_SIZE_MB}"
      ;;
    *)
      die "unknown migration mode: ${mode}"
      ;;
  esac

  printf '%s\n' "${expected_numa}" > /proc/sys/kernel/numa_balancing
  write_sysfs_if_writable "${OURS_MIGRATION_ENABLED_PATH}" "${expected_migration}"
  write_sysfs_if_writable /sys/kernel/mm/numa/demotion_enabled "${expected_demotion}"
  if [[ "${mode}" == "ours" ]]; then
    write_sysfs_if_writable /sys/kernel/mm/numa_balancing/local_fault_rate "${LOCAL_FAULT_RATE}"
  else
    write_sysfs_if_writable /sys/kernel/mm/numa_balancing/local_fault_rate 0
  fi

  actual_numa="$(tr -d '[:space:]' < /proc/sys/kernel/numa_balancing)"
  actual_migration="$(tr -d '[:space:]' < "${OURS_MIGRATION_ENABLED_PATH}")"
  actual_demotion="$(tr -d '[:space:]' < /sys/kernel/mm/numa/demotion_enabled)"
  [[ "${actual_numa}" == "${expected_numa}" ]] ||
    die "${mode}: NUMA balancing readback ${actual_numa}, expected ${expected_numa}"
  [[ "${actual_migration}" == "${expected_migration}" ]] ||
    die "${mode}: migration readback ${actual_migration}, expected ${expected_migration}"
  [[ "${actual_demotion}" == "${expected_demotion}" ]] ||
    die "${mode}: demotion readback ${actual_demotion}, expected ${expected_demotion}"
}

snapshot_common() {
  local outdir="$1" phase="$2"
  mkdir -p "${outdir}"
  cat /proc/sys/kernel/numa_balancing > "${outdir}/numa_balancing.${phase}.txt" 2>/dev/null || true
  cat "${OURS_MIGRATION_ENABLED_PATH}" > "${outdir}/migration_enabled.${phase}.txt" 2>/dev/null || true
  swapon --show > "${outdir}/swapon.${phase}.txt" 2>/dev/null || true
  cat /sys/kernel/debug/sched/numa_balancing/scan_size_mb > "${outdir}/scan_size_mb.${phase}.txt" 2>/dev/null || true
  cat /sys/kernel/debug/sched/numa_balancing/scan_period_min_ms > "${outdir}/scan_period_min_ms.${phase}.txt" 2>/dev/null || true
  cat /sys/kernel/mm/numa/demotion_enabled > "${outdir}/demotion_enabled.${phase}.txt" 2>/dev/null || true
  cat /sys/kernel/mm/numa/demotion_target > "${outdir}/demotion_target.${phase}.txt" 2>/dev/null || true
  for name in \
    local_fault_rate \
    local_fault_scan_period_ms \
    local_fault_scan_size_mb \
    local_fault_window \
    remote_scan_cycles \
    fault_latency_quantiles; do
    cat "/sys/kernel/mm/numa_balancing/${name}" > "${outdir}/${name}.${phase}.txt" 2>/dev/null || true
  done
  cat "/sys/devices/system/node/node${LOCAL_NODE}/meminfo" > "${outdir}/node${LOCAL_NODE}.meminfo.${phase}.txt" 2>/dev/null || true
  cat "/sys/devices/system/node/node${REMOTE_NODE}/meminfo" > "${outdir}/node${REMOTE_NODE}.meminfo.${phase}.txt" 2>/dev/null || true
  cat /proc/vmstat > "${outdir}/vmstat.${phase}.txt" 2>/dev/null || true
  free -h > "${outdir}/free.${phase}.txt" 2>/dev/null || true
}

rapl_domain_path() {
  local domain="$1" d name
  for d in /sys/class/powercap/intel-rapl:*; do
    [[ -r "${d}/name" ]] || continue
    name="$(cat "${d}/name" 2>/dev/null || true)"
    if [[ "${name}" == "${domain}" ]]; then
      printf '%s\n' "${d}"
      return 0
    fi
  done
  return 1
}

rapl_read_value() {
  local domain="$1" file="$2" path
  path="$(rapl_domain_path "${domain}")" || return 1
  [[ -r "${path}/${file}" ]] || return 1
  cat "${path}/${file}"
}

rapl_delta_uj() {
  local start="$1" end="$2" max="$3"
  [[ "${start}" =~ ^[0-9]+$ && "${end}" =~ ^[0-9]+$ ]] || return 1
  if (( end >= start )); then
    printf '%s\n' $((end - start))
  elif [[ "${max}" =~ ^[0-9]+$ && "${max}" -gt 0 ]]; then
    printf '%s\n' $((end + max - start))
  else
    return 1
  fi
}

uj_to_j() {
  awk -v uj="${1:-}" 'BEGIN { if (uj ~ /^[0-9]+$/) printf "%.6f", uj / 1000000; }'
}

j_to_avg_w() {
  awk -v joules="${1:-}" -v elapsed="${2:-0}" \
    'BEGIN { if (joules != "" && elapsed > 0) printf "%.6f", joules / elapsed; }'
}

write_rapl_snapshot() {
  local outdir="$1" phase="$2" domain path energy max
  local file="${outdir}/rapl.${phase}.tsv"
  printf 'domain\tpath\tenergy_uj\tmax_energy_range_uj\n' > "${file}"
  for domain in "${RAPL_PACKAGE_DOMAIN}" "${RAPL_DRAM_DOMAIN}"; do
    path="$(rapl_domain_path "${domain}" 2>/dev/null || true)"
    [[ -n "${path}" ]] || continue
    energy="$(cat "${path}/energy_uj" 2>/dev/null || true)"
    max="$(cat "${path}/max_energy_range_uj" 2>/dev/null || true)"
    printf '%s\t%s\t%s\t%s\n' "${domain}" "${path}" "${energy}" "${max}" >> "${file}"
  done
}

start_ipmi_power_sampler() {
  local outdir="$1" csv="${outdir}/ipmi_power.csv"
  IPMI_POWER_PID=""
  [[ "${IPMI_POWER_SAMPLING}" == "1" ]] || return 0
  [[ -x "${IPMI_BIN}" ]] || return 0
  (
    printf 'epoch,power_w\n'
    while :; do
      now="$(date +%s)"
      power="$("${IPMI_BIN}" dcmi power reading 2>/dev/null | awk -F: '
        /Instantaneous power reading/ {
          gsub(/ Watts/, "", $2)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
          print $2
          exit
        }'
      )"
      if [[ "${power}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        printf '%s,%s\n' "${now}" "${power}"
      fi
      sleep "${IPMI_POWER_INTERVAL_SEC}"
    done
  ) > "${csv}" 2> "${outdir}/ipmi_power.stderr.txt" &
  IPMI_POWER_PID="$!"
}

stop_ipmi_power_sampler() {
  if [[ -n "${IPMI_POWER_PID}" ]] && kill -0 "${IPMI_POWER_PID}" 2>/dev/null; then
    kill "${IPMI_POWER_PID}" 2>/dev/null || true
    wait "${IPMI_POWER_PID}" 2>/dev/null || true
  fi
  IPMI_POWER_PID=""
}

summarize_ipmi_power() {
  local csv="$1" elapsed="$2"
  awk -F, -v elapsed="${elapsed}" '
    NR > 1 && $2 ~ /^[0-9.]+$/ {
      sum += $2
      n += 1
      if (n == 1 || $2 < min) min = $2
      if (n == 1 || $2 > max) max = $2
    }
    END {
      if (n > 0) {
        avg = sum / n
        printf "ipmi_samples=%d\nipmi_avg_w=%.6f\nipmi_min_w=%.6f\nipmi_max_w=%.6f\nipmi_energy_est_j=%.6f\n", n, avg, min, max, avg * elapsed
      } else {
        printf "ipmi_samples=0\nipmi_avg_w=\nipmi_min_w=\nipmi_max_w=\nipmi_energy_est_j=\n"
      }
    }
  ' "${csv}" 2>/dev/null || printf 'ipmi_samples=0\nipmi_avg_w=\nipmi_min_w=\nipmi_max_w=\nipmi_energy_est_j=\n'
}

workload_command() {
  local workload="$1"
  local outdir="${2:-}"
  WORKLOAD_CMD=()
  case "${workload}" in
    pr)
      WORKLOAD_CMD=("${PR_BIN}" -g "${GAPBS_GRAPH_SCALE}" -i "${PR_ITERATIONS}" -t "${PR_TOLERANCE}" -n "${PR_TRIALS}")
      ;;
    bc)
      WORKLOAD_CMD=("${BC_BIN}" -g "${GAPBS_GRAPH_SCALE}" -i "${BC_ITERATIONS}" -n "${BC_TRIALS}")
      ;;
    gups)
      WORKLOAD_CMD=("${GUPS_BIN}")
      ;;
    btree)
      WORKLOAD_CMD=("${BTREE_BIN}")
      ;;
    graph500)
      [[ -x "${GRAPH500_BIN}" ]] || die "missing executable Graph500 benchmark: ${GRAPH500_BIN}"
      WORKLOAD_CMD=("${GRAPH500_BIN}" -s "${GRAPH500_SCALE}")
      ;;
    silo)
      [[ -x "${SILO_BIN}" ]] || die "missing executable Silo dbtest: ${SILO_BIN}"
      WORKLOAD_CMD=("${SILO_BIN}" --verbose --bench ycsb --num-threads "${SILO_THREADS}" \
        --scale-factor "${SILO_SCALE_FACTOR}" --ops-per-worker="${SILO_OPS_PER_WORKER}")
      ;;
    liblinear)
      [[ -x "${LIBLINEAR_TRAIN_BIN}" ]] || die "missing executable Liblinear train: ${LIBLINEAR_TRAIN_BIN}"
      [[ -r "${LIBLINEAR_DATASET}" ]] || die "missing Liblinear dataset: ${LIBLINEAR_DATASET}"
      [[ -n "${outdir}" ]] || die "internal error: liblinear requires an output directory"
      local dataset_name
      dataset_name="$(basename -- "${LIBLINEAR_DATASET}")"
      WORKLOAD_CMD=("${LIBLINEAR_TRAIN_BIN}" -s "${LIBLINEAR_SOLVER}" -m "${LIBLINEAR_THREADS}" \
        "${LIBLINEAR_DATASET}" "${outdir}/${dataset_name}.model")
      ;;
    *)
      die "unknown workload: ${workload}"
      ;;
  esac
}

run_one_workload() {
  local target="$1" migration="$2" workload="$3"
  local outdir start end rc elapsed free_before free_after
  local rapl_pkg_start="" rapl_pkg_end="" rapl_pkg_max="" rapl_pkg_delta="" rapl_pkg_j="" rapl_pkg_w=""
  local rapl_dram_start="" rapl_dram_end="" rapl_dram_max="" rapl_dram_delta="" rapl_dram_j="" rapl_dram_w=""
  local ipmi_samples="" ipmi_avg_w="" ipmi_min_w="" ipmi_max_w="" ipmi_energy_est_j=""
  outdir="$(run_dir)/target${target}g/migration_${migration}/${workload}"
  mkdir -p "${outdir}"

  verify_target_or_reboot "${target}" "${outdir}"
  apply_runtime_knobs
  set_migration_mode "${migration}"
  disable_swap_if_requested
  drop_caches
  if ! target_ok "${target}"; then
    log "target ${target}G drifted after setting migration=${migration}; retrying verify before convergence"
    verify_target_or_reboot "${target}" "${outdir}/verify.after_migration"
  fi
  free_before="$(node_memfree_mib "${LOCAL_NODE}" 2>/dev/null || printf 0)"
  snapshot_common "${outdir}" "before"
  write_rapl_snapshot "${outdir}" "before"
  workload_command "${workload}" "${outdir}"

  {
    printf 'target_gib=%s\n' "${target}"
    printf 'migration=%s\n' "${migration}"
    printf 'workload=%s\n' "${workload}"
    printf 'local_node=%s\n' "${LOCAL_NODE}"
    printf 'remote_node=%s\n' "${REMOTE_NODE}"
    printf 'keep_memory_nodes=%s\n' "${KEEP_MEMORY_NODES}"
    printf 'offline_cpu_node=%s\n' "${OFFLINE_CPU_NODE}"
    printf 'cpu_node=%s\n' "${CPU_NODE}"
    printf 'local_fault_rate=%s\n' "${LOCAL_FAULT_RATE}"
    printf 'local_fault_scan_period_ms=%s\n' "${LOCAL_FAULT_SCAN_PERIOD_MS}"
    printf 'local_fault_scan_size_mb=%s\n' "${LOCAL_FAULT_SCAN_SIZE_MB}"
    printf 'migration_enabled_path=%s\n' "${OURS_MIGRATION_ENABLED_PATH}"
    printf 'migration_enabled=%s\n' "$(cat "${OURS_MIGRATION_ENABLED_PATH}" 2>/dev/null || printf 'NA')"
    printf 'disable_swap=%s\n' "${DISABLE_SWAP}"
    printf 'swap_total_kib=%s\n' "$(awk '/^SwapTotal:/ { print $2; found = 1 } END { if (!found) print "NA" }' /proc/meminfo 2>/dev/null)"
    printf 'swap_free_kib=%s\n' "$(awk '/^SwapFree:/ { print $2; found = 1 } END { if (!found) print "NA" }' /proc/meminfo 2>/dev/null)"
    printf 'numa_scan_size_mb=%s\n' "${NUMA_SCAN_SIZE_MB}"
    printf 'numa_scan_period_min_ms=%s\n' "${NUMA_SCAN_PERIOD_MIN_MS}"
    printf 'thp_mode=%s\n' "${THP_MODE}"
    printf 'thp_defrag=%s\n' "${THP_DEFRAG}"
    printf 'mglru_enabled=%s\n' "${MGLRU_ENABLED}"
    printf 'numa_balancing=%s\n' "$(cat /proc/sys/kernel/numa_balancing 2>/dev/null || printf 'NA')"
    printf 'demotion_enabled=%s\n' "$(cat /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || printf 'NA')"
    printf 'demotion_targets=%s\n' "${DEMOTION_TARGETS}"
    printf 'fault_bucket_controller_dir=%s\n' "${FAULT_BUCKET_CONTROLLER_DIR}"
    printf 'fault_bucket_controller_runner=%s\n' "${FAULT_BUCKET_CONTROLLER_RUNNER}"
    printf 'ours_window_sec=%s\n' "${OURS_WINDOW_SEC}"
    printf 'ours_cycle_window_min_sec=%s\n' "${OURS_CYCLE_WINDOW_MIN_SEC}"
    printf 'ours_cycle_window_max_sec=%s\n' "${OURS_CYCLE_WINDOW_MAX_SEC}"
    printf 'ours_min_local_pages=%s\n' "${OURS_MIN_LOCAL_PAGES}"
    printf 'ours_min_remote_pages=%s\n' "${OURS_MIN_REMOTE_PAGES}"
    printf 'ours_start_consecutive=%s\n' "${OURS_START_CONSECUTIVE}"
    printf 'ours_start_capacity_margin_pct=%s\n' "${OURS_START_CAPACITY_MARGIN_PCT}"
    printf 'ours_stop_capacity_ratio_threshold=%s\n' "${OURS_STOP_CAPACITY_RATIO_THRESHOLD}"
    printf 'gapbs_graph_source=generated\n'
    printf 'gapbs_graph_scale=%s\n' "${GAPBS_GRAPH_SCALE}"
    printf 'command='
    printf '%q ' "${TIME_BIN}" -v "${NUMACTL_BIN}" --cpunodebind="${CPU_NODE}" --localalloc \
      env OMP_NUM_THREADS="${OMP_THREADS}" OMP_PROC_BIND=true OMP_PLACES=cores "${WORKLOAD_CMD[@]}"
    printf '\n'
  } > "${outdir}/command.env"

  log "run target=${target}G migration=${migration} workload=${workload}"
  rapl_pkg_start="$(rapl_read_value "${RAPL_PACKAGE_DOMAIN}" energy_uj 2>/dev/null || true)"
  rapl_pkg_max="$(rapl_read_value "${RAPL_PACKAGE_DOMAIN}" max_energy_range_uj 2>/dev/null || true)"
  rapl_dram_start="$(rapl_read_value "${RAPL_DRAM_DOMAIN}" energy_uj 2>/dev/null || true)"
  rapl_dram_max="$(rapl_read_value "${RAPL_DRAM_DOMAIN}" max_energy_range_uj 2>/dev/null || true)"
  start_ipmi_power_sampler "${outdir}"
  start="$(date +%s)"
  if [[ "${migration}" == "ours" ]]; then
    WRAPPED_RC=""
    WRAPPED_ELAPSED=""
    run_controller_wrapped_workload "${target}" "${migration}" "${workload}" "${outdir}"
    rc="${WRAPPED_RC}"
  else
    set +e
    "${TIME_BIN}" -v \
      "${NUMACTL_BIN}" --cpunodebind="${CPU_NODE}" --localalloc \
      env OMP_NUM_THREADS="${OMP_THREADS}" OMP_PROC_BIND=true OMP_PLACES=cores \
      "${WORKLOAD_CMD[@]}" > "${outdir}/workload.stdout.txt" 2>&1
    rc=$?
    set -e
  fi
  end="$(date +%s)"
  stop_ipmi_power_sampler
  rapl_pkg_end="$(rapl_read_value "${RAPL_PACKAGE_DOMAIN}" energy_uj 2>/dev/null || true)"
  rapl_dram_end="$(rapl_read_value "${RAPL_DRAM_DOMAIN}" energy_uj 2>/dev/null || true)"
  elapsed=$((end - start))
  if [[ "${migration}" == "ours" && "${WRAPPED_ELAPSED}" =~ ^[0-9]+$ ]]; then
    elapsed="${WRAPPED_ELAPSED}"
  fi
  rapl_pkg_delta="$(rapl_delta_uj "${rapl_pkg_start}" "${rapl_pkg_end}" "${rapl_pkg_max}" 2>/dev/null || true)"
  rapl_dram_delta="$(rapl_delta_uj "${rapl_dram_start}" "${rapl_dram_end}" "${rapl_dram_max}" 2>/dev/null || true)"
  rapl_pkg_j="$(uj_to_j "${rapl_pkg_delta}")"
  rapl_dram_j="$(uj_to_j "${rapl_dram_delta}")"
  rapl_pkg_w="$(j_to_avg_w "${rapl_pkg_j}" "${elapsed}")"
  rapl_dram_w="$(j_to_avg_w "${rapl_dram_j}" "${elapsed}")"
  eval "$(summarize_ipmi_power "${outdir}/ipmi_power.csv" "${elapsed}")"
  printf '%s\n' "${rc}" > "${outdir}/workload.rc"
  printf '%s\n' "${elapsed}" > "${outdir}/elapsed_sec"
  {
    printf 'rapl_package_domain=%s\n' "${RAPL_PACKAGE_DOMAIN}"
    printf 'rapl_package_start_uj=%s\n' "${rapl_pkg_start}"
    printf 'rapl_package_end_uj=%s\n' "${rapl_pkg_end}"
    printf 'rapl_package_delta_uj=%s\n' "${rapl_pkg_delta}"
    printf 'rapl_package_j=%s\n' "${rapl_pkg_j}"
    printf 'rapl_package_avg_w=%s\n' "${rapl_pkg_w}"
    printf 'rapl_dram_domain=%s\n' "${RAPL_DRAM_DOMAIN}"
    printf 'rapl_dram_start_uj=%s\n' "${rapl_dram_start}"
    printf 'rapl_dram_end_uj=%s\n' "${rapl_dram_end}"
    printf 'rapl_dram_delta_uj=%s\n' "${rapl_dram_delta}"
    printf 'rapl_dram_j=%s\n' "${rapl_dram_j}"
    printf 'rapl_dram_avg_w=%s\n' "${rapl_dram_w}"
    printf 'ipmi_samples=%s\n' "${ipmi_samples}"
    printf 'ipmi_avg_w=%s\n' "${ipmi_avg_w}"
    printf 'ipmi_min_w=%s\n' "${ipmi_min_w}"
    printf 'ipmi_max_w=%s\n' "${ipmi_max_w}"
    printf 'ipmi_energy_est_j=%s\n' "${ipmi_energy_est_j}"
  } > "${outdir}/energy.env"

  sleep "${POST_WORKLOAD_SLEEP_SEC}"
  drop_caches
  free_after="$(node_memfree_mib "${LOCAL_NODE}" 2>/dev/null || printf 0)"
  snapshot_common "${outdir}" "after"
  write_rapl_snapshot "${outdir}" "after"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${RUN_ID}" "${target}" "${migration}" "${workload}" "${rc}" "${elapsed}" "${free_before}" "${free_after}" \
    "${rapl_pkg_j}" "${rapl_pkg_w}" "${rapl_dram_j}" "${rapl_dram_w}" \
    "${ipmi_avg_w}" "${ipmi_energy_est_j}" "${ipmi_samples}" \
    >> "$(summary_path)"
  log "done target=${target}G migration=${migration} workload=${workload} rc=${rc} elapsed=${elapsed}s"
}

advance_indices() {
  local target_count migration_count workload_count
  split_words "${TARGETS}"; target_count="${#SPLIT_WORDS[@]}"
  split_words "${MIGRATION_MODES}"; migration_count="${#SPLIT_WORDS[@]}"
  split_words "${WORKLOADS}"; workload_count="${#SPLIT_WORDS[@]}"

  WORKLOAD_INDEX=$((WORKLOAD_INDEX + 1))
  if (( WORKLOAD_INDEX >= workload_count )); then
    WORKLOAD_INDEX=0
    MIGRATION_INDEX=$((MIGRATION_INDEX + 1))
  fi
  if (( MIGRATION_INDEX >= migration_count )); then
    MIGRATION_INDEX=0
    TARGET_INDEX=$((TARGET_INDEX + 1))
  fi
  save_state

  if (( TARGET_INDEX < target_count && WORKLOAD_INDEX == 0 && MIGRATION_INDEX == 0 )); then
    split_words "${TARGETS}"
    local next_target="${SPLIT_WORDS[${TARGET_INDEX}]}"
    if ! target_ok "${next_target}"; then
      apply_target_boot_and_reboot "${next_target}"
    fi
  fi
}

resume_run() {
  require_root
  mkdir -p "${STATE_ROOT}" "${LOG_ROOT}" "${RESULTS_ROOT}"
  exec 9>"${LOCK_FILE}"
  if ! flock -n 9; then
    log "another sweep runner is active"
    exit 0
  fi

  load_state
  validate_run_configuration
  require_kernel_abi
  split_words "${TARGETS}"; local -a targets=("${SPLIT_WORDS[@]}")
  split_words "${MIGRATION_MODES}"; local -a migrations=("${SPLIT_WORDS[@]}")
  split_words "${WORKLOADS}"; local -a workloads=("${SPLIT_WORDS[@]}")
  local target_count="${#targets[@]}"
  local migration_count="${#migrations[@]}"
  local workload_count="${#workloads[@]}"

  while (( TARGET_INDEX < target_count )); do
    local target="${targets[${TARGET_INDEX}]}"
    local migration="${migrations[${MIGRATION_INDEX}]}"
    local workload="${workloads[${WORKLOAD_INDEX}]}"
    run_one_workload "${target}" "${migration}" "${workload}"
    advance_indices
    split_words "${TARGETS}"; targets=("${SPLIT_WORDS[@]}"); target_count="${#targets[@]}"
    split_words "${MIGRATION_MODES}"; migrations=("${SPLIT_WORDS[@]}"); migration_count="${#migrations[@]}"
    split_words "${WORKLOADS}"; workloads=("${SPLIT_WORDS[@]}"); workload_count="${#workloads[@]}"
  done

  remove_reboot_hook
  log "sweep completed; results=$(run_dir)"
}

start_run() {
  require_root
  validate_run_configuration
  require_kernel_abi
  RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
  TARGET_INDEX=0
  MIGRATION_INDEX=0
  WORKLOAD_INDEX=0
  mkdir -p "$(run_dir)"
  printf 'run_id\ttarget_gib\tmigration\tworkload\trc\telapsed_sec\tnode0_free_mib_before\tnode0_free_mib_after\trapl_package_j\trapl_package_avg_w\trapl_dram_j\trapl_dram_avg_w\tipmi_avg_w\tipmi_energy_est_j\tipmi_samples\n' \
    > "$(summary_path)"
  {
    printf 'run_id=%s\n' "${RUN_ID}"
    printf 'targets=%s\n' "${TARGETS}"
    printf 'migration_modes=%s\n' "${MIGRATION_MODES}"
    printf 'workloads=%s\n' "${WORKLOADS}"
    printf 'local_node=%s\n' "${LOCAL_NODE}"
    printf 'remote_node=%s\n' "${REMOTE_NODE}"
    printf 'keep_memory_nodes=%s\n' "${KEEP_MEMORY_NODES}"
    printf 'offline_cpu_node=%s\n' "${OFFLINE_CPU_NODE}"
    printf 'cpu_node=%s\n' "${CPU_NODE}"
    printf 'gapbs_graph_source=generated\n'
    printf 'gapbs_graph_scale=%s\n' "${GAPBS_GRAPH_SCALE}"
    printf 'pr_args=-g %s -i %s -t %s -n %s\n' "${GAPBS_GRAPH_SCALE}" "${PR_ITERATIONS}" "${PR_TOLERANCE}" "${PR_TRIALS}"
    printf 'bc_args=-g %s -i %s -n %s\n' "${GAPBS_GRAPH_SCALE}" "${BC_ITERATIONS}" "${BC_TRIALS}"
    printf 'gups_bin=%s\n' "${GUPS_BIN}"
    printf 'btree_bin=%s\n' "${BTREE_BIN}"
    printf 'graph500_bin=%s\n' "${GRAPH500_BIN}"
    printf 'graph500_args=-s %s\n' "${GRAPH500_SCALE}"
    printf 'silo_bin=%s\n' "${SILO_BIN}"
    printf 'silo_args=--verbose --bench ycsb --num-threads %s --scale-factor %s --ops-per-worker=%s\n' \
      "${SILO_THREADS}" "${SILO_SCALE_FACTOR}" "${SILO_OPS_PER_WORKER}"
    printf 'liblinear_train_bin=%s\n' "${LIBLINEAR_TRAIN_BIN}"
    printf 'liblinear_dataset=%s\n' "${LIBLINEAR_DATASET}"
    printf 'liblinear_args=-s %s -m %s %s <outdir>/kdd12.model\n' \
      "${LIBLINEAR_SOLVER}" "${LIBLINEAR_THREADS}" "${LIBLINEAR_DATASET}"
    printf 'post_workload_sleep_sec=%s\n' "${POST_WORKLOAD_SLEEP_SEC}"
    printf 'verify_retries=%s\n' "${VERIFY_RETRIES}"
    printf 'verify_retry_sleep_sec=%s\n' "${VERIFY_RETRY_SLEEP_SEC}"
    printf 'rapl_package_domain=%s\n' "${RAPL_PACKAGE_DOMAIN}"
    printf 'rapl_dram_domain=%s\n' "${RAPL_DRAM_DOMAIN}"
    printf 'ipmi_power_sampling=%s\n' "${IPMI_POWER_SAMPLING}"
    printf 'ipmi_power_interval_sec=%s\n' "${IPMI_POWER_INTERVAL_SEC}"
    printf 'numa_scan_size_mb=%s\n' "${NUMA_SCAN_SIZE_MB}"
    printf 'numa_scan_period_min_ms=%s\n' "${NUMA_SCAN_PERIOD_MIN_MS}"
    printf 'local_fault_rate=%s\n' "${LOCAL_FAULT_RATE}"
    printf 'local_fault_scan_period_ms=%s\n' "${LOCAL_FAULT_SCAN_PERIOD_MS}"
    printf 'local_fault_scan_size_mb=%s\n' "${LOCAL_FAULT_SCAN_SIZE_MB}"
    printf 'mglru_enabled=%s\n' "${MGLRU_ENABLED}"
    printf 'thp_mode=%s\n' "${THP_MODE}"
    printf 'thp_defrag=%s\n' "${THP_DEFRAG}"
    printf 'demotion_policy=off:false;on:true;tpp:true;ours:true\n'
    printf 'demotion_targets=%s\n' "${DEMOTION_TARGETS}"
    printf 'fault_bucket_controller_dir=%s\n' "${FAULT_BUCKET_CONTROLLER_DIR}"
    printf 'fault_bucket_controller_runner=%s\n' "${FAULT_BUCKET_CONTROLLER_RUNNER}"
    printf 'ours_window_sec=%s\n' "${OURS_WINDOW_SEC}"
    printf 'ours_cycle_window_min_sec=%s\n' "${OURS_CYCLE_WINDOW_MIN_SEC}"
    printf 'ours_cycle_window_max_sec=%s\n' "${OURS_CYCLE_WINDOW_MAX_SEC}"
    printf 'ours_min_local_pages=%s\n' "${OURS_MIN_LOCAL_PAGES}"
    printf 'ours_min_remote_pages=%s\n' "${OURS_MIN_REMOTE_PAGES}"
    printf 'ours_start_consecutive=%s\n' "${OURS_START_CONSECUTIVE}"
    printf 'ours_start_capacity_margin_pct=%s\n' "${OURS_START_CAPACITY_MARGIN_PCT}"
    printf 'ours_stop_capacity_ratio_threshold=%s\n' "${OURS_STOP_CAPACITY_RATIO_THRESHOLD}"
    printf 'ours_migration_enabled_path=%s\n' "${OURS_MIGRATION_ENABLED_PATH}"
  } > "$(run_dir)/run_meta.env"
  save_state
  install_reboot_hook
  split_words "${TARGETS}"
  local first_target="${SPLIT_WORDS[0]}"
  if ! target_ok "${first_target}"; then
    log "initial target=${first_target}G is not active; applying target boot before first workload"
    apply_target_boot_and_reboot "${first_target}"
  fi
  resume_run
}

cmd_status() {
  if [[ -r "${STATE_FILE}" ]]; then
    cat "${STATE_FILE}"
  else
    printf 'state_absent=%s\n' "${STATE_FILE}"
  fi
  if [[ -n "${RUN_ID:-}" ]]; then
    printf 'results=%s\n' "$(run_dir)"
  fi
}

main() {
  local cmd="${1:-}"
  case "${cmd}" in
    start) start_run ;;
    start-tmux) start_tmux_run start ;;
    resume) resume_run ;;
    resume-tmux) start_tmux_run resume ;;
    status) cmd_status ;;
    remove-hook) remove_reboot_hook ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
