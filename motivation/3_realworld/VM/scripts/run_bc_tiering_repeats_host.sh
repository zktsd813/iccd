#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EXP_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="${REPO_ROOT:-/Serverless/iccd-git}"
VMCTL="${VMCTL:-${REPO_ROOT}/VM/vmctl.sh}"
SSH_KEY="${SSH_KEY:-/Serverless/Migration-friendly/qemu/tests/keys/id_rsa}"
HOST="${HOST:-127.0.0.1}"

RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-bc-tiering-repeat-local32}"
RESULTS_ROOT="${RESULTS_ROOT:-${EXP_ROOT}/results}"
RUN_ROOT="${RUN_ROOT:-${RESULTS_ROOT}/${RUN_ID}}"
VM_RUN_TAG="${VM_RUN_TAG:-$(printf '%s' "${RUN_ID}" | cksum | awk '{print $1}')}"
VM_RUN_DIR_HOST="${VM_RUN_DIR_HOST:-/tmp/vm32-realworld-${VM_RUN_TAG}}"

LOCAL_SIZE_GIB="${LOCAL_SIZE_GIB:-32}"
LOCAL_LABEL="local${LOCAL_SIZE_GIB}"
CONFIG="${CONFIG:-tiering_0x2}"
WORKLOAD="${WORKLOAD:-bc}"
REPEAT_COUNT="${REPEAT_COUNT:-3}"
NUMA_SCAN_SIZE_MB="${NUMA_SCAN_SIZE_MB:-}"
NUMA_SCAN_PERIOD_MIN_MS="${NUMA_SCAN_PERIOD_MIN_MS:-}"

default_port_for_config() {
  case "$1" in
    migration_off) printf '%s\n' "${MIGRATION_OFF_PORT:-10160}" ;;
    migration_on|tiering_0x2|tpp|tpp_0x4) printf '%s\n' "${MIGRATION_ON_PORT:-10161}" ;;
    all_local) printf '%s\n' "${ALL_LOCAL_PORT:-10162}" ;;
    all_slow) printf '%s\n' "${ALL_SLOW_PORT:-10163}" ;;
    controller_0x2|controller) printf '%s\n' "${CONTROLLER_PORT:-10165}" ;;
    *) printf '%s\n' "${MIGRATION_ON_PORT:-10161}" ;;
  esac
}

PORT="${PORT:-$(default_port_for_config "${CONFIG}")}"
VM_NAME="vm32-${VM_RUN_TAG}-${LOCAL_LABEL}-${CONFIG}"
GUEST_BASE="/root/vm32_realworld/${RUN_ID}/${LOCAL_LABEL}"
HOST_CONFIG_DIR="${RUN_ROOT}/guest-results/${LOCAL_LABEL}/${CONFIG}"
SUMMARY_DIR="${RUN_ROOT}/summaries"
LOG_DIR="${RUN_ROOT}/host-logs"
IMAGE="${RUN_ROOT}/images/${LOCAL_LABEL}-${CONFIG}.qcow2"
RESTORE_SMT_AFTER="${RESTORE_SMT_AFTER:-1}"
DELETE_VM_IMAGE_AFTER="${DELETE_VM_IMAGE_AFTER:-1}"

ORIG_SMT_CONTROL=""

log() {
  printf '[bc-repeat] %s\n' "$*" >&2
}

read_smt_control() {
  if [[ -r /sys/devices/system/cpu/smt/control ]]; then
    cat /sys/devices/system/cpu/smt/control
  else
    printf 'NA\n'
  fi
}

restore_smt() {
  [[ "${RESTORE_SMT_AFTER}" == "1" ]] || return 0
  [[ -n "${ORIG_SMT_CONTROL}" && "${ORIG_SMT_CONTROL}" != "NA" ]] || return 0
  [[ -w /sys/devices/system/cpu/smt/control || "$(id -u)" != "0" ]] || return 0
  if [[ "$(read_smt_control)" != "${ORIG_SMT_CONTROL}" ]]; then
    log "restore SMT state to ${ORIG_SMT_CONTROL}"
    if [[ "$(id -u)" == "0" ]]; then
      printf '%s\n' "${ORIG_SMT_CONTROL}" > /sys/devices/system/cpu/smt/control || true
    else
      sudo -n sh -c "printf '%s\n' '${ORIG_SMT_CONTROL}' > /sys/devices/system/cpu/smt/control" || true
    fi
  fi
}

cleanup() {
  log "stop VM ${VM_NAME}"
  VM_RUN_DIR="${VM_RUN_DIR_HOST}" "${VMCTL}" stop --name "${VM_NAME}" >/dev/null 2>&1 || true
  if [[ "${DELETE_VM_IMAGE_AFTER}" == "1" && -e "${IMAGE}" ]]; then
    log "delete image ${IMAGE}"
    rm -f "${IMAGE}" || true
  fi
  restore_smt
}
trap cleanup EXIT

ssh_guest() {
  ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=5 \
    -i "${SSH_KEY}" \
    -p "${PORT}" \
    "root@${HOST}" \
    "$@"
}

ssh_guest_retry() {
  local label="$1"
  shift
  local attempt rc=0
  for ((attempt = 1; attempt <= 12; attempt++)); do
    if ((attempt > 1)); then
      log "retry ssh ${label} attempt ${attempt}/12"
      sleep 10
    fi
    set +e
    ssh_guest "$@"
    rc=$?
    set -e
    if [[ "${rc}" == "0" ]]; then
      return 0
    fi
  done
  return "${rc}"
}

copy_from_guest_dir() {
  local guest_dir="$1" host_parent="$2"
  mkdir -p "${host_parent}"
  scp \
    -r \
    -P "${PORT}" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    -i "${SSH_KEY}" \
    "root@${HOST}:${guest_dir}" \
    "${host_parent}/"
}

copy_from_guest_dir_retry() {
  local guest_dir="$1" host_parent="$2"
  local attempt rc=0
  for ((attempt = 1; attempt <= 8; attempt++)); do
    if ((attempt > 1)); then
      log "retry copy ${guest_dir} attempt ${attempt}/8"
      sleep 10
    fi
    set +e
    copy_from_guest_dir "${guest_dir}" "${host_parent}"
    rc=$?
    set -e
    if [[ "${rc}" == "0" ]]; then
      return 0
    fi
  done
  return "${rc}"
}

run_extra_repeat() {
  local rep="$1"
  local guest_out="${GUEST_BASE}/${CONFIG}/${WORKLOAD}_rep${rep}"
  local host_out_parent="${HOST_CONFIG_DIR}"
  local repeat_log="${LOG_DIR}/${LOCAL_LABEL}-${CONFIG}-${WORKLOAD}-rep${rep}.log"

  log "start repeat ${rep}/${REPEAT_COUNT}: ${guest_out}"
  ssh_guest_retry "repeat ${rep}" "rm -rf '${guest_out}'; env LOCAL_SIZE_GIB='${LOCAL_SIZE_GIB}' SAMPLE_INTERVAL_SEC='${SAMPLE_INTERVAL_SEC:-5}' OMP_THREADS='${OMP_THREADS:-32}' MGLRU_ENABLED='${MGLRU_ENABLED:-0x0007}' NUMA_SCAN_SIZE_MB='${NUMA_SCAN_SIZE_MB}' NUMA_SCAN_PERIOD_MIN_MS='${NUMA_SCAN_PERIOD_MIN_MS}' THP_MODE='${THP_MODE:-}' THP_DEFRAG='${THP_DEFRAG:-}' REALWORLD_SIZE_PROFILE='${REALWORLD_SIZE_PROFILE:-rss60}' VERIFY_REQUIRED_STATE='${VERIFY_REQUIRED_STATE:-1}' TRACE_BC_TRIAL_PROMOTIONS='${TRACE_BC_TRIAL_PROMOTIONS:-0}' BENCHMARK_DIR='/root/benchmark' GAPBS_GRAPH_MODE='generated' GAPBS_GRAPH_SCALE='29' DROP_GUEST_CACHES='0' COMPACT_GUEST_MEMORY='0' BC_ITERATIONS='${BC_ITERATIONS:-1}' BC_TRIALS='${BC_TRIALS:-8}' /root/vm32_realworld/scripts/run_workload_case_guest.sh --config '${CONFIG}' --workload '${WORKLOAD}' --outdir '${guest_out}'" \
    > "${repeat_log}" 2>&1
  copy_from_guest_dir_retry "${guest_out}" "${host_out_parent}" \
    >> "${repeat_log}" 2>&1
  log "done repeat ${rep}/${REPEAT_COUNT}"
}

write_summary() {
  mkdir -p "${SUMMARY_DIR}"
  python3 - "${HOST_CONFIG_DIR}" "${SUMMARY_DIR}/bc_tiering_repeats.csv" <<'PY'
import csv
import re
import sys
from pathlib import Path

base = Path(sys.argv[1])
out = Path(sys.argv[2])
rows = []
for case in sorted(base.glob("bc*")):
    if not case.is_dir():
        continue
    stdout = case / "workload.stdout.log"
    status = case / "status.txt"
    if not stdout.exists():
        continue
    text = stdout.read_text(errors="replace")
    read_match = re.search(r"Read Time:\s*([0-9.]+)", text)
    trials = [float(x) for x in re.findall(r"Trial Time:\s*([0-9.]+)", text)]
    status_map = {}
    if status.exists():
        for line in status.read_text(errors="replace").splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                status_map[key] = value
    rep = 1 if case.name == "bc" else int(case.name.rsplit("rep", 1)[1])
    read_s = float(read_match.group(1)) if read_match else 0.0
    avg_s = sum(trials) / len(trials) if trials else 0.0
    rows.append({
        "rep": rep,
        "case_dir": str(case),
        "returncode": status_map.get("returncode", ""),
        "elapsed_s": status_map.get("elapsed_s", ""),
        "read_s": f"{read_s:.6f}",
        "avg_trial_s": f"{avg_s:.6f}",
        "sum_trial_s": f"{sum(trials):.6f}",
        "trial_times_s": " ".join(f"{x:.6f}" for x in trials),
    })
rows.sort(key=lambda row: row["rep"])
out.parent.mkdir(parents=True, exist_ok=True)
with out.open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=[
        "rep", "case_dir", "returncode", "elapsed_s", "read_s",
        "avg_trial_s", "sum_trial_s", "trial_times_s",
    ])
    writer.writeheader()
    writer.writerows(rows)
print(out)
PY
}

main() {
  if ((REPEAT_COUNT < 1)); then
    log "REPEAT_COUNT must be >= 1"
    return 2
  fi

  mkdir -p "${RUN_ROOT}" "${LOG_DIR}" "${SUMMARY_DIR}"
  ORIG_SMT_CONTROL="$(read_smt_control)"

  log "run root ${RUN_ROOT}"
  log "first run boots/stages VM; later repeats reuse the same guest image"
  env \
    RUN_ID="${RUN_ID}" \
    RESULTS_ROOT="${RESULTS_ROOT}" \
    RUN_ROOT="${RUN_ROOT}" \
    VM_RUN_TAG="${VM_RUN_TAG}" \
    VM_RUN_DIR_HOST="${VM_RUN_DIR_HOST}" \
    LOCAL_SIZES_GIB="${LOCAL_SIZE_GIB}" \
    CONFIGS="${CONFIG}" \
    WORKLOADS="${WORKLOAD}" \
    TRACE_BC_TRIAL_PROMOTIONS="${TRACE_BC_TRIAL_PROMOTIONS:-0}" \
    RESUME=0 \
    STOP_VM_ON_SUCCESS=0 \
    STOP_VM_ON_FAILURE=1 \
    STOP_VM_ON_EXIT=0 \
    DELETE_VM_IMAGES=0 \
    RESTORE_SMT=0 \
    SAMPLE_INTERVAL_SEC="${SAMPLE_INTERVAL_SEC:-5}" \
    OMP_THREADS="${OMP_THREADS:-32}" \
    NUMA_SCAN_SIZE_MB="${NUMA_SCAN_SIZE_MB}" \
    NUMA_SCAN_PERIOD_MIN_MS="${NUMA_SCAN_PERIOD_MIN_MS}" \
    "${SCRIPT_DIR}/run_vm_sweep_host.sh"

  if ! grep -q '^returncode=0$' "${HOST_CONFIG_DIR}/${WORKLOAD}/status.txt"; then
    log "first run failed; not starting repeats"
    return 1
  fi

  local rep
  for ((rep = 2; rep <= REPEAT_COUNT; rep++)); do
    run_extra_repeat "${rep}"
  done
  write_summary
  log "summary ${SUMMARY_DIR}/bc_tiering_repeats.csv"
}

main "$@"
