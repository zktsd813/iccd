#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

EXP_NAME="${EXP_NAME:-$(date -u +%Y%m%d-%H%M%S)-microbenchmark-fixedops}"
EXP_ROOT="${EXP_ROOT:-${SCRIPT_DIR}/results/${EXP_NAME}}"
FIGURE_DIR="${FIGURE_DIR:-${SCRIPT_DIR}/figure}"
KERNEL="${KERNEL:-${REPO_ROOT}/linux-global-build/arch/x86/boot/bzImage}"
ROOTFS_BACKING="${ROOTFS_BACKING:-${REPO_ROOT}/experiments/20260602-pr28-smoke/images/pr28-smoke.qcow2}"
ROOTFS_OVERLAY="${ROOTFS_OVERLAY:-${EXP_ROOT}/images/microbenchmark-fixedops.qcow2}"
SSH_KEY="${SSH_KEY:-${REPO_ROOT}/experiments/20260602-pr28-smoke/keys/id_rsa}"
SSH_PORT="${SSH_PORT:-10112}"
VM_NAME="${VM_NAME:-iccd-microbenchmark-fixedops}"
FAST_MEM="${FAST_MEM:-20G}"
SLOW_MEM="${SLOW_MEM:-64G}"
HOST_CPUS="${HOST_CPUS:-0-31}"
GUEST_CPUS="${GUEST_CPUS:-32}"
GUEST_NODE0_CPUS="${GUEST_NODE0_CPUS:-0-31}"
FAST_HOST_NODE="${FAST_HOST_NODE:-0}"
SLOW_HOST_NODE="${SLOW_HOST_NODE:-2}"
GUEST_OUTROOT="${GUEST_OUTROOT:-/root/microbenchmark-fixedops}"
STOP_VM_ON_EXIT="${STOP_VM_ON_EXIT:-1}"

mkdir -p "${EXP_ROOT}/images" "${EXP_ROOT}/host-logs" \
	"${EXP_ROOT}/guest-results" "${EXP_ROOT}/summaries" "${FIGURE_DIR}"

log() {
	printf '[microbenchmark-fixedops-host] %s\n' "$*" >&2
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 2
}

require_file() {
	local path="$1" desc="$2"
	[[ -e "${path}" ]] || die "missing ${desc}: ${path}"
}

cleanup() {
	set +e
	if [[ "${STOP_VM_ON_EXIT}" == "1" ]]; then
		"${REPO_ROOT}/VM/vmctl.sh" stop --name "${VM_NAME}" >/dev/null 2>&1
	fi
	if [[ -n "${BOOT_PID:-}" ]]; then
		wait "${BOOT_PID}" >/dev/null 2>&1
	fi
}

ssh_guest() {
	"${REPO_ROOT}/VM/vmctl.sh" ssh \
		--ssh-key "${SSH_KEY}" --ssh-port "${SSH_PORT}" --name "${VM_NAME}" \
		-- "$@"
}

scp_to_guest_root() {
	scp -P "${SSH_PORT}" -i "${SSH_KEY}" \
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		"$@" "root@127.0.0.1:/root/"
}

guest_results_basename() {
	basename -- "${GUEST_OUTROOT}"
}

guest_results_local_root() {
	printf '%s/%s\n' "${EXP_ROOT}/guest-results" "$(guest_results_basename)"
}

copy_results_from_guest() {
	local parent base

	parent="$(dirname -- "${GUEST_OUTROOT}")"
	base="$(guest_results_basename)"
	mkdir -p "${EXP_ROOT}/guest-results"
	ssh_guest "cd $(printf '%q' "${parent}") && tar -cf - $(printf '%q' "${base}")" \
		| tar -xf - -C "${EXP_ROOT}/guest-results"
}

guest_env_command() {
	printf 'OUTROOT=%q ' "${GUEST_OUTROOT}"
	printf 'MBENCH=%q ' "/root/mbench"
	for name in CASES TARGET_SECONDS TARGET_OPS CALIBRATE_MS WARMUP_MS \
		SAMPLE_MS ARENA_SIZE WINDOW_SIZE WINDOW_SPLIT_LOCAL THREADS \
		THREAD_COUNTS PLACEMENT_MODE MBENCH_MODE \
		BW_STRIDE BW_BLOCK CPU_NODE MGLRU_ENABLED DEMOTION_ENABLED \
		HOTSET_PAGES HOT_PROB_PCT HOTSET_READ_PCT HOTSET_WRITE_PCT \
		HOTSET_RMW_PCT HOTSET_INDEX_MODE \
		DEMOTION_TARGET NUMA_SCAN_SIZE_MB NUMA_SCAN_PERIOD_MIN_MS \
		USE_KERNEL_DEFAULT_NUMA_SCAN \
		NUMA_BALANCING_ON NUMA_BALANCING_OFF LOCAL_FAULT_RATE \
		RESET_FAULT_LATENCY_WINDOW \
		RESET_FAULT_LATENCY_WINDOW_AFTER_WARMUP \
		RESET_FAULT_LATENCY_WINDOW_AFTER_OPS \
		FAULT_LATENCY_WINDOW_SECONDS TRACE_BUFFER_KB \
		MONITOR_INTERVAL_MS SMOKE SMOKE_CASES SMOKE_ARENA_SIZE \
		SMOKE_WINDOW_SIZE SMOKE_WINDOW_SPLIT_LOCAL SMOKE_THREADS \
		SMOKE_TARGET_SECONDS SMOKE_CALIBRATE_MS SMOKE_WARMUP_MS \
		BW_SHARED_WINDOW; do
		if [[ -n "${!name+x}" ]]; then
			printf '%s=%q ' "${name}" "${!name}"
		fi
	done
	printf '/root/run_guest.sh'
}

boot_vm() {
	log "booting VM ${VM_NAME} on SSH port ${SSH_PORT}"
	"${REPO_ROOT}/VM/vmctl.sh" boot \
		--name "${VM_NAME}" \
		--kernel "${KERNEL}" \
		--rootfs "${ROOTFS_OVERLAY}" \
		--rootfs-format qcow2 \
		--root-device /dev/vda2 \
		--ssh-key "${SSH_KEY}" \
		--ssh-port "${SSH_PORT}" \
		--host-cpus "${HOST_CPUS}" \
		--guest-cpus "${GUEST_CPUS}" \
		--guest-node0-cpus "${GUEST_NODE0_CPUS}" \
		--fast-host-node "${FAST_HOST_NODE}" \
		--slow-host-node "${SLOW_HOST_NODE}" \
		--fast-mem "${FAST_MEM}" \
		--slow-mem "${SLOW_MEM}" \
		--slow-memory-mode host-cxl \
		--accel kvm > "${EXP_ROOT}/host-logs/boot.log" 2>&1 &
	BOOT_PID=$!
	SSH_TIMEOUT="${SSH_TIMEOUT:-300}" "${REPO_ROOT}/VM/vmctl.sh" wait-ssh \
		--ssh-key "${SSH_KEY}" --ssh-port "${SSH_PORT}" --name "${VM_NAME}"
}

main() {
	require_file "${KERNEL}" "kernel image"
	require_file "${ROOTFS_BACKING}" "rootfs backing image"
	require_file "${SSH_KEY}" "SSH key"

	log "building mbench"
	make -C "${REPO_ROOT}/Microbenchmark" -j"$(nproc)" mbench

	if [[ ! -e "${ROOTFS_OVERLAY}" ]]; then
		log "creating rootfs overlay: ${ROOTFS_OVERLAY}"
		qemu-img create -f qcow2 -F qcow2 -b "${ROOTFS_BACKING}" \
			"${ROOTFS_OVERLAY}"
	fi

	trap cleanup EXIT
	boot_vm

	log "staging guest files"
	scp_to_guest_root "${REPO_ROOT}/Microbenchmark/mbench" "${SCRIPT_DIR}/run_guest.sh"
	ssh_guest "chmod +x /root/mbench /root/run_guest.sh"

	log "running guest experiment"
	set +e
	ssh_guest "$(guest_env_command)"
	local guest_rc=$?
	set -e

	log "copying guest results"
	set +e
	copy_results_from_guest
	local copy_rc=$?
	set -e

	if [[ "${copy_rc}" -eq 0 ]]; then
		log "parsing results"
		python3 "${SCRIPT_DIR}/parse_results.py" "$(guest_results_local_root)" \
			--summary-dir "${EXP_ROOT}/summaries" \
			--figure-dir "${FIGURE_DIR}"
	else
		log "guest result copy failed with rc=${copy_rc}"
	fi
	if [[ "${guest_rc}" -ne 0 ]]; then
		log "guest experiment failed with rc=${guest_rc}"
		exit "${guest_rc}"
	fi
	if [[ "${copy_rc}" -ne 0 ]]; then
		exit "${copy_rc}"
	fi
	log "done: ${EXP_ROOT}"
}

main "$@"
