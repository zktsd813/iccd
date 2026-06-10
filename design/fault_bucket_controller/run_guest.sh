#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUTROOT="${OUTROOT:-/root/fault-bucket-controller}"
RUN_NAME="${RUN_NAME:-$(date -u +%Y%m%d-%H%M%S)}"
OUTDIR="${OUTDIR:-${OUTROOT}/${RUN_NAME}}"
CONTROLLER="${CONTROLLER:-${SCRIPT_DIR}/bucket_latency_controller.py}"
PLOTTER="${PLOTTER:-${SCRIPT_DIR}/plot_controller.py}"
WORKLOAD_COMMAND="${WORKLOAD_COMMAND:-}"
BTREE="${BTREE:-/root/benchmark/vmitosis-workloads/bin/bench_btree_mt}"
CPU_NODE="${CPU_NODE:-0}"
OMP_THREADS="${OMP_THREADS:-32}"

WINDOW_SEC="${WINDOW_SEC:-5}"
LOCAL_RATE="${LOCAL_RATE:-5}"
REMOTE_RATE="${REMOTE_RATE:-5}"
LOCAL_FAULT_SCAN_PERIOD_MS="${LOCAL_FAULT_SCAN_PERIOD_MS:-1000}"
LOCAL_FAULT_SCAN_SIZE_MB="${LOCAL_FAULT_SCAN_SIZE_MB:-256}"
REMOTE_FAULT_SCAN_PERIOD_MS="${REMOTE_FAULT_SCAN_PERIOD_MS:-${LOCAL_FAULT_SCAN_PERIOD_MS}}"
REMOTE_FAULT_SCAN_SIZE_MB="${REMOTE_FAULT_SCAN_SIZE_MB:-${LOCAL_FAULT_SCAN_SIZE_MB}}"
MIN_LOCAL_PAGES="${MIN_LOCAL_PAGES:-1024}"
MIN_REMOTE_PAGES="${MIN_REMOTE_PAGES:-1024}"
BASELINE_SKIP_WINDOWS="${BASELINE_SKIP_WINDOWS:-1}"
CONSECUTIVE_EFFECTIVE="${CONSECUTIVE_EFFECTIVE:-2}"
CONSECUTIVE_NO_IMPROVE="${CONSECUTIVE_NO_IMPROVE:-2}"
RESTART_REMOTE_SHARE_THRESHOLD="${RESTART_REMOTE_SHARE_THRESHOLD:-1.2}"
CONSECUTIVE_RESTART="${CONSECUTIVE_RESTART:-2}"
RESTART_GRACE_WINDOWS="${RESTART_GRACE_WINDOWS:-1}"
NUMA_BALANCING_ON="${NUMA_BALANCING_ON:-2}"
NUMA_BALANCING_OFF="${NUMA_BALANCING_OFF:-0}"

MGLRU_ENABLED="${MGLRU_ENABLED:-0x0007}"
DEMOTION_ENABLED="${DEMOTION_ENABLED:-true}"
DEMOTION_TARGET="${DEMOTION_TARGET:-0 1}"
NUMA_SCAN_SIZE_MB="${NUMA_SCAN_SIZE_MB:-}"
NUMA_SCAN_PERIOD_MIN_MS="${NUMA_SCAN_PERIOD_MIN_MS:-}"
USE_KERNEL_DEFAULT_NUMA_SCAN="${USE_KERNEL_DEFAULT_NUMA_SCAN:-0}"
THP_MODE="${THP_MODE:-}"
THP_DEFRAG="${THP_DEFRAG:-}"
PLOT_AFTER="${PLOT_AFTER:-1}"
RESTORE_KNOBS="${RESTORE_KNOBS:-1}"

STOP_FILE="${OUTDIR}/stop-controller"
CONTROLLER_CSV="${OUTDIR}/controller.csv"
WINDOW_DIR="${OUTDIR}/fault_latency_windows"

log() {
	printf '[fault-bucket-runner] %s\n' "$*" >&2
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
	mkdir -p /sys/kernel/debug
	mountpoint -q /sys/kernel/debug ||
		mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
	ORIG_NUMA_BALANCING="$(read_file /proc/sys/kernel/numa_balancing)"
	ORIG_NUMA_SCAN_SIZE_MB="$(read_file /sys/kernel/debug/sched/numa_balancing/scan_size_mb)"
	ORIG_NUMA_SCAN_PERIOD_MIN_MS="$(read_file /sys/kernel/debug/sched/numa_balancing/scan_period_min_ms)"
	ORIG_LOCAL_FAULT_RATE="$(read_file /sys/kernel/mm/numa_balancing/local_fault_rate)"
	ORIG_REMOTE_FAULT_RATE="$(read_file /sys/kernel/mm/numa_balancing/remote_fault_rate)"
	ORIG_LOCAL_FAULT_SCAN_PERIOD_MS="$(read_file /sys/kernel/mm/numa_balancing/local_fault_scan_period_ms)"
	ORIG_LOCAL_FAULT_SCAN_SIZE_MB="$(read_file /sys/kernel/mm/numa_balancing/local_fault_scan_size_mb)"
	ORIG_REMOTE_FAULT_SCAN_PERIOD_MS="$(read_file /sys/kernel/mm/numa_balancing/remote_fault_scan_period_ms)"
	ORIG_REMOTE_FAULT_SCAN_SIZE_MB="$(read_file /sys/kernel/mm/numa_balancing/remote_fault_scan_size_mb)"
}

restore_original_knobs() {
	if [[ "${RESTORE_KNOBS}" != "1" ]]; then
		return
	fi
	if [[ -n "${ORIG_NUMA_BALANCING:-}" && "${ORIG_NUMA_BALANCING}" != "NA" ]]; then
		write_if_writable /proc/sys/kernel/numa_balancing "${ORIG_NUMA_BALANCING}"
	fi
	if [[ -n "${ORIG_NUMA_SCAN_SIZE_MB:-}" && "${ORIG_NUMA_SCAN_SIZE_MB}" != "NA" ]]; then
		write_if_writable /sys/kernel/debug/sched/numa_balancing/scan_size_mb \
			"${ORIG_NUMA_SCAN_SIZE_MB}"
	fi
	if [[ -n "${ORIG_NUMA_SCAN_PERIOD_MIN_MS:-}" && "${ORIG_NUMA_SCAN_PERIOD_MIN_MS}" != "NA" ]]; then
		write_if_writable /sys/kernel/debug/sched/numa_balancing/scan_period_min_ms \
			"${ORIG_NUMA_SCAN_PERIOD_MIN_MS}"
	fi
	if [[ -n "${ORIG_LOCAL_FAULT_RATE:-}" && "${ORIG_LOCAL_FAULT_RATE}" != "NA" ]]; then
		write_if_writable /sys/kernel/mm/numa_balancing/local_fault_rate \
			"${ORIG_LOCAL_FAULT_RATE}"
	fi
	if [[ -n "${ORIG_REMOTE_FAULT_RATE:-}" && "${ORIG_REMOTE_FAULT_RATE}" != "NA" ]]; then
		write_if_writable /sys/kernel/mm/numa_balancing/remote_fault_rate \
			"${ORIG_REMOTE_FAULT_RATE}"
	fi
	if [[ -n "${ORIG_LOCAL_FAULT_SCAN_PERIOD_MS:-}" && "${ORIG_LOCAL_FAULT_SCAN_PERIOD_MS}" != "NA" ]]; then
		write_if_writable /sys/kernel/mm/numa_balancing/local_fault_scan_period_ms \
			"${ORIG_LOCAL_FAULT_SCAN_PERIOD_MS}"
	fi
	if [[ -n "${ORIG_LOCAL_FAULT_SCAN_SIZE_MB:-}" && "${ORIG_LOCAL_FAULT_SCAN_SIZE_MB}" != "NA" ]]; then
		write_if_writable /sys/kernel/mm/numa_balancing/local_fault_scan_size_mb \
			"${ORIG_LOCAL_FAULT_SCAN_SIZE_MB}"
	fi
	if [[ -n "${ORIG_REMOTE_FAULT_SCAN_PERIOD_MS:-}" && "${ORIG_REMOTE_FAULT_SCAN_PERIOD_MS}" != "NA" ]]; then
		write_if_writable /sys/kernel/mm/numa_balancing/remote_fault_scan_period_ms \
			"${ORIG_REMOTE_FAULT_SCAN_PERIOD_MS}"
	fi
	if [[ -n "${ORIG_REMOTE_FAULT_SCAN_SIZE_MB:-}" && "${ORIG_REMOTE_FAULT_SCAN_SIZE_MB}" != "NA" ]]; then
		write_if_writable /sys/kernel/mm/numa_balancing/remote_fault_scan_size_mb \
			"${ORIG_REMOTE_FAULT_SCAN_SIZE_MB}"
	fi
}

require_environment() {
	[[ -x "${CONTROLLER}" ]] || die "controller is not executable: ${CONTROLLER}"
	command -v numactl >/dev/null 2>&1 || die "numactl is required"
	[[ -r /sys/kernel/mm/lru_gen/enabled ]] ||
		die "missing /sys/kernel/mm/lru_gen/enabled"
	[[ -r /sys/kernel/mm/numa_balancing/fault_latency_histograms ]] ||
		die "missing fault_latency_histograms"
	[[ -w /sys/kernel/mm/numa_balancing/local_fault_window ]] ||
		die "missing writable local_fault_window"
	[[ -w /sys/kernel/mm/numa_balancing/local_fault_rate ]] ||
		die "missing writable local_fault_rate"
	[[ -w /sys/kernel/mm/numa_balancing/remote_fault_rate ]] ||
		die "missing writable remote_fault_rate"
	[[ -w /sys/kernel/mm/numa_balancing/local_fault_scan_period_ms ]] ||
		die "missing writable local_fault_scan_period_ms"
	[[ -w /sys/kernel/mm/numa_balancing/local_fault_scan_size_mb ]] ||
		die "missing writable local_fault_scan_size_mb"
	[[ -w /sys/kernel/mm/numa_balancing/remote_fault_scan_period_ms ]] ||
		die "missing writable remote_fault_scan_period_ms"
	[[ -w /sys/kernel/mm/numa_balancing/remote_fault_scan_size_mb ]] ||
		die "missing writable remote_fault_scan_size_mb"
	[[ -w /proc/sys/kernel/numa_balancing ]] ||
		die "missing writable /proc/sys/kernel/numa_balancing"
	if [[ -z "${WORKLOAD_COMMAND}" ]]; then
		[[ -x "${BTREE}" ]] || die "btree benchmark is not executable: ${BTREE}"
	fi
}

set_common_knobs() {
	mkdir -p /sys/kernel/debug
	mountpoint -q /sys/kernel/debug ||
		mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true

	write_if_writable /sys/kernel/mm/lru_gen/enabled "${MGLRU_ENABLED}"
	if [[ "$(read_file /sys/kernel/mm/lru_gen/enabled)" != "${MGLRU_ENABLED}" ]]; then
		die "MGLRU expected ${MGLRU_ENABLED}, got $(read_file /sys/kernel/mm/lru_gen/enabled)"
	fi

	write_if_writable /sys/kernel/mm/numa/demotion_enabled "${DEMOTION_ENABLED}"
	write_if_writable /sys/kernel/mm/numa/demotion_target "${DEMOTION_TARGET}"
	if [[ "${USE_KERNEL_DEFAULT_NUMA_SCAN}" != "1" ]]; then
		if [[ -n "${NUMA_SCAN_SIZE_MB}" ]]; then
			write_if_writable /sys/kernel/debug/sched/numa_balancing/scan_size_mb \
				"${NUMA_SCAN_SIZE_MB}"
		fi
		if [[ -n "${NUMA_SCAN_PERIOD_MIN_MS}" ]]; then
			write_if_writable /sys/kernel/debug/sched/numa_balancing/scan_period_min_ms \
				"${NUMA_SCAN_PERIOD_MIN_MS}"
		fi
	fi
	write_if_writable /sys/kernel/mm/numa_balancing/local_fault_scan_period_ms \
		"${LOCAL_FAULT_SCAN_PERIOD_MS}"
	write_if_writable /sys/kernel/mm/numa_balancing/local_fault_scan_size_mb \
		"${LOCAL_FAULT_SCAN_SIZE_MB}"
	write_if_writable /sys/kernel/mm/numa_balancing/remote_fault_scan_period_ms \
		"${REMOTE_FAULT_SCAN_PERIOD_MS}"
	write_if_writable /sys/kernel/mm/numa_balancing/remote_fault_scan_size_mb \
		"${REMOTE_FAULT_SCAN_SIZE_MB}"
	if [[ -n "${THP_MODE}" ]]; then
		write_if_writable /sys/kernel/mm/transparent_hugepage/enabled "${THP_MODE}"
	fi
	if [[ -n "${THP_DEFRAG}" ]]; then
		write_if_writable /sys/kernel/mm/transparent_hugepage/defrag "${THP_DEFRAG}"
	fi
}

snapshot() {
	local tag="$1"
	{
		printf 'tag=%s\n' "${tag}"
		printf 'date_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf 'uname=%s\n' "$(uname -a)"
		printf 'cmdline=%s\n' "$(cat /proc/cmdline)"
		printf 'numa_balancing=%s\n' "$(read_file /proc/sys/kernel/numa_balancing)"
		printf 'lru_gen_enabled=%s\n' "$(read_file /sys/kernel/mm/lru_gen/enabled)"
		printf 'demotion_enabled=%s\n' "$(read_file /sys/kernel/mm/numa/demotion_enabled)"
		printf 'demotion_target<<EOF\n%s\nEOF\n' "$(read_file /sys/kernel/mm/numa/demotion_target)"
		printf 'scan_size_mb=%s\n' "$(read_file /sys/kernel/debug/sched/numa_balancing/scan_size_mb)"
		printf 'scan_period_min_ms=%s\n' "$(read_file /sys/kernel/debug/sched/numa_balancing/scan_period_min_ms)"
		printf 'local_fault_rate=%s\n' "$(read_file /sys/kernel/mm/numa_balancing/local_fault_rate)"
		printf 'remote_fault_rate=%s\n' "$(read_file /sys/kernel/mm/numa_balancing/remote_fault_rate)"
		printf 'local_fault_scan_period_ms=%s\n' "$(read_file /sys/kernel/mm/numa_balancing/local_fault_scan_period_ms)"
		printf 'local_fault_scan_size_mb=%s\n' "$(read_file /sys/kernel/mm/numa_balancing/local_fault_scan_size_mb)"
		printf 'remote_fault_scan_period_ms=%s\n' "$(read_file /sys/kernel/mm/numa_balancing/remote_fault_scan_period_ms)"
		printf 'remote_fault_scan_size_mb=%s\n' "$(read_file /sys/kernel/mm/numa_balancing/remote_fault_scan_size_mb)"
		printf 'thp_enabled=%s\n' "$(read_file /sys/kernel/mm/transparent_hugepage/enabled | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
		printf 'thp_defrag=%s\n' "$(read_file /sys/kernel/mm/transparent_hugepage/defrag | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
		printf 'window_sec=%s\n' "${WINDOW_SEC}"
		find /sys/devices/virtual/memory_tiering -name nodelist -print -exec cat {} \; 2>/dev/null || true
	} > "${OUTDIR}/${tag}.meta"
	cp /proc/vmstat "${OUTDIR}/${tag}.vmstat" 2>/dev/null || true
	cp /proc/pressure/memory "${OUTDIR}/${tag}.pressure.memory" 2>/dev/null || true
	cat /sys/kernel/mm/numa_balancing/local_fault_stats \
		> "${OUTDIR}/${tag}.local_fault_stats" 2>/dev/null || true
	cat /sys/kernel/mm/numa_balancing/remote_fault_stats \
		> "${OUTDIR}/${tag}.remote_fault_stats" 2>/dev/null || true
	cat /sys/kernel/mm/numa_balancing/fault_latency_histograms \
		> "${OUTDIR}/${tag}.fault_latency_histograms" 2>/dev/null || true
	numactl -H > "${OUTDIR}/${tag}.numactl" 2>&1 || true
}

write_config() {
	{
		printf 'outdir=%s\n' "${OUTDIR}"
		printf 'controller=%s\n' "${CONTROLLER}"
		printf 'window_sec=%s\n' "${WINDOW_SEC}"
		printf 'local_rate=%s\n' "${LOCAL_RATE}"
		printf 'remote_rate=%s\n' "${REMOTE_RATE}"
		printf 'local_fault_scan_period_ms=%s\n' "${LOCAL_FAULT_SCAN_PERIOD_MS}"
		printf 'local_fault_scan_size_mb=%s\n' "${LOCAL_FAULT_SCAN_SIZE_MB}"
		printf 'remote_fault_scan_period_ms=%s\n' "${REMOTE_FAULT_SCAN_PERIOD_MS}"
		printf 'remote_fault_scan_size_mb=%s\n' "${REMOTE_FAULT_SCAN_SIZE_MB}"
		printf 'min_local_pages=%s\n' "${MIN_LOCAL_PAGES}"
		printf 'min_remote_pages=%s\n' "${MIN_REMOTE_PAGES}"
		printf 'baseline_skip_windows=%s\n' "${BASELINE_SKIP_WINDOWS}"
		printf 'consecutive_effective=%s\n' "${CONSECUTIVE_EFFECTIVE}"
		printf 'consecutive_no_improve=%s\n' "${CONSECUTIVE_NO_IMPROVE}"
		printf 'restart_remote_share_threshold=%s\n' "${RESTART_REMOTE_SHARE_THRESHOLD}"
		printf 'consecutive_restart=%s\n' "${CONSECUTIVE_RESTART}"
		printf 'restart_grace_windows=%s\n' "${RESTART_GRACE_WINDOWS}"
		printf 'numa_balancing_on=%s\n' "${NUMA_BALANCING_ON}"
		printf 'numa_balancing_off=%s\n' "${NUMA_BALANCING_OFF}"
		printf 'numa_scan_size_mb=%s\n' "${NUMA_SCAN_SIZE_MB}"
		printf 'numa_scan_period_min_ms=%s\n' "${NUMA_SCAN_PERIOD_MIN_MS}"
		printf 'restore_knobs=%s\n' "${RESTORE_KNOBS}"
		printf 'cpu_node=%s\n' "${CPU_NODE}"
		printf 'omp_threads=%s\n' "${OMP_THREADS}"
		printf 'workload_command=%s\n' "${WORKLOAD_COMMAND:-${BTREE}}"
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
	local workload_status controller_status

	require_environment
	mkdir -p "${OUTDIR}"
	rm -f "${STOP_FILE}"
	write_config
	save_original_knobs
	set_common_knobs
	snapshot before

	log "starting controller"
	"${CONTROLLER}" \
		--window-sec "${WINDOW_SEC}" \
		--local-rate "${LOCAL_RATE}" \
		--remote-rate "${REMOTE_RATE}" \
		--min-local-pages "${MIN_LOCAL_PAGES}" \
		--min-remote-pages "${MIN_REMOTE_PAGES}" \
		--baseline-skip-windows "${BASELINE_SKIP_WINDOWS}" \
		--consecutive-effective "${CONSECUTIVE_EFFECTIVE}" \
		--consecutive-no-improve "${CONSECUTIVE_NO_IMPROVE}" \
		--restart-remote-share-threshold "${RESTART_REMOTE_SHARE_THRESHOLD}" \
		--consecutive-restart "${CONSECUTIVE_RESTART}" \
		--restart-grace-windows "${RESTART_GRACE_WINDOWS}" \
		--node-balancing-on "${NUMA_BALANCING_ON}" \
		--node-balancing-off "${NUMA_BALANCING_OFF}" \
		--stop-file "${STOP_FILE}" \
		--output "${CONTROLLER_CSV}" \
		--hist-dir "${WINDOW_DIR}" &
	CONTROLLER_PID="$!"
	trap cleanup EXIT

	if [[ -n "${WORKLOAD_COMMAND}" ]]; then
		printf 'numactl --cpunodebind=%q env OMP_NUM_THREADS=%q bash -lc %q\n' \
			"${CPU_NODE}" "${OMP_THREADS}" "exec ${WORKLOAD_COMMAND}" \
			> "${OUTDIR}/command.txt"
		set +e
		/usr/bin/time -v -o "${OUTDIR}/time.txt" \
			numactl "--cpunodebind=${CPU_NODE}" \
			env "OMP_NUM_THREADS=${OMP_THREADS}" OMP_PROC_BIND=true OMP_PLACES=cores \
			bash -lc "exec ${WORKLOAD_COMMAND}" \
			> "${OUTDIR}/stdout.txt" 2> "${OUTDIR}/stderr.txt"
		workload_status=$?
		set -e
	else
		printf 'numactl --cpunodebind=%q env OMP_NUM_THREADS=%q %q\n' \
			"${CPU_NODE}" "${OMP_THREADS}" "${BTREE}" > "${OUTDIR}/command.txt"
		set +e
		/usr/bin/time -v -o "${OUTDIR}/time.txt" \
			numactl "--cpunodebind=${CPU_NODE}" \
			env "OMP_NUM_THREADS=${OMP_THREADS}" OMP_PROC_BIND=true OMP_PLACES=cores \
			"${BTREE}" > "${OUTDIR}/stdout.txt" 2> "${OUTDIR}/stderr.txt"
		workload_status=$?
		set -e
	fi
	printf '%s\n' "${workload_status}" > "${OUTDIR}/exit.status"

	touch "${STOP_FILE}"
	set +e
	wait "${CONTROLLER_PID}"
	controller_status=$?
	set -e
	printf '%s\n' "${controller_status}" > "${OUTDIR}/controller.exit.status"
	CONTROLLER_PID=""

	snapshot after
	if [[ "${PLOT_AFTER}" == "1" && -x "${PLOTTER}" && -s "${CONTROLLER_CSV}" ]]; then
		python3 "${PLOTTER}" "${CONTROLLER_CSV}" \
			--out-dir "${OUTDIR}/figures" \
			--prefix "fault_bucket_controller" || true
	fi

	log "done: ${OUTDIR}"
	return "${workload_status}"
}

main "$@"
