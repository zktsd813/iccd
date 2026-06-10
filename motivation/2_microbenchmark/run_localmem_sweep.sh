#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

EXP_NAME="${EXP_NAME:-varying_local}"
EXP_ROOT="${EXP_ROOT:-${SCRIPT_DIR}/varying_local/raw}"
PUBLIC_SUMMARY_DIR="${PUBLIC_SUMMARY_DIR:-${SCRIPT_DIR}/varying_local}"
COMMON_FIGURE_DIR="${COMMON_FIGURE_DIR:-${SCRIPT_DIR}/varying_local/figures}"
LOCAL_MEM_VALUES="${LOCAL_MEM_VALUES:-8G 12G 16G 20G 24G 28G 32G}"
SLOW_MEM="${SLOW_MEM:-64G}"
TARGET_OPS="${TARGET_OPS:-43686414250}"
TARGET_SECONDS="${TARGET_SECONDS:-240}"
CALIBRATE_MS="${CALIBRATE_MS:-30000}"
DELETE_VM_OVERLAY_ON_SUCCESS="${DELETE_VM_OVERLAY_ON_SUCCESS:-1}"

log() {
	printf '[localmem-sweep] %s\n' "$*" >&2
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 2
}

local_label() {
	local mem="$1" gib

	gib="${mem%G}"
	[[ "${gib}" =~ ^[0-9]+$ ]] || die "LOCAL_MEM_VALUES must use GiB values like 8G: ${mem}"
	printf 'local-%02dG\n' "${gib}"
}

write_sweep_meta() {
	mkdir -p "${EXP_ROOT}/summaries" "${EXP_ROOT}/figures" "${COMMON_FIGURE_DIR}"
	{
		printf 'exp_name=%s\n' "${EXP_NAME}"
		printf 'local_mem_values=%s\n' "${LOCAL_MEM_VALUES}"
		printf 'slow_mem=%s\n' "${SLOW_MEM}"
		printf 'target_ops=%s\n' "${TARGET_OPS}"
		printf 'target_seconds=%s\n' "${TARGET_SECONDS}"
		printf 'calibrate_ms=%s\n' "${CALIBRATE_MS}"
		printf 'threads=32\n'
		printf 'arena_size=32G\n'
		printf 'window_size=32G\n'
		printf 'bw_shared_window=1\n'
		printf 'use_kernel_default_numa_scan=1\n'
	} > "${EXP_ROOT}/sweep.meta"
}

run_one() {
	local mem="$1" label subroot

	label="$(local_label "${mem}")"
	subroot="${EXP_ROOT}/${label}"
	if [[ -e "${subroot}/summaries/summary.csv" ]]; then
		die "refusing to overwrite existing completed subrun: ${subroot}"
	fi

	mkdir -p "${subroot}"
	{
		printf 'local_mem=%s\n' "${mem}"
		printf 'fast_mem=%s\n' "${mem}"
		printf 'window_split_local=%s\n' "${mem}"
		printf 'label=%s\n' "${label}"
	} > "${subroot}/local_mem.meta"

	log "running ${label}: FAST_MEM=${mem} WINDOW_SPLIT_LOCAL=${mem}"
	EXP_ROOT="${subroot}" \
	FIGURE_DIR="${subroot}/figures" \
	GUEST_OUTROOT="/root/microbenchmark-fixedops-${label}" \
	FAST_MEM="${mem}" \
	SLOW_MEM="${SLOW_MEM}" \
	CASES="off on" \
	ARENA_SIZE="32G" \
	WINDOW_SIZE="32G" \
	WINDOW_SPLIT_LOCAL="${mem}" \
	THREADS="32" \
	THREAD_COUNTS="" \
	BW_SHARED_WINDOW="1" \
	BW_STRIDE="512" \
	BW_BLOCK="4K" \
	TARGET_OPS="${TARGET_OPS}" \
	TARGET_SECONDS="${TARGET_SECONDS}" \
	CALIBRATE_MS="${CALIBRATE_MS}" \
	USE_KERNEL_DEFAULT_NUMA_SCAN="1" \
		"${SCRIPT_DIR}/run_host.sh"

	if [[ "${DELETE_VM_OVERLAY_ON_SUCCESS}" == "1" ]]; then
		rm -rf "${subroot}/images"
	fi
}

aggregate_results() {
	log "aggregating local memory sweep"
	python3 "${SCRIPT_DIR}/parse_localmem_sweep.py" "${EXP_ROOT}" \
		--summary-dir "${EXP_ROOT}/summaries" \
		--figure-dir "${EXP_ROOT}/figures"
	mkdir -p "${PUBLIC_SUMMARY_DIR}" "${COMMON_FIGURE_DIR}"
	cp "${EXP_ROOT}/summaries/summary_ko.md" \
		"${EXP_ROOT}/summaries/local_mem_sweep.csv" \
		"${PUBLIC_SUMMARY_DIR}/"
	cp "${EXP_ROOT}"/figures/localmem_*.svg "${EXP_ROOT}"/figures/localmem_*.pdf \
		"${COMMON_FIGURE_DIR}/" 2>/dev/null || true
}

main() {
	local mem

	write_sweep_meta
	for mem in ${LOCAL_MEM_VALUES}; do
		run_one "${mem}"
	done
	aggregate_results
	log "done: ${EXP_ROOT}"
}

main "$@"
