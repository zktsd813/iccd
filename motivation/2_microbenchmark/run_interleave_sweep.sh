#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

EXP_NAME="${EXP_NAME:-interleave}"
EXP_ROOT="${EXP_ROOT:-${SCRIPT_DIR}/interleave/raw}"
PUBLIC_SUMMARY_DIR="${PUBLIC_SUMMARY_DIR:-${SCRIPT_DIR}/interleave}"
PUBLIC_FIGURE_DIR="${PUBLIC_FIGURE_DIR:-${SCRIPT_DIR}/interleave/figures}"
LOCAL_MEM_VALUES="${LOCAL_MEM_VALUES:-8G 12G 16G 20G 24G 28G 32G}"
INTERLEAVE_MODES="${INTERLEAVE_MODES:-all_slow half_local}"
SLOW_MEM="${SLOW_MEM:-64G}"
SMOKE="${SMOKE:-0}"
if [[ "${SMOKE}" == "1" ]]; then
	TARGET_OPS="${TARGET_OPS:-1000000}"
else
	TARGET_OPS="${TARGET_OPS:-43686414250}"
fi
TARGET_SECONDS="${TARGET_SECONDS:-240}"
CALIBRATE_MS="${CALIBRATE_MS:-30000}"
DELETE_VM_OVERLAY_ON_SUCCESS="${DELETE_VM_OVERLAY_ON_SUCCESS:-1}"

log() {
	printf '[interleave-sweep] %s\n' "$*" >&2
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 2
}

mem_gib() {
	local mem="$1" gib

	gib="${mem%G}"
	[[ "${gib}" =~ ^[0-9]+$ ]] ||
		die "memory values must use GiB suffix like 8G: ${mem}"
	printf '%s\n' "${gib}"
}

local_label() {
	printf 'local-%02dG\n' "$(mem_gib "$1")"
}

half_mem() {
	local gib

	gib="$(mem_gib "$1")"
	(( gib % 2 == 0 )) ||
		die "half_local requires an even GiB local memory size: $1"
	printf '%dG\n' $((gib / 2))
}

slow_hotset_mem() {
	local local_hot_gib

	local_hot_gib="$(mem_gib "$1")"
	printf '%dG\n' $((32 - local_hot_gib))
}

write_sweep_meta() {
	mkdir -p "${EXP_ROOT}" "${PUBLIC_SUMMARY_DIR}" "${PUBLIC_FIGURE_DIR}"
	{
		printf 'exp_name=%s\n' "${EXP_NAME}"
		printf 'local_mem_values=%s\n' "${LOCAL_MEM_VALUES}"
		printf 'interleave_modes=%s\n' "${INTERLEAVE_MODES}"
		printf 'slow_mem=%s\n' "${SLOW_MEM}"
		printf 'target_ops=%s\n' "${TARGET_OPS}"
		printf 'target_seconds=%s\n' "${TARGET_SECONDS}"
		printf 'calibrate_ms=%s\n' "${CALIBRATE_MS}"
		printf 'smoke=%s\n' "${SMOKE}"
		printf 'threads=32\n'
		printf 'arena_size=32G\n'
		printf 'window_size=32G\n'
		printf 'bw_shared_window=1\n'
		printf 'use_kernel_default_numa_scan=1\n'
	} > "${EXP_ROOT}/sweep.meta"
}

run_one() {
	local mode="$1" mem="$2" label subroot placement_mode split_local
	local initial_local_hotset initial_slow_hotset guest_label

	label="$(local_label "${mem}")"
	subroot="${EXP_ROOT}/${mode}/${label}"
	if [[ -e "${subroot}/summaries/summary.csv" ]]; then
		die "refusing to overwrite existing completed subrun: ${subroot}"
	fi

	case "${mode}" in
	all_slow)
		placement_mode="all-slow"
		split_local="0G"
		initial_local_hotset="0G"
		initial_slow_hotset="32G"
		;;
	half_local)
		placement_mode="window-split"
		split_local="$(half_mem "${mem}")"
		initial_local_hotset="${split_local}"
		initial_slow_hotset="$(slow_hotset_mem "${split_local}")"
		;;
	*) die "unknown interleave mode: ${mode}" ;;
	esac

	mkdir -p "${subroot}"
	{
		printf 'mode=%s\n' "${mode}"
		printf 'local_mem=%s\n' "${mem}"
		printf 'fast_mem=%s\n' "${mem}"
		printf 'slow_mem=%s\n' "${SLOW_MEM}"
		printf 'placement_mode=%s\n' "${placement_mode}"
		printf 'window_split_local=%s\n' "${split_local}"
		printf 'initial_local_hotset=%s\n' "${initial_local_hotset}"
		printf 'initial_slow_hotset=%s\n' "${initial_slow_hotset}"
		printf 'label=%s\n' "${label}"
	} > "${subroot}/interleave.meta"

	guest_label="microbenchmark-interleave-${mode}-${label}"
	log "running ${mode}/${label}: FAST_MEM=${mem} initial_local_hotset=${initial_local_hotset}"
	EXP_ROOT="${subroot}" \
	FIGURE_DIR="${subroot}/figures" \
	GUEST_OUTROOT="/root/${guest_label}" \
	FAST_MEM="${mem}" \
	SLOW_MEM="${SLOW_MEM}" \
	CASES="off on" \
	ARENA_SIZE="32G" \
	WINDOW_SIZE="32G" \
	WINDOW_SPLIT_LOCAL="${split_local}" \
	PLACEMENT_MODE="${placement_mode}" \
	THREADS="32" \
	THREAD_COUNTS="" \
	BW_SHARED_WINDOW="1" \
	BW_STRIDE="512" \
	BW_BLOCK="4K" \
	TARGET_OPS="${TARGET_OPS}" \
	TARGET_SECONDS="${TARGET_SECONDS}" \
	CALIBRATE_MS="${CALIBRATE_MS}" \
	USE_KERNEL_DEFAULT_NUMA_SCAN="1" \
	SMOKE="${SMOKE}" \
	SMOKE_CASES="${SMOKE_CASES:-off on}" \
		"${SCRIPT_DIR}/run_host.sh"

	if [[ "${DELETE_VM_OVERLAY_ON_SUCCESS}" == "1" ]]; then
		rm -rf "${subroot}/images"
	fi
}

aggregate_results() {
	log "aggregating interleave sweep"
	python3 "${SCRIPT_DIR}/parse_interleave_sweep.py" "${EXP_ROOT}" \
		--summary-dir "${PUBLIC_SUMMARY_DIR}" \
		--figure-dir "${PUBLIC_FIGURE_DIR}"
}

main() {
	local mode mem

	write_sweep_meta
	for mode in ${INTERLEAVE_MODES}; do
		for mem in ${LOCAL_MEM_VALUES}; do
			run_one "${mode}" "${mem}"
		done
	done
	aggregate_results
	log "done: ${PUBLIC_SUMMARY_DIR}"
}

main "$@"
