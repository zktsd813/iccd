#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

EXP_NAME="${EXP_NAME:-hotset16-rss32-local24-hotset-half-random-page}"
EXP_ROOT="${EXP_ROOT:-${SCRIPT_DIR}/hotset16_rss32_local24_hotset_half_random_page/raw}"
PUBLIC_SUMMARY_DIR="${PUBLIC_SUMMARY_DIR:-${SCRIPT_DIR}/hotset16_rss32_local24_hotset_half_random_page}"
PUBLIC_FIGURE_DIR="${PUBLIC_FIGURE_DIR:-${PUBLIC_SUMMARY_DIR}/figures}"
COMMON_FIGURE_DIR="${COMMON_FIGURE_DIR:-${SCRIPT_DIR}/figure}"

FAST_MEM="${FAST_MEM:-24G}"
SLOW_MEM="${SLOW_MEM:-64G}"
ARENA_SIZE="${ARENA_SIZE:-32G}"
WINDOW_SIZE="${WINDOW_SIZE:-16G}"
WINDOW_SPLIT_LOCAL="${WINDOW_SPLIT_LOCAL:-8G}"
TARGET_OPS="${TARGET_OPS:-43686414250}"
TARGET_SECONDS="${TARGET_SECONDS:-120}"
CALIBRATE_MS="${CALIBRATE_MS:-10000}"
WARMUP_MS="${WARMUP_MS:-20000}"
THREADS="${THREADS:-32}"
SSH_PORT="${SSH_PORT:-10115}"
VM_NAME="${VM_NAME:-iccd-microbench-hotset16-local24-half-random}"
DELETE_VM_OVERLAY_ON_SUCCESS="${DELETE_VM_OVERLAY_ON_SUCCESS:-1}"

log() {
	printf '[hotset16-random-page] %s\n' "$*" >&2
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

write_run_meta() {
	mkdir -p "${EXP_ROOT}" "${PUBLIC_SUMMARY_DIR}" "${PUBLIC_FIGURE_DIR}" \
		"${COMMON_FIGURE_DIR}"
	{
		printf 'exp_name=%s\n' "${EXP_NAME}"
		printf 'fast_mem=%s\n' "${FAST_MEM}"
		printf 'slow_mem=%s\n' "${SLOW_MEM}"
		printf 'arena_size=%s\n' "${ARENA_SIZE}"
		printf 'window_size=%s\n' "${WINDOW_SIZE}"
		printf 'window_split_local=%s\n' "${WINDOW_SPLIT_LOCAL}"
		printf 'initial_local_hotset=%s\n' "${WINDOW_SPLIT_LOCAL}"
		printf 'initial_slow_hotset=%s\n' \
			"$(awk -v total="$(size_to_bytes "${WINDOW_SIZE}")" \
				-v local="$(size_to_bytes "${WINDOW_SPLIT_LOCAL}")" \
				'BEGIN { printf "%.0fG\n", (total - local) / 1024 / 1024 / 1024 }')"
		printf 'hotset_pages=%s\n' "$(size_to_pages "${WINDOW_SIZE}")"
		printf 'target_ops=%s\n' "${TARGET_OPS}"
		printf 'target_seconds=%s\n' "${TARGET_SECONDS}"
		printf 'calibrate_ms=%s\n' "${CALIBRATE_MS}"
		printf 'threads=%s\n' "${THREADS}"
		printf 'mbench_mode=skewed-hotset\n'
		printf 'hot_prob_pct=100\n'
		printf 'hotset_read_pct=100\n'
		printf 'hotset_write_pct=0\n'
		printf 'hotset_rmw_pct=0\n'
		printf 'hotset_index_mode=xorshift\n'
		printf 'use_kernel_default_numa_scan=1\n'
	} > "${PUBLIC_SUMMARY_DIR}/run.meta"
}

copy_public_artifacts() {
	local artifact_prefix base f

	artifact_prefix="${EXP_NAME//-/_}"
	cp "${EXP_ROOT}/summaries/summary.csv" \
		"${PUBLIC_SUMMARY_DIR}/${artifact_prefix}_summary.csv"
	for f in "${PUBLIC_FIGURE_DIR}"/*.{svg,pdf}; do
		[[ -e "${f}" ]] || continue
		base="$(basename -- "${f}")"
		cp "${f}" "${COMMON_FIGURE_DIR}/${artifact_prefix}_${base}"
	done
}

main() {
	if [[ -e "${EXP_ROOT}/summaries/summary.csv" ]]; then
		die "refusing to overwrite existing completed run: ${EXP_ROOT}"
	fi

	write_run_meta
	log "running ${EXP_NAME}: ${WINDOW_SPLIT_LOCAL} local within ${WINDOW_SIZE} hotset"
	EXP_NAME="${EXP_NAME}" \
	EXP_ROOT="${EXP_ROOT}" \
	FIGURE_DIR="${PUBLIC_FIGURE_DIR}" \
	GUEST_OUTROOT="/root/microbenchmark-${EXP_NAME}" \
	VM_NAME="${VM_NAME}" \
	SSH_PORT="${SSH_PORT}" \
	FAST_MEM="${FAST_MEM}" \
	SLOW_MEM="${SLOW_MEM}" \
	CASES="off on" \
	ARENA_SIZE="${ARENA_SIZE}" \
	WINDOW_SIZE="${WINDOW_SIZE}" \
	WINDOW_SPLIT_LOCAL="${WINDOW_SPLIT_LOCAL}" \
	PLACEMENT_MODE="window-split" \
	THREADS="${THREADS}" \
	THREAD_COUNTS="" \
	TARGET_OPS="${TARGET_OPS}" \
	TARGET_SECONDS="${TARGET_SECONDS}" \
	CALIBRATE_MS="${CALIBRATE_MS}" \
	WARMUP_MS="${WARMUP_MS}" \
	MBENCH_MODE="skewed-hotset" \
	HOTSET_PAGES="$(size_to_pages "${WINDOW_SIZE}")" \
	HOT_PROB_PCT="100" \
	HOTSET_READ_PCT="100" \
	HOTSET_WRITE_PCT="0" \
	HOTSET_RMW_PCT="0" \
	HOTSET_INDEX_MODE="xorshift" \
	USE_KERNEL_DEFAULT_NUMA_SCAN="1" \
		"${SCRIPT_DIR}/run_host.sh"

	copy_public_artifacts
	if [[ "${DELETE_VM_OVERLAY_ON_SUCCESS}" == "1" ]]; then
		rm -rf "${EXP_ROOT}/images"
	fi
	log "done: ${PUBLIC_SUMMARY_DIR}"
}

main "$@"
