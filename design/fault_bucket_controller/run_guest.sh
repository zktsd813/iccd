#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUTROOT="${OUTROOT:-/root/fault-bucket-controller}"
RUN_NAME="${RUN_NAME:-$(date -u +%Y%m%d-%H%M%S)}"
OUTDIR="${OUTDIR:-${OUTROOT}/${RUN_NAME}}"
CONTROLLER="${CONTROLLER:-${SCRIPT_DIR}/bucket_latency_controller.py}"
WORKLOAD_COMMAND="${WORKLOAD_COMMAND:-}"
CPU_NODE="${CPU_NODE:-0}"
OMP_THREADS="${OMP_THREADS:-32}"

WINDOW_SEC="${WINDOW_SEC:-1}"
CYCLE_WINDOW_MIN_SEC="${CYCLE_WINDOW_MIN_SEC:-5}"
CYCLE_WINDOW_MAX_SEC="${CYCLE_WINDOW_MAX_SEC:-20}"
LOCAL_RATE="${LOCAL_RATE:-5}"
LOCAL_FAULT_SCAN_PERIOD_MS="${LOCAL_FAULT_SCAN_PERIOD_MS:-1000}"
LOCAL_FAULT_SCAN_SIZE_MB="${LOCAL_FAULT_SCAN_SIZE_MB:-64}"
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
CONTROLLER_POLICY="capacity_rank_latency_local_remote_restart_v3"
LOCAL_NODE="${LOCAL_NODE:-0}"
REMOTE_NODE="${REMOTE_NODE:-1}"
MIGRATION_ENABLED_PATH="${MIGRATION_ENABLED_PATH:-/sys/kernel/mm/numa_balancing/migration_enabled}"
REMOTE_QUANTILE_RANK_PATH="/sys/kernel/mm/numa_balancing/remote_quantile_rank_ppm"

MGLRU_ENABLED="${MGLRU_ENABLED:-0x0007}"
DEMOTION_ENABLED="${DEMOTION_ENABLED:-true}"
DEMOTION_TARGET="${DEMOTION_TARGET:-0 1}"
NUMA_SCAN_SIZE_MB="${NUMA_SCAN_SIZE_MB:-256}"
NUMA_SCAN_PERIOD_MIN_MS="${NUMA_SCAN_PERIOD_MIN_MS:-1000}"
NUMA_SCAN_PERIOD_MAX_MS="${NUMA_SCAN_PERIOD_MAX_MS:-}"
NUMA_SCAN_DELAY_MS="${NUMA_SCAN_DELAY_MS:-}"
THP_MODE="${THP_MODE:-}"
THP_DEFRAG="${THP_DEFRAG:-}"
MAX_WINDOWS="${MAX_WINDOWS:-0}"
RESTORE_KNOBS="${RESTORE_KNOBS:-1}"

STOP_FILE="${OUTDIR}/stop-controller"
CONTROLLER_CSV="${OUTDIR}/controller.csv"
WORKLOAD_PID_FILE="${OUTDIR}/workload.pid"

log() {
	printf '[fault-controller-runner] %s\n' "$*" >&2
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 2
}

read_file() {
	local path="$1"
	if [[ -r "${path}" ]]; then
		cat "${path}"
	else
		printf 'NA\n'
	fi
}

write_if_writable() {
	local path="$1" value="$2"
	if [[ -w "${path}" ]]; then
		printf '%s\n' "${value}" > "${path}"
	fi
}

save_original_knobs() {
	ORIG_NUMA_BALANCING="$(read_file /proc/sys/kernel/numa_balancing)"
	ORIG_NUMA_SCAN_SIZE_MB="$(read_file /sys/kernel/mm/numa_balancing/numa_scan_size_mb)"
	ORIG_NUMA_SCAN_PERIOD_MIN_MS="$(read_file /sys/kernel/mm/numa_balancing/numa_scan_period_min_ms)"
	ORIG_NUMA_SCAN_PERIOD_MAX_MS="$(read_file /sys/kernel/mm/numa_balancing/numa_scan_period_max_ms)"
	ORIG_NUMA_SCAN_DELAY_MS="$(read_file /sys/kernel/mm/numa_balancing/numa_scan_delay_ms)"
	ORIG_LOCAL_FAULT_RATE="$(read_file /sys/kernel/mm/numa_balancing/local_fault_rate)"
	ORIG_MIGRATION_ENABLED="$(read_file "${MIGRATION_ENABLED_PATH}")"
	ORIG_REMOTE_QUANTILE_RANK_PPM="$(read_file "${REMOTE_QUANTILE_RANK_PATH}")"
	ORIG_LOCAL_FAULT_SCAN_PERIOD_MS="$(read_file /sys/kernel/mm/numa_balancing/local_fault_scan_period_ms)"
	ORIG_LOCAL_FAULT_SCAN_SIZE_MB="$(read_file /sys/kernel/mm/numa_balancing/local_fault_scan_size_mb)"
}

restore_one() {
	local path="$1" value="$2"
	if [[ -n "${value}" && "${value}" != "NA" ]]; then
		write_if_writable "${path}" "${value}"
	fi
}

restore_original_knobs() {
	[[ "${RESTORE_KNOBS}" == "1" ]] || return 0
	restore_one /proc/sys/kernel/numa_balancing "${ORIG_NUMA_BALANCING:-}"
	restore_one /sys/kernel/mm/numa_balancing/numa_scan_size_mb "${ORIG_NUMA_SCAN_SIZE_MB:-}"
	restore_one /sys/kernel/mm/numa_balancing/numa_scan_period_min_ms "${ORIG_NUMA_SCAN_PERIOD_MIN_MS:-}"
	restore_one /sys/kernel/mm/numa_balancing/numa_scan_period_max_ms "${ORIG_NUMA_SCAN_PERIOD_MAX_MS:-}"
	restore_one /sys/kernel/mm/numa_balancing/numa_scan_delay_ms "${ORIG_NUMA_SCAN_DELAY_MS:-}"
	restore_one /sys/kernel/mm/numa_balancing/local_fault_rate "${ORIG_LOCAL_FAULT_RATE:-}"
	restore_one "${MIGRATION_ENABLED_PATH}" "${ORIG_MIGRATION_ENABLED:-}"
	restore_one "${REMOTE_QUANTILE_RANK_PATH}" "${ORIG_REMOTE_QUANTILE_RANK_PPM:-}"
	restore_one /sys/kernel/mm/numa_balancing/local_fault_scan_period_ms "${ORIG_LOCAL_FAULT_SCAN_PERIOD_MS:-}"
	restore_one /sys/kernel/mm/numa_balancing/local_fault_scan_size_mb "${ORIG_LOCAL_FAULT_SCAN_SIZE_MB:-}"
}

require_environment() {
	[[ -x "${CONTROLLER}" ]] || die "controller is not executable: ${CONTROLLER}"
	command -v numactl >/dev/null 2>&1 || die "numactl is required"
	[[ -r /sys/kernel/mm/lru_gen/enabled ]] || die "missing MGLRU enabled knob"
	[[ -r /sys/kernel/mm/numa_balancing/fault_latency_quantiles ]] ||
		die "missing fault_latency_quantiles"
	[[ -r /sys/kernel/mm/numa_balancing/remote_scan_cycles ]] ||
		die "missing remote_scan_cycles"
	[[ -w "${REMOTE_QUANTILE_RANK_PATH}" ]] ||
		die "missing writable remote_quantile_rank_ppm"
	[[ -w /sys/kernel/mm/numa_balancing/local_fault_window ]] ||
		die "missing writable local_fault_window"
	[[ -w /sys/kernel/mm/numa_balancing/local_fault_rate ]] ||
		die "missing writable local_fault_rate"
	[[ -w /sys/kernel/mm/numa_balancing/local_fault_scan_period_ms ]] ||
		die "missing writable local_fault_scan_period_ms"
	[[ -w /sys/kernel/mm/numa_balancing/local_fault_scan_size_mb ]] ||
		die "missing writable local_fault_scan_size_mb"
	[[ -w /proc/sys/kernel/numa_balancing ]] ||
		die "missing writable kernel.numa_balancing"
	[[ -w "${MIGRATION_ENABLED_PATH}" ]] ||
		die "missing writable migration knob: ${MIGRATION_ENABLED_PATH}"
	[[ -n "${WORKLOAD_COMMAND}" ]] || die "WORKLOAD_COMMAND is required"
}

set_common_knobs() {
	write_if_writable /sys/kernel/mm/lru_gen/enabled "${MGLRU_ENABLED}"
	write_if_writable /sys/kernel/mm/numa/demotion_enabled "${DEMOTION_ENABLED}"
	write_if_writable /sys/kernel/mm/numa/demotion_target "${DEMOTION_TARGET}"
	write_if_writable /sys/kernel/mm/numa_balancing/numa_scan_size_mb "${NUMA_SCAN_SIZE_MB}"
	if [[ -n "${NUMA_SCAN_PERIOD_MIN_MS}" ]]; then
		write_if_writable /sys/kernel/mm/numa_balancing/numa_scan_period_min_ms "${NUMA_SCAN_PERIOD_MIN_MS}"
	fi
	if [[ -n "${NUMA_SCAN_PERIOD_MAX_MS}" ]]; then
		write_if_writable /sys/kernel/mm/numa_balancing/numa_scan_period_max_ms "${NUMA_SCAN_PERIOD_MAX_MS}"
	fi
	if [[ -n "${NUMA_SCAN_DELAY_MS}" ]]; then
		write_if_writable /sys/kernel/mm/numa_balancing/numa_scan_delay_ms "${NUMA_SCAN_DELAY_MS}"
	fi
	write_if_writable /sys/kernel/mm/numa_balancing/local_fault_scan_period_ms "${LOCAL_FAULT_SCAN_PERIOD_MS}"
	write_if_writable /sys/kernel/mm/numa_balancing/local_fault_scan_size_mb "${LOCAL_FAULT_SCAN_SIZE_MB}"
	write_if_writable "${MIGRATION_ENABLED_PATH}" 1
	if [[ -n "${THP_MODE}" ]]; then
		write_if_writable /sys/kernel/mm/transparent_hugepage/enabled "${THP_MODE}"
	fi
	if [[ -n "${THP_DEFRAG}" ]]; then
		write_if_writable /sys/kernel/mm/transparent_hugepage/defrag "${THP_DEFRAG}"
	fi

	[[ "$(read_file /sys/kernel/mm/numa_balancing/numa_scan_size_mb)" == "${NUMA_SCAN_SIZE_MB}" ]] ||
		die "failed to set NUMA scan size to ${NUMA_SCAN_SIZE_MB} MB"
	[[ "$(read_file /sys/kernel/mm/numa_balancing/local_fault_scan_size_mb)" == "${LOCAL_FAULT_SCAN_SIZE_MB}" ]] ||
		die "failed to set local fault scan size to ${LOCAL_FAULT_SCAN_SIZE_MB} MB"
}

write_config() {
	{
		printf 'policy=%s\n' "${CONTROLLER_POLICY}"
		printf 'controller_csv_schema=%s\n' "${CONTROLLER_POLICY}"
		printf 'window_sec=%s\n' "${WINDOW_SEC}"
		printf 'cycle_window_min_sec=%s\n' "${CYCLE_WINDOW_MIN_SEC}"
		printf 'cycle_window_max_sec=%s\n' "${CYCLE_WINDOW_MAX_SEC}"
		printf 'local_rate=%s\n' "${LOCAL_RATE}"
		printf 'local_fault_scan_period_ms=%s\n' "${LOCAL_FAULT_SCAN_PERIOD_MS}"
		printf 'local_fault_scan_size_mb=%s\n' "${LOCAL_FAULT_SCAN_SIZE_MB}"
		printf 'min_local_pages=%s\n' "${MIN_LOCAL_PAGES}"
		printf 'min_remote_pages=%s\n' "${MIN_REMOTE_PAGES}"
		printf 'local_percentile=75\n'
		printf 'local_head_fraction=0.75\n'
		printf 'local_tail_fraction=0.25\n'
		printf 'stop_capacity_ratio_threshold=%s\n' "${STOP_CAPACITY_RATIO_THRESHOLD}"
		printf 'start_consecutive=%s\n' "${START_CONSECUTIVE}"
		printf 'start_capacity_margin_pct=%s\n' "${START_CAPACITY_MARGIN_PCT}"
		printf 'p75_stagnation_required_decrease_pct=%s\n' "${P75_STAGNATION_REQUIRED_DECREASE_PCT}"
		printf 'p75_stagnation_required_windows=%s\n' "${P75_STAGNATION_REQUIRED_WINDOWS}"
		printf 'p75_stagnation_restart_degradation_pct=%s\n' "${P75_STAGNATION_RESTART_DEGRADATION_PCT}"
		printf 'p75_stagnation_restart_required_windows=%s\n' "${P75_STAGNATION_RESTART_REQUIRED_WINDOWS}"
		printf 'remote_restart_improvement_pct=%s\n' "${REMOTE_RESTART_IMPROVEMENT_PCT}"
		printf 'p75_stagnation_reference=max_trigger_increment_p75\n'
		printf 'arbitration_precedence=p75_stagnation_latched_stop,p75_stagnation_restart,confirmed_start,raw_stop,hold\n'
		printf 'local_node=%s\n' "${LOCAL_NODE}"
		printf 'remote_node=%s\n' "${REMOTE_NODE}"
		printf 'migration_enabled_path=%s\n' "${MIGRATION_ENABLED_PATH}"
		printf 'numa_scan_size_mb=%s\n' "${NUMA_SCAN_SIZE_MB}"
		printf 'numa_scan_period_min_ms=%s\n' "${NUMA_SCAN_PERIOD_MIN_MS}"
		printf 'workload_command=%s\n' "${WORKLOAD_COMMAND}"
	} > "${OUTDIR}/config.meta"
}

cleanup() {
	local status=$?
	touch "${STOP_FILE}" 2>/dev/null || true
	if [[ -n "${CONTROLLER_PID:-}" ]]; then
		wait "${CONTROLLER_PID}" 2>/dev/null || true
	fi
	restore_original_knobs
	return "${status}"
}

main() {
	local workload_status controller_status run_status workload_pid workload_display
	local -a controller_args workload_prefix

	require_environment
	mkdir -p "${OUTDIR}"
	rm -f "${STOP_FILE}" "${WORKLOAD_PID_FILE}"
	save_original_knobs
	set_common_knobs
	write_config

	controller_args=(
		"${CONTROLLER}"
		--window-sec "${WINDOW_SEC}"
		--cycle-window-min-sec "${CYCLE_WINDOW_MIN_SEC}"
		--cycle-window-max-sec "${CYCLE_WINDOW_MAX_SEC}"
		--local-rate "${LOCAL_RATE}"
		--min-local-pages "${MIN_LOCAL_PAGES}"
		--min-remote-pages "${MIN_REMOTE_PAGES}"
		--start-consecutive "${START_CONSECUTIVE}"
		--start-capacity-margin-pct "${START_CAPACITY_MARGIN_PCT}"
		--stop-capacity-ratio-threshold "${STOP_CAPACITY_RATIO_THRESHOLD}"
		--p75-stagnation-required-decrease-pct "${P75_STAGNATION_REQUIRED_DECREASE_PCT}"
		--p75-stagnation-required-windows "${P75_STAGNATION_REQUIRED_WINDOWS}"
		--p75-stagnation-restart-degradation-pct "${P75_STAGNATION_RESTART_DEGRADATION_PCT}"
		--p75-stagnation-restart-required-windows "${P75_STAGNATION_RESTART_REQUIRED_WINDOWS}"
		--remote-restart-improvement-pct "${REMOTE_RESTART_IMPROVEMENT_PCT}"
		--workload-pid-file "${WORKLOAD_PID_FILE}"
		--local-node "${LOCAL_NODE}"
		--remote-node "${REMOTE_NODE}"
		--migration-enabled-path "${MIGRATION_ENABLED_PATH}"
		--stop-file "${STOP_FILE}"
		--output "${CONTROLLER_CSV}"
		--max-windows "${MAX_WINDOWS}"
	)
	log "starting capacity-rank latency controller with P75 stagnation guard"
	"${controller_args[@]}" &
	CONTROLLER_PID="$!"
	trap cleanup EXIT

	workload_prefix=(
		/usr/bin/time -v -o "${OUTDIR}/time.txt"
		numactl "--cpunodebind=${CPU_NODE}"
		env "OMP_NUM_THREADS=${OMP_THREADS}" OMP_PROC_BIND=true OMP_PLACES=cores
	)
	printf -v workload_display '%q ' "${workload_prefix[@]}" bash -lc "exec ${WORKLOAD_COMMAND}"
	printf '%s\n' "${workload_display}" > "${OUTDIR}/command.txt"
	set +e
	"${workload_prefix[@]}" bash -lc "exec ${WORKLOAD_COMMAND}" \
		> "${OUTDIR}/stdout.txt" 2> "${OUTDIR}/stderr.txt" &
	workload_pid=$!
	printf '%s\n' "${workload_pid}" > "${WORKLOAD_PID_FILE}"
	wait "${workload_pid}"
	workload_status=$?
	set -e
	printf '%s\n' "${workload_status}" > "${OUTDIR}/workload.exit.status"

	touch "${STOP_FILE}"
	set +e
	wait "${CONTROLLER_PID}"
	controller_status=$?
	set -e
	printf '%s\n' "${controller_status}" > "${OUTDIR}/controller.exit.status"
	CONTROLLER_PID=""
	run_status="${workload_status}"
	if [[ "${controller_status}" != "0" ]]; then
		log "controller failed: status=${controller_status}"
		if [[ "${run_status}" == "0" ]]; then
			run_status="${controller_status}"
		fi
	fi
	printf '%s\n' "${run_status}" > "${OUTDIR}/exit.status"

	log "done: ${OUTDIR}"
	return "${run_status}"
}

main "$@"
