#!/usr/bin/env bash
set -euo pipefail

OUTROOT="${OUTROOT:-/root/microbenchmark-fixedops}"
MBENCH="${MBENCH:-/root/mbench}"
CPU_NODE="${CPU_NODE:-0}"
CASES="${CASES:-off on on_trace}"
TARGET_SECONDS="${TARGET_SECONDS:-120}"
TARGET_OPS="${TARGET_OPS:-}"
CALIBRATE_MS="${CALIBRATE_MS:-10000}"
WARMUP_MS="${WARMUP_MS:-20000}"
SAMPLE_MS="${SAMPLE_MS:-1000}"
ARENA_SIZE="${ARENA_SIZE:-32G}"
WINDOW_SIZE="${WINDOW_SIZE:-32G}"
WINDOW_SPLIT_LOCAL="${WINDOW_SPLIT_LOCAL:-16G}"
PLACEMENT_MODE="${PLACEMENT_MODE:-window-split}"
THREADS="${THREADS:-32}"
THREAD_COUNTS="${THREAD_COUNTS:-}"
MBENCH_MODE="${MBENCH_MODE:-bw}"
BW_STRIDE="${BW_STRIDE:-512}"
BW_BLOCK="${BW_BLOCK:-4K}"
BW_SHARED_WINDOW="${BW_SHARED_WINDOW:-1}"
HOTSET_PAGES="${HOTSET_PAGES:-}"
HOT_PROB_PCT="${HOT_PROB_PCT:-100}"
HOTSET_READ_PCT="${HOTSET_READ_PCT:-100}"
HOTSET_WRITE_PCT="${HOTSET_WRITE_PCT:-0}"
HOTSET_RMW_PCT="${HOTSET_RMW_PCT:-0}"
HOTSET_INDEX_MODE="${HOTSET_INDEX_MODE:-xorshift}"
MGLRU_ENABLED="${MGLRU_ENABLED:-0x0007}"
DEMOTION_ENABLED="${DEMOTION_ENABLED:-true}"
DEMOTION_TARGET="${DEMOTION_TARGET:-0 1}"
NUMA_SCAN_SIZE_MB="${NUMA_SCAN_SIZE_MB:-4096}"
NUMA_SCAN_PERIOD_MIN_MS="${NUMA_SCAN_PERIOD_MIN_MS:-1000}"
USE_KERNEL_DEFAULT_NUMA_SCAN="${USE_KERNEL_DEFAULT_NUMA_SCAN:-0}"
NUMA_BALANCING_ON="${NUMA_BALANCING_ON:-2}"
NUMA_BALANCING_OFF="${NUMA_BALANCING_OFF:-0}"
LOCAL_FAULT_RATE="${LOCAL_FAULT_RATE:-}"
RESET_FAULT_LATENCY_WINDOW="${RESET_FAULT_LATENCY_WINDOW:-0}"
RESET_FAULT_LATENCY_WINDOW_AFTER_WARMUP="${RESET_FAULT_LATENCY_WINDOW_AFTER_WARMUP:-0}"
RESET_FAULT_LATENCY_WINDOW_AFTER_OPS="${RESET_FAULT_LATENCY_WINDOW_AFTER_OPS:-0}"
FAULT_LATENCY_WINDOW_SECONDS="${FAULT_LATENCY_WINDOW_SECONDS:-0}"
TRACE_BUFFER_KB="${TRACE_BUFFER_KB:-262144}"
MONITOR_INTERVAL_MS="${MONITOR_INTERVAL_MS:-1000}"
SMOKE="${SMOKE:-0}"

if [[ "${SMOKE}" == "1" ]]; then
	ARENA_SIZE="${SMOKE_ARENA_SIZE:-512M}"
	WINDOW_SIZE="${SMOKE_WINDOW_SIZE:-512M}"
	WINDOW_SPLIT_LOCAL="${SMOKE_WINDOW_SPLIT_LOCAL:-256M}"
	THREADS="${SMOKE_THREADS:-2}"
	TARGET_SECONDS="${SMOKE_TARGET_SECONDS:-5}"
	CALIBRATE_MS="${SMOKE_CALIBRATE_MS:-2000}"
	WARMUP_MS="${SMOKE_WARMUP_MS:-1000}"
	CASES="${SMOKE_CASES:-off on_trace}"
fi

mkdir -p "${OUTROOT}"

log() {
	printf '[microbenchmark-fixedops] %s\n' "$*" >&2
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 2
}

size_to_bytes() {
	local value="$1" number suffix

	number="${value%[KkMmGg]}"
	suffix="${value:${#number}}"
	[[ "${number}" =~ ^[0-9]+$ ]] || die "unsupported size value: ${value}"
	case "${suffix}" in
	K|k) printf '%s\n' $((number * 1024)) ;;
	M|m) printf '%s\n' $((number * 1024 * 1024)) ;;
	G|g) printf '%s\n' $((number * 1024 * 1024 * 1024)) ;;
	"") printf '%s\n' "${number}" ;;
	*) die "unsupported size suffix in: ${value}" ;;
	esac
}

size_to_pages() {
	local bytes page_size

	bytes="$(size_to_bytes "$1")"
	page_size="$(getconf PAGESIZE 2>/dev/null || printf '4096')"
	[[ "${page_size}" =~ ^[0-9]+$ && "${page_size}" -gt 0 ]] ||
		page_size=4096
	printf '%s\n' $((bytes / page_size))
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
	[[ -x "${MBENCH}" ]] || die "mbench is not executable: ${MBENCH}"
	command -v numactl >/dev/null 2>&1 || die "numactl is required in the guest"
	[[ -r /sys/kernel/mm/lru_gen/enabled ]] ||
		die "missing /sys/kernel/mm/lru_gen/enabled; booted kernel lacks MGLRU sysfs"
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
	if [[ -n "${LOCAL_FAULT_RATE}" ]]; then
		write_if_writable /sys/kernel/mm/numa_balancing/local_fault_rate \
			"${LOCAL_FAULT_RATE}"
	fi
	if [[ "${USE_KERNEL_DEFAULT_NUMA_SCAN}" != "1" ]]; then
		write_if_writable /sys/kernel/debug/sched/numa_balancing/scan_size_mb "${NUMA_SCAN_SIZE_MB}"
		write_if_writable /sys/kernel/debug/sched/numa_balancing/scan_period_min_ms "${NUMA_SCAN_PERIOD_MIN_MS}"
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

enable_event() {
	local trace_root="$1" event="$2"
	if [[ -w "${trace_root}/events/${event}/enable" ]]; then
		printf '1\n' > "${trace_root}/events/${event}/enable"
		printf '%s\n' "${event}" >> "${3}"
	fi
}

start_trace() {
	local dir="$1" trace_root="$2" enabled_file

	enabled_file="${dir}/trace.enabled_events"
	: > "${enabled_file}"
	printf '0\n' > "${trace_root}/tracing_on" 2>/dev/null || true
	printf '0\n' > "${trace_root}/events/enable" 2>/dev/null || true
	printf 'nop\n' > "${trace_root}/current_tracer" 2>/dev/null || true
	if [[ -w "${trace_root}/buffer_size_kb" ]]; then
		printf '%s\n' "${TRACE_BUFFER_KB}" > "${trace_root}/buffer_size_kb" 2>/dev/null || true
	fi
	: > "${trace_root}/trace" 2>/dev/null || true
	enable_event "${trace_root}" migrate/mm_migrate_stage "${enabled_file}"
	enable_event "${trace_root}" migrate/mm_migrate_pages_start "${enabled_file}"
	enable_event "${trace_root}" migrate/mm_migrate_pages "${enabled_file}"
	enable_event "${trace_root}" migrate/set_migration_pte "${enabled_file}"
	enable_event "${trace_root}" migrate/remove_migration_pte "${enabled_file}"
	enable_event "${trace_root}" tlb/tlb_flush "${enabled_file}"
	enable_event "${trace_root}" exceptions/page_fault_user "${enabled_file}"
	enable_event "${trace_root}" exceptions/page_fault_kernel "${enabled_file}"
	printf '1\n' > "${trace_root}/tracing_on" 2>/dev/null || true
}

stop_trace() {
	local dir="$1" trace_root="$2"

	printf '0\n' > "${trace_root}/tracing_on" 2>/dev/null || true
	cat "${trace_root}/trace" > "${dir}/trace.txt" 2>/dev/null || true
	printf '0\n' > "${trace_root}/events/enable" 2>/dev/null || true
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

mbench_base_cmd() {
	local placement_mode

	printf '%s\0' numactl "--cpunodebind=${CPU_NODE}" "${MBENCH}" \
		--mode "${MBENCH_MODE}" \
		--arena-size "${ARENA_SIZE}" \
		--window-size "${WINDOW_SIZE}" \
		--move-policy fixed
	case "${PLACEMENT_MODE}" in
	window-split)
		if [[ "${WINDOW_SPLIT_LOCAL}" == "${WINDOW_SIZE}" ]]; then
			placement_mode="bind:0"
			printf '%s\0' --placement "${placement_mode}"
		else
			placement_mode="window-split:0,1"
			printf '%s\0' \
				--placement "${placement_mode}" \
				--window-split-local "${WINDOW_SPLIT_LOCAL}"
		fi
		;;
	all-slow)
		case "${MBENCH_MODE}" in
		skewed-hotset|hotset)
			printf '%s\0' --hotset-prefault-node 1
			;;
		*)
			printf '%s\0' \
				--hotset-pages "$(size_to_pages "${WINDOW_SIZE}")" \
				--hotset-prefault-node 1
			;;
		esac
		;;
	*) die "unknown PLACEMENT_MODE: ${PLACEMENT_MODE}" ;;
	esac
	case "${MBENCH_MODE}" in
	bw)
		printf '%s\0' \
			--bw-kernel read \
			--bw-stride "${BW_STRIDE}" \
			--bw-block "${BW_BLOCK}"
		if [[ "${BW_SHARED_WINDOW}" == "1" ]]; then
			printf '%s\0' --bw-shared-window
		fi
		;;
	skewed-hotset|hotset)
		printf '%s\0' \
			--hotset-pages "${HOTSET_PAGES:-$(size_to_pages "${WINDOW_SIZE}")}" \
			--hot-prob-pct "${HOT_PROB_PCT}" \
			--hotset-read-pct "${HOTSET_READ_PCT}" \
			--hotset-write-pct "${HOTSET_WRITE_PCT}" \
			--hotset-rmw-pct "${HOTSET_RMW_PCT}" \
			--hotset-index-mode "${HOTSET_INDEX_MODE}"
		;;
	*) die "unsupported MBENCH_MODE for this runner: ${MBENCH_MODE}" ;;
	esac
	printf '%s\0' \
		--threads "${THREADS}" \
		--sample-ms "${SAMPLE_MS}" \
		--csv
}

run_timed() {
	local dir="$1"
	shift
	local perf_events monitor_pid rc
	local stderr_path stderr_fifo stderr_monitor_pid
	local stdout_path stdout_fifo stdout_monitor_pid
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
	stderr_path="${dir}/stderr.txt"
	stderr_fifo=""
	stderr_monitor_pid=""
	if [[ "${RESET_FAULT_LATENCY_WINDOW_AFTER_WARMUP}" == "1" ]]; then
		stderr_fifo="${dir}/stderr.pipe"
		rm -f "${stderr_fifo}"
		mkfifo "${stderr_fifo}"
		: > "${stderr_path}"
		: > "${dir}/fault_window_reset.log"
		(
			while IFS= read -r line; do
				printf '%s\n' "${line}" >> "${stderr_path}"
				if [[ "${line}" == warmup_complete* ]]; then
					if [[ -w /sys/kernel/mm/numa_balancing/local_fault_window ]]; then
						printf '1\n' > /sys/kernel/mm/numa_balancing/local_fault_window
						printf 'reset_after_warmup date_utc=%s line=%s\n' \
							"$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
							"${line}" >> "${dir}/fault_window_reset.log"
					fi
				fi
			done < "${stderr_fifo}"
		) &
		stderr_monitor_pid=$!
	fi
	stdout_path="${dir}/stdout.txt"
	stdout_fifo=""
	stdout_monitor_pid=""
	if [[ "${RESET_FAULT_LATENCY_WINDOW_AFTER_OPS}" != "0" ]]; then
		stdout_fifo="${dir}/stdout.pipe"
		rm -f "${stdout_fifo}"
		mkfifo "${stdout_fifo}"
		: > "${stdout_path}"
		: > "${dir}/fault_window_reset_after_ops.log"
		(
			local reset_done=0
			while IFS= read -r line; do
				printf '%s\n' "${line}" >> "${stdout_path}"
				if [[ "${reset_done}" == "0" &&
				      "${line}" =~ ^[0-9]+,[0-9]+, ]]; then
					local ops_total

					ops_total="${line#*,}"
					ops_total="${ops_total%%,*}"
					if [[ "${ops_total}" =~ ^[0-9]+$ &&
					      "${ops_total}" -ge "${RESET_FAULT_LATENCY_WINDOW_AFTER_OPS}" ]]; then
						if [[ -w /sys/kernel/mm/numa_balancing/local_fault_window ]]; then
							printf '1\n' > /sys/kernel/mm/numa_balancing/local_fault_window
							printf 'reset_after_ops date_utc=%s threshold_ops=%s line=%s\n' \
								"$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
								"${RESET_FAULT_LATENCY_WINDOW_AFTER_OPS}" \
								"${line}" >> "${dir}/fault_window_reset_after_ops.log"
							reset_done=1
						fi
					fi
				fi
			done < "${stdout_fifo}"
		) &
		stdout_monitor_pid=$!
	fi
	set +e
	if [[ -n "${perf_events}" ]]; then
		if [[ -n "${stderr_fifo}" ]]; then
			/usr/bin/time -v -o "${dir}/time.txt" \
				perf stat -x, -o "${dir}/perf.csv" -e "${perf_events}" \
				-- "$@" > "${stdout_fifo:-${stdout_path}}" 2> "${stderr_fifo}"
		else
			/usr/bin/time -v -o "${dir}/time.txt" \
				perf stat -x, -o "${dir}/perf.csv" -e "${perf_events}" \
				-- "$@" > "${stdout_fifo:-${stdout_path}}" 2> "${stderr_path}"
		fi
	else
		printf 'perf stat unavailable or no candidate events are available\n' \
			> "${dir}/perf.unavailable"
		if [[ -n "${stderr_fifo}" ]]; then
			/usr/bin/time -v -o "${dir}/time.txt" \
				"$@" > "${stdout_fifo:-${stdout_path}}" 2> "${stderr_fifo}"
		else
			/usr/bin/time -v -o "${dir}/time.txt" \
				"$@" > "${stdout_fifo:-${stdout_path}}" 2> "${stderr_path}"
		fi
	fi
	rc=$?
	set -e
	if [[ -n "${stdout_monitor_pid}" ]]; then
		wait "${stdout_monitor_pid}" >/dev/null 2>&1 || true
		rm -f "${stdout_fifo}"
	fi
	if [[ -n "${stderr_monitor_pid}" ]]; then
		wait "${stderr_monitor_pid}" >/dev/null 2>&1 || true
		rm -f "${stderr_fifo}"
	fi
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

run_case() {
	local name="$1" balancing="$2" trace="$3" target_ops="$4" trace_root="$5"
	local dir="${OUTROOT}/${name}"
	local -a cmd
	local rc

	log "case=${name} numa_balancing=${balancing} trace=${trace} target_ops=${target_ops}"
	mkdir -p "${dir}"
	write_if_writable /proc/sys/kernel/numa_balancing "${balancing}"
	if [[ "${RESET_FAULT_LATENCY_WINDOW}" == "1" ]]; then
		write_if_writable /sys/kernel/mm/numa_balancing/local_fault_window 1
	fi
	snapshot "${dir}" before
	mapfile -d '' -t cmd < <(mbench_base_cmd)
	cmd+=(--target-ops "${target_ops}")

	if [[ "${trace}" == "1" ]]; then
		start_trace "${dir}" "${trace_root}"
	fi
	set +e
	MBENCH_FORCE_WARMUP_MS="${WARMUP_MS}" run_timed "${dir}" "${cmd[@]}"
	rc=$?
	set -e
	if [[ "${trace}" == "1" ]]; then
		stop_trace "${dir}" "${trace_root}"
	fi
	snapshot "${dir}" after
	return "${rc}"
}

parse_total_ops() {
	local stderr_path="$1"
	sed -n 's/.*total_ops=\([0-9][0-9]*\).*/\1/p' "${stderr_path}" | tail -n 1
}

parse_elapsed_s() {
	local stderr_path="$1"
	sed -n 's/.*elapsed_s=\([0-9.][0-9.]*\).*/\1/p' "${stderr_path}" | tail -n 1
}

calibrate_target_ops() {
	local label="${1:-calibrate_off}"
	local dir="${OUTROOT}/${label}"
	local -a cmd
	local ops elapsed target

	log "calibrating ${label} target ops with off run: ${CALIBRATE_MS}ms measured"
	write_if_writable /proc/sys/kernel/numa_balancing "${NUMA_BALANCING_OFF}"
	snapshot "${dir}" before
	mapfile -d '' -t cmd < <(mbench_base_cmd)
	MBENCH_FORCE_WARMUP_MS="${WARMUP_MS}" \
	MBENCH_FORCE_DURATION_MS="${CALIBRATE_MS}" \
		run_timed "${dir}" "${cmd[@]}"
	snapshot "${dir}" after

	ops="$(parse_total_ops "${dir}/stderr.txt")"
	elapsed="$(parse_elapsed_s "${dir}/stderr.txt")"
	[[ -n "${ops}" && -n "${elapsed}" ]] ||
		die "failed to parse calibration result from ${dir}/stderr.txt"
	target="$(awk -v ops="${ops}" -v elapsed="${elapsed}" -v seconds="${TARGET_SECONDS}" \
		'BEGIN { if (elapsed <= 0) exit 1; printf "%.0f\n", ops * seconds / elapsed }')"
	[[ -n "${target}" && "${target}" != "0" ]] || die "calibrated target_ops is zero"
	printf '%s\n' "${target}" > "${OUTROOT}/${label}.target_ops"
	if [[ "${label}" == "calibrate_off" ]]; then
		printf '%s\n' "${target}" > "${OUTROOT}/target_ops"
	fi
	printf 'calibration_ops=%s\ncalibration_elapsed_s=%s\ntarget_seconds=%s\ntarget_ops=%s\n' \
		"${ops}" "${elapsed}" "${TARGET_SECONDS}" "${target}" > "${OUTROOT}/${label}.target_ops.meta"
	if [[ "${label}" == "calibrate_off" ]]; then
		cp "${OUTROOT}/${label}.target_ops.meta" "${OUTROOT}/target_ops.meta"
	fi
	printf '%s\n' "${target}"
}

write_experiment_meta() {
	{
		case "${MBENCH_MODE}" in
		bw) printf 'case_label=stream_read_32g_split16_4kstride\n' ;;
		skewed-hotset|hotset) printf 'case_label=random_page_hotset\n' ;;
		*) printf 'case_label=%s\n' "${MBENCH_MODE}" ;;
		esac
		printf 'mbench_mode=%s\n' "${MBENCH_MODE}"
		printf 'arena_size=%s\n' "${ARENA_SIZE}"
		printf 'window_size=%s\n' "${WINDOW_SIZE}"
		printf 'placement_mode=%s\n' "${PLACEMENT_MODE}"
		printf 'window_split_local=%s\n' "${WINDOW_SPLIT_LOCAL}"
		case "${PLACEMENT_MODE}" in
		window-split)
			if [[ "${WINDOW_SPLIT_LOCAL}" == "${WINDOW_SIZE}" ]]; then
				printf 'placement=bind:0\n'
			else
				printf 'placement=window-split:0,1\n'
			fi
			;;
		all-slow)
			printf 'placement=hotset-prefault-node:1\n'
			printf 'hotset_pages_for_prefault=%s\n' "$(size_to_pages "${WINDOW_SIZE}")"
			;;
		esac
		printf 'threads=%s\n' "${THREADS}"
		printf 'thread_counts=%s\n' "${THREAD_COUNTS}"
		printf 'bw_stride=%s\n' "${BW_STRIDE}"
		printf 'bw_block=%s\n' "${BW_BLOCK}"
		printf 'bw_shared_window=%s\n' "${BW_SHARED_WINDOW}"
		printf 'hotset_pages=%s\n' "${HOTSET_PAGES:-$(size_to_pages "${WINDOW_SIZE}")}"
		printf 'hot_prob_pct=%s\n' "${HOT_PROB_PCT}"
		printf 'hotset_read_pct=%s\n' "${HOTSET_READ_PCT}"
		printf 'hotset_write_pct=%s\n' "${HOTSET_WRITE_PCT}"
		printf 'hotset_rmw_pct=%s\n' "${HOTSET_RMW_PCT}"
		printf 'hotset_index_mode=%s\n' "${HOTSET_INDEX_MODE}"
		printf 'cpu_node=%s\n' "${CPU_NODE}"
		printf 'use_kernel_default_numa_scan=%s\n' "${USE_KERNEL_DEFAULT_NUMA_SCAN}"
		printf 'reset_fault_latency_window_after_warmup=%s\n' \
			"${RESET_FAULT_LATENCY_WINDOW_AFTER_WARMUP}"
		printf 'reset_fault_latency_window_after_ops=%s\n' \
			"${RESET_FAULT_LATENCY_WINDOW_AFTER_OPS}"
		printf 'fault_latency_window_seconds=%s\n' \
			"${FAULT_LATENCY_WINDOW_SECONDS}"
		printf 'target_seconds=%s\n' "${TARGET_SECONDS}"
		printf 'target_ops=%s\n' "$(cat "${OUTROOT}/target_ops" 2>/dev/null || printf '%s' "${TARGET_OPS}")"
		printf 'cases=%s\n' "${CASES}"
		printf 'mbench=%s\n' "${MBENCH}"
		printf 'mbench_sha256=%s\n' "$(sha256sum "${MBENCH}" | awk '{print $1}')"
	} > "${OUTROOT}/experiment.meta"
}

run_sweep() {
	local trace_root="$1" original_threads target_ops case_name thread_count label

	original_threads="${THREADS}"
	for thread_count in ${THREAD_COUNTS}; do
		THREADS="${thread_count}"
		label="t${THREADS}_calibrate_off"
		if [[ -n "${TARGET_OPS}" ]]; then
			target_ops="${TARGET_OPS}"
			printf '%s\n' "${target_ops}" > "${OUTROOT}/${label}.target_ops"
		else
			target_ops="$(calibrate_target_ops "${label}")"
		fi
		for case_name in ${CASES}; do
			case "${case_name}" in
			off) run_case "t${THREADS}_off" "${NUMA_BALANCING_OFF}" 0 "${target_ops}" "${trace_root}" ;;
			on) run_case "t${THREADS}_on" "${NUMA_BALANCING_ON}" 0 "${target_ops}" "${trace_root}" ;;
			on_trace) run_case "t${THREADS}_on_trace" "${NUMA_BALANCING_ON}" 1 "${target_ops}" "${trace_root}" ;;
			off_trace) run_case "t${THREADS}_off_trace" "${NUMA_BALANCING_OFF}" 1 "${target_ops}" "${trace_root}" ;;
			*) die "unknown case: ${case_name}" ;;
			esac
		done
	done
	THREADS="${original_threads}"
}

main() {
	local trace_root target_ops case_name

	require_environment
	set_common_knobs
	trace_root="$(cat "${OUTROOT}/trace_root.path")"
	if [[ -n "${THREAD_COUNTS}" ]]; then
		write_experiment_meta
		run_sweep "${trace_root}"
		log "done: ${OUTROOT}"
		return
	fi

	if [[ -n "${TARGET_OPS}" ]]; then
		target_ops="${TARGET_OPS}"
		printf '%s\n' "${target_ops}" > "${OUTROOT}/target_ops"
	else
		target_ops="$(calibrate_target_ops)"
	fi
	write_experiment_meta

	for case_name in ${CASES}; do
		case "${case_name}" in
		off) run_case off "${NUMA_BALANCING_OFF}" 0 "${target_ops}" "${trace_root}" ;;
		on) run_case on "${NUMA_BALANCING_ON}" 0 "${target_ops}" "${trace_root}" ;;
		on_trace) run_case on_trace "${NUMA_BALANCING_ON}" 1 "${target_ops}" "${trace_root}" ;;
		off_trace) run_case off_trace "${NUMA_BALANCING_OFF}" 1 "${target_ops}" "${trace_root}" ;;
		*) die "unknown case: ${case_name}" ;;
		esac
	done
	log "done: ${OUTROOT}"
}

main "$@"
