#!/usr/bin/env bash
set -euo pipefail

OUTROOT="${OUTROOT:-/root/btree-fault-latency}"
BTREE="${BTREE:-/root/benchmark/vmitosis-workloads/bin/bench_btree_mt}"
WORKLOAD_LABEL="${WORKLOAD_LABEL:-btree_fault_latency}"
WORKLOAD_COMMAND="${WORKLOAD_COMMAND:-}"
CPU_NODE="${CPU_NODE:-0}"
OMP_THREADS="${OMP_THREADS:-32}"
MGLRU_ENABLED="${MGLRU_ENABLED:-0x0007}"
DEMOTION_ENABLED="${DEMOTION_ENABLED:-true}"
DEMOTION_TARGET="${DEMOTION_TARGET:-0 1}"
NUMA_SCAN_SIZE_MB="${NUMA_SCAN_SIZE_MB:-4096}"
NUMA_SCAN_PERIOD_MIN_MS="${NUMA_SCAN_PERIOD_MIN_MS:-1000}"
USE_KERNEL_DEFAULT_NUMA_SCAN="${USE_KERNEL_DEFAULT_NUMA_SCAN:-0}"
NUMA_BALANCING_ON="${NUMA_BALANCING_ON:-2}"
LOCAL_FAULT_RATE="${LOCAL_FAULT_RATE:-10}"
FAULT_LATENCY_WINDOW_SECONDS="${FAULT_LATENCY_WINDOW_SECONDS:-10}"
MONITOR_INTERVAL_MS="${MONITOR_INTERVAL_MS:-1000}"

mkdir -p "${OUTROOT}"

log() {
	printf '[btree-fault-latency] %s\n' "$*" >&2
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

mount_tracefs() {
	mkdir -p /sys/kernel/tracing /sys/kernel/debug
	if ! mountpoint -q /sys/kernel/tracing; then
		mount -t tracefs tracefs /sys/kernel/tracing 2>/dev/null || true
	fi
	if [[ -d /sys/kernel/tracing/events ]]; then
		printf '/sys/kernel/tracing\n'
		return
	fi
	if ! mountpoint -q /sys/kernel/debug; then
		mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
	fi
	printf '/sys/kernel/debug/tracing\n'
}

require_environment() {
	if [[ -z "${WORKLOAD_COMMAND}" ]]; then
		[[ -x "${BTREE}" ]] || die "btree benchmark is not executable: ${BTREE}"
	fi
	command -v numactl >/dev/null 2>&1 || die "numactl is required in the guest"
	[[ -r /sys/kernel/mm/lru_gen/enabled ]] ||
		die "missing /sys/kernel/mm/lru_gen/enabled; booted kernel lacks MGLRU sysfs"
	[[ -r /sys/kernel/mm/numa_balancing/fault_latency_histograms ]] ||
		die "missing /sys/kernel/mm/numa_balancing/fault_latency_histograms"
	[[ -w /sys/kernel/mm/numa_balancing/local_fault_window ]] ||
		die "missing writable /sys/kernel/mm/numa_balancing/local_fault_window"
}

set_common_knobs() {
	local trace_root

	trace_root="$(mount_tracefs)"
	printf '%s\n' "${trace_root}" > "${OUTROOT}/trace_root.path"
	mkdir -p /sys/kernel/debug
	mountpoint -q /sys/kernel/debug ||
		mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true

	write_if_writable /sys/kernel/mm/lru_gen/enabled "${MGLRU_ENABLED}"
	if [[ "$(read_file /sys/kernel/mm/lru_gen/enabled)" != "${MGLRU_ENABLED}" ]]; then
		die "MGLRU expected ${MGLRU_ENABLED}, got $(read_file /sys/kernel/mm/lru_gen/enabled)"
	fi

	write_if_writable /sys/kernel/mm/numa/demotion_enabled "${DEMOTION_ENABLED}"
	write_if_writable /sys/kernel/mm/numa/demotion_target "${DEMOTION_TARGET}"
	write_if_writable /sys/kernel/mm/numa_balancing/local_fault_rate \
		"${LOCAL_FAULT_RATE}"
	if [[ "${USE_KERNEL_DEFAULT_NUMA_SCAN}" != "1" ]]; then
		write_if_writable /sys/kernel/debug/sched/numa_balancing/scan_size_mb \
			"${NUMA_SCAN_SIZE_MB}"
		write_if_writable /sys/kernel/debug/sched/numa_balancing/scan_period_min_ms \
			"${NUMA_SCAN_PERIOD_MIN_MS}"
	fi
	write_if_writable /sys/kernel/mm/transparent_hugepage/enabled never
}

snapshot() {
	local dir="$1" tag="$2"

	mkdir -p "${dir}"
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
		printf 'fault_latency_window_seconds=%s\n' "${FAULT_LATENCY_WINDOW_SECONDS}"
		printf 'thp_enabled=%s\n' "$(read_file /sys/kernel/mm/transparent_hugepage/enabled)"
		find /sys/devices/virtual/memory_tiering -name nodelist -print -exec cat {} \; 2>/dev/null || true
	} > "${dir}/${tag}.meta"
	numactl -H > "${dir}/${tag}.numactl" 2>&1 || true
	cp /proc/vmstat "${dir}/${tag}.vmstat" 2>/dev/null || true
	cp /proc/pressure/memory "${dir}/${tag}.pressure.memory" 2>/dev/null || true
	cat /sys/kernel/mm/numa_balancing/local_fault_stats \
		> "${dir}/${tag}.local_fault_stats" 2>/dev/null || true
	cat /sys/kernel/mm/numa_balancing/fault_latency_histograms \
		> "${dir}/${tag}.fault_latency_histograms" 2>/dev/null || true
}

vmstat_value() {
	local key="$1"
	awk -v key="${key}" '$1 == key { print $2; found=1 } END { if (!found) print 0 }' /proc/vmstat
}

psi_total() {
	local label="$1"
	awk -v label="${label}" '
		$1 == label {
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^total=/) {
					sub(/^total=/, "", $i)
					print $i
					found = 1
				}
			}
		}
		END { if (!found) print 0 }
	' /proc/pressure/memory 2>/dev/null || printf '0\n'
}

monitor_metrics() {
	local dir="$1"
	local start_ns now_ns elapsed_ms

	start_ns="$(date +%s%N)"
	printf 'time_ms,numa_hint_faults,numa_hint_faults_local,numa_pages_migrated,pgpromote_success,pgdemote_direct,pgdemote_kswapd,pgfault,pgmajfault,psi_some_total_us,psi_full_total_us\n' \
		> "${dir}/monitor.csv"
	while :; do
		now_ns="$(date +%s%N)"
		elapsed_ms=$(( (now_ns - start_ns) / 1000000 ))
		printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
			"${elapsed_ms}" \
			"$(vmstat_value numa_hint_faults)" \
			"$(vmstat_value numa_hint_faults_local)" \
			"$(vmstat_value numa_pages_migrated)" \
			"$(vmstat_value pgpromote_success)" \
			"$(vmstat_value pgdemote_direct)" \
			"$(vmstat_value pgdemote_kswapd)" \
			"$(vmstat_value pgfault)" \
			"$(vmstat_value pgmajfault)" \
			"$(psi_total some)" \
			"$(psi_total full)" >> "${dir}/monitor.csv"
		sleep "$(awk -v ms="${MONITOR_INTERVAL_MS}" 'BEGIN { printf "%.3f", ms / 1000.0 }')"
	done
}

record_fault_latency_window() {
	local dir="$1" window_index="$2" elapsed_ms="$3" advance="$4"
	local window_dir label

	window_dir="${dir}/fault_latency_windows"
	label="$(printf 'window_%04d' "${window_index}")"
	mkdir -p "${window_dir}"
	{
		printf 'window_index=%s\n' "${window_index}"
		printf 'elapsed_ms=%s\n' "${elapsed_ms}"
		printf 'date_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf 'numa_balancing=%s\n' "$(read_file /proc/sys/kernel/numa_balancing)"
		printf 'local_fault_window_seq=%s\n' \
			"$(read_file /sys/kernel/mm/numa_balancing/local_fault_window)"
	} > "${window_dir}/${label}.meta"
	cat /sys/kernel/mm/numa_balancing/fault_latency_histograms \
		> "${window_dir}/${label}.fault_latency_histograms" 2>/dev/null || true
	cat /sys/kernel/mm/numa_balancing/local_fault_stats \
		> "${window_dir}/${label}.local_fault_stats" 2>/dev/null || true
	cp /proc/vmstat "${window_dir}/${label}.vmstat" 2>/dev/null || true
	if [[ "${advance}" == "1" ]]; then
		write_if_writable /sys/kernel/mm/numa_balancing/local_fault_window 1
	fi
}

monitor_fault_latency_windows() {
	local dir="$1" interval_s="$2"
	local start_ns now_ns elapsed_ms window_index

	start_ns="$(date +%s%N)"
	window_index=0
	mkdir -p "${dir}/fault_latency_windows"
	printf 'interval_s=%s\n' "${interval_s}" \
		> "${dir}/fault_latency_windows/monitor.meta"
	while :; do
		sleep "${interval_s}"
		now_ns="$(date +%s%N)"
		elapsed_ms=$(( (now_ns - start_ns) / 1000000 ))
		record_fault_latency_window "${dir}" "${window_index}" "${elapsed_ms}" 1
		window_index=$((window_index + 1))
	done
}

build_perf_events() {
	local event
	local events=()
	local candidates=(
		task-clock
		context-switches
		cpu-migrations
		page-faults
		minor-faults
		major-faults
		cycles
		instructions
		stalled-cycles-frontend
		stalled-cycles-backend
	)

	command -v perf >/dev/null 2>&1 || return 0
	for event in "${candidates[@]}"; do
		if perf stat -x, -e "${event}" -- true >/dev/null 2>"${OUTROOT}/perf-probe.tmp"; then
			events+=("${event}")
		fi
	done
	rm -f "${OUTROOT}/perf-probe.tmp"
	IFS=,
	printf '%s\n' "${events[*]}"
	unset IFS
}

run_timed() {
	local dir="$1"
	shift
	local perf_events monitor_pid rc
	local fault_window_monitor_pid fault_window_final_index
	local fault_window_start_ns fault_window_end_ns fault_window_elapsed_ms

	mkdir -p "${dir}"
	printf '%q ' "$@" > "${dir}/command.txt"
	printf '\n' >> "${dir}/command.txt"
	perf_events="$(build_perf_events)"
	printf '%s\n' "${perf_events}" > "${dir}/perf.events"

	monitor_metrics "${dir}" &
	monitor_pid=$!
	fault_window_monitor_pid=""
	fault_window_start_ns=""
	if [[ "${FAULT_LATENCY_WINDOW_SECONDS}" != "0" ]]; then
		fault_window_start_ns="$(date +%s%N)"
		monitor_fault_latency_windows "${dir}" \
			"${FAULT_LATENCY_WINDOW_SECONDS}" &
		fault_window_monitor_pid=$!
	fi

	set +e
	if [[ -n "${perf_events}" ]]; then
		/usr/bin/time -v -o "${dir}/time.txt" \
			perf stat -x, -o "${dir}/perf.csv" -e "${perf_events}" \
			-- "$@" > "${dir}/stdout.txt" 2> "${dir}/stderr.txt"
	else
		printf 'perf stat unavailable or no candidate events are available\n' \
			> "${dir}/perf.unavailable"
		/usr/bin/time -v -o "${dir}/time.txt" \
			"$@" > "${dir}/stdout.txt" 2> "${dir}/stderr.txt"
	fi
	rc=$?
	set -e

	if [[ -n "${fault_window_monitor_pid}" ]]; then
		kill "${fault_window_monitor_pid}" >/dev/null 2>&1 || true
		wait "${fault_window_monitor_pid}" >/dev/null 2>&1 || true
		fault_window_final_index="$(
			find "${dir}/fault_latency_windows" -name 'window_*.fault_latency_histograms' \
				-printf '%f\n' 2>/dev/null |
				sed -n 's/window_0*\([0-9][0-9]*\)\.fault_latency_histograms/\1/p' |
				awk 'BEGIN { max=-1 } { if ($1 > max) max=$1 } END { print max + 1 }'
		)"
		[[ "${fault_window_final_index}" =~ ^[0-9]+$ ]] ||
			fault_window_final_index=0
		fault_window_end_ns="$(date +%s%N)"
		fault_window_elapsed_ms=$(( (fault_window_end_ns - fault_window_start_ns) / 1000000 ))
		record_fault_latency_window "${dir}" "${fault_window_final_index}" \
			"${fault_window_elapsed_ms}" 0
	fi
	kill "${monitor_pid}" >/dev/null 2>&1 || true
	wait "${monitor_pid}" >/dev/null 2>&1 || true
	printf '%s\n' "${rc}" > "${dir}/exit.status"
	return "${rc}"
}

write_experiment_meta() {
	{
		printf 'case_label=%s\n' "${WORKLOAD_LABEL}"
		printf 'btree=%s\n' "${BTREE}"
		if [[ -x "${BTREE}" ]]; then
			printf 'btree_sha256=%s\n' "$(sha256sum "${BTREE}" | awk '{print $1}')"
		fi
		printf 'workload_label=%s\n' "${WORKLOAD_LABEL}"
		printf 'workload_command=%s\n' "${WORKLOAD_COMMAND:-${BTREE}}"
		printf 'cpu_node=%s\n' "${CPU_NODE}"
		printf 'omp_threads=%s\n' "${OMP_THREADS}"
		printf 'mglru_enabled=%s\n' "${MGLRU_ENABLED}"
		printf 'demotion_enabled=%s\n' "${DEMOTION_ENABLED}"
		printf 'demotion_target=%s\n' "${DEMOTION_TARGET}"
		printf 'numa_balancing_on=%s\n' "${NUMA_BALANCING_ON}"
		printf 'numa_scan_size_mb=%s\n' "${NUMA_SCAN_SIZE_MB}"
		printf 'numa_scan_period_min_ms=%s\n' "${NUMA_SCAN_PERIOD_MIN_MS}"
		printf 'use_kernel_default_numa_scan=%s\n' "${USE_KERNEL_DEFAULT_NUMA_SCAN}"
		printf 'local_fault_rate=%s\n' "${LOCAL_FAULT_RATE}"
		printf 'fault_latency_window_seconds=%s\n' "${FAULT_LATENCY_WINDOW_SECONDS}"
	} > "${OUTROOT}/experiment.meta"
}

run_case() {
	local dir="${OUTROOT}/on"
	local -a cmd

	log "case=on workload=${WORKLOAD_LABEL} numa_balancing=${NUMA_BALANCING_ON} window=${FAULT_LATENCY_WINDOW_SECONDS}s"
	mkdir -p "${dir}"
	write_if_writable /proc/sys/kernel/numa_balancing "${NUMA_BALANCING_ON}"
	write_if_writable /sys/kernel/mm/numa_balancing/local_fault_window 1
	snapshot "${dir}" before
	if [[ -n "${WORKLOAD_COMMAND}" ]]; then
		cmd=(env "OMP_NUM_THREADS=${OMP_THREADS}" numactl "--cpunodebind=${CPU_NODE}" bash -lc "exec ${WORKLOAD_COMMAND}")
	else
		cmd=(env "OMP_NUM_THREADS=${OMP_THREADS}" numactl "--cpunodebind=${CPU_NODE}" "${BTREE}")
	fi
	run_timed "${dir}" "${cmd[@]}"
	snapshot "${dir}" after
}

main() {
	require_environment
	set_common_knobs
	write_experiment_meta
	run_case
	log "done: ${OUTROOT}"
}

main "$@"
