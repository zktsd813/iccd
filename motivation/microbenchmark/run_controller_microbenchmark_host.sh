#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

EXP_NAME="${EXP_NAME:-$(date -u +%Y%m%d-%H%M%S)-controller-microbenchmark}"
EXP_ROOT="${EXP_ROOT:-${SCRIPT_DIR}/results/${EXP_NAME}}"
FIGURE_DIR="${FIGURE_DIR:-${SCRIPT_DIR}/figure}"
COMMON_FIGURE_DIR="${COMMON_FIGURE_DIR:-${FIGURE_DIR}}"
FIGURE_PREFIX="${FIGURE_PREFIX:-${EXP_NAME}_}"

KERNEL="${KERNEL:-${REPO_ROOT}/linux-global-build/arch/x86/boot/bzImage}"
ROOTFS_BACKING="${ROOTFS_BACKING:-${REPO_ROOT}/experiments/20260602-pr28-smoke/images/pr28-smoke.qcow2}"
ROOTFS_OVERLAY="${ROOTFS_OVERLAY:-${EXP_ROOT}/images/controller-microbenchmark.qcow2}"
SSH_KEY="${SSH_KEY:-${REPO_ROOT}/experiments/20260602-pr28-smoke/keys/id_rsa}"
SSH_PORT="${SSH_PORT:-10118}"
VM_NAME="${VM_NAME:-iccd-controller-microbenchmark}"
FAST_MEM="${FAST_MEM:-16G}"
SLOW_MEM="${SLOW_MEM:-64G}"
HOST_CPUS="${HOST_CPUS:-0-31}"
GUEST_CPUS="${GUEST_CPUS:-32}"
GUEST_NODE0_CPUS="${GUEST_NODE0_CPUS:-0-31}"
FAST_HOST_NODE="${FAST_HOST_NODE:-0}"
SLOW_HOST_NODE="${SLOW_HOST_NODE:-2}"
GUEST_OUTROOT="${GUEST_OUTROOT:-/root/${EXP_NAME}}"
STOP_VM_ON_EXIT="${STOP_VM_ON_EXIT:-1}"
DELETE_VM_OVERLAY_ON_SUCCESS="${DELETE_VM_OVERLAY_ON_SUCCESS:-1}"

WORKLOAD_COMMAND="${WORKLOAD_COMMAND:-}"
CPU_NODE="${CPU_NODE:-0}"
OMP_THREADS="${OMP_THREADS:-32}"

WINDOW_SEC="${WINDOW_SEC:-5}"
LOCAL_RATE="${LOCAL_RATE:-5}"
REMOTE_RATE="${REMOTE_RATE:-5}"
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
NUMA_SCAN_SIZE_MB="${NUMA_SCAN_SIZE_MB:-256}"
NUMA_SCAN_PERIOD_MIN_MS="${NUMA_SCAN_PERIOD_MIN_MS:-1000}"
USE_KERNEL_DEFAULT_NUMA_SCAN="${USE_KERNEL_DEFAULT_NUMA_SCAN:-0}"
RESTORE_KNOBS="${RESTORE_KNOBS:-1}"
PLOT_AFTER="${PLOT_AFTER:-1}"

mkdir -p "${EXP_ROOT}/images" "${EXP_ROOT}/host-logs" \
	"${EXP_ROOT}/guest-results" "${EXP_ROOT}/figures" "${COMMON_FIGURE_DIR}"

log() {
	printf '[controller-microbenchmark-host] %s\n' "$*" >&2
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

scp_to_guest_path() {
	local src="$1" dst="$2"

	ssh_guest "mkdir -p $(printf '%q' "$(dirname -- "${dst}")")"
	scp -P "${SSH_PORT}" -i "${SSH_KEY}" \
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		"${src}" "root@127.0.0.1:${dst}"
}

guest_results_basename() {
	basename -- "${GUEST_OUTROOT}"
}

guest_results_local_root() {
	printf '%s/%s\n' "${EXP_ROOT}/guest-results" "$(guest_results_basename)"
}

guest_run_dir() {
	printf '%s/controller\n' "$(guest_results_local_root)"
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
	printf 'RUN_NAME=%q ' controller
	printf 'WORKLOAD_COMMAND=%q ' "${WORKLOAD_COMMAND}"
	for name in CPU_NODE OMP_THREADS WINDOW_SEC LOCAL_RATE REMOTE_RATE \
		MIN_LOCAL_PAGES MIN_REMOTE_PAGES BASELINE_SKIP_WINDOWS \
		CONSECUTIVE_EFFECTIVE CONSECUTIVE_NO_IMPROVE \
		RESTART_REMOTE_SHARE_THRESHOLD CONSECUTIVE_RESTART \
		RESTART_GRACE_WINDOWS NUMA_BALANCING_ON NUMA_BALANCING_OFF \
		MGLRU_ENABLED DEMOTION_ENABLED DEMOTION_TARGET NUMA_SCAN_SIZE_MB \
		NUMA_SCAN_PERIOD_MIN_MS USE_KERNEL_DEFAULT_NUMA_SCAN \
		RESTORE_KNOBS PLOT_AFTER; do
		printf '%s=%q ' "${name}" "${!name}"
	done
	printf '/root/design/fault_bucket_controller/run_guest.sh'
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

stage_guest_files() {
	log "building mbench"
	make -C "${REPO_ROOT}/Microbenchmark" -j"$(nproc)" mbench

	log "staging mbench and controller"
	scp_to_guest_path "${REPO_ROOT}/Microbenchmark/mbench" /root/mbench
	scp_to_guest_path "${REPO_ROOT}/design/fault_bucket_controller/run_guest.sh" \
		/root/design/fault_bucket_controller/run_guest.sh
	scp_to_guest_path "${REPO_ROOT}/design/fault_bucket_controller/bucket_latency_controller.py" \
		/root/design/fault_bucket_controller/bucket_latency_controller.py
	scp_to_guest_path "${REPO_ROOT}/design/fault_bucket_controller/plot_controller.py" \
		/root/design/fault_bucket_controller/plot_controller.py
	ssh_guest "chmod +x /root/mbench /root/design/fault_bucket_controller/*.py /root/design/fault_bucket_controller/run_guest.sh"
}

write_host_meta() {
	{
		printf 'experiment=%s\n' "${EXP_NAME}"
		printf 'kernel=%s\n' "${KERNEL}"
		printf 'rootfs_backing=%s\n' "${ROOTFS_BACKING}"
		printf 'rootfs_overlay=%s\n' "${ROOTFS_OVERLAY}"
		printf 'slow_memory_mode=host-cxl\n'
		printf 'host_cpus=%s\n' "${HOST_CPUS}"
		printf 'guest_cpus=%s\n' "${GUEST_CPUS}"
		printf 'guest_node0_cpus=%s\n' "${GUEST_NODE0_CPUS}"
		printf 'fast_host_node=%s\n' "${FAST_HOST_NODE}"
		printf 'slow_host_node=%s\n' "${SLOW_HOST_NODE}"
		printf 'fast_mem=%s\n' "${FAST_MEM}"
		printf 'slow_mem=%s\n' "${SLOW_MEM}"
		printf 'ssh_port=%s\n' "${SSH_PORT}"
		printf 'vm_name=%s\n' "${VM_NAME}"
		printf 'guest_outroot=%s\n' "${GUEST_OUTROOT}"
		printf 'workload_command=%s\n' "${WORKLOAD_COMMAND}"
		printf 'window_sec=%s\n' "${WINDOW_SEC}"
		printf 'local_rate=%s\n' "${LOCAL_RATE}"
		printf 'remote_rate=%s\n' "${REMOTE_RATE}"
		printf 'min_local_pages=%s\n' "${MIN_LOCAL_PAGES}"
		printf 'min_remote_pages=%s\n' "${MIN_REMOTE_PAGES}"
		printf 'baseline_skip_windows=%s\n' "${BASELINE_SKIP_WINDOWS}"
		printf 'consecutive_effective=%s\n' "${CONSECUTIVE_EFFECTIVE}"
		printf 'consecutive_no_improve=%s\n' "${CONSECUTIVE_NO_IMPROVE}"
		printf 'restart_remote_share_threshold=%s\n' "${RESTART_REMOTE_SHARE_THRESHOLD}"
		printf 'consecutive_restart=%s\n' "${CONSECUTIVE_RESTART}"
		printf 'restart_grace_windows=%s\n' "${RESTART_GRACE_WINDOWS}"
		printf 'numa_scan_size_mb=%s\n' "${NUMA_SCAN_SIZE_MB}"
		printf 'numa_scan_period_min_ms=%s\n' "${NUMA_SCAN_PERIOD_MIN_MS}"
		printf 'use_kernel_default_numa_scan=%s\n' "${USE_KERNEL_DEFAULT_NUMA_SCAN}"
		printf 'date_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	} > "${EXP_ROOT}/host.meta"
}

copy_common_figures() {
	local figure base

	shopt -s nullglob
	for figure in "${EXP_ROOT}/figures"/*.{svg,pdf}; do
		base="$(basename -- "${figure}")"
		cp "${figure}" "${COMMON_FIGURE_DIR}/${FIGURE_PREFIX}${base}"
	done
	shopt -u nullglob
}

generate_outputs() {
	local run_dir window_dir

	run_dir="$(guest_run_dir)"
	window_dir="${run_dir}/fault_latency_windows"
	[[ -s "${run_dir}/controller.csv" ]] ||
		die "missing controller CSV after guest run: ${run_dir}/controller.csv"

	cp "${run_dir}/controller.csv" "${EXP_ROOT}/window_decisions.csv"
	cp "${run_dir}/config.meta" "${EXP_ROOT}/controller_config.meta"
	cp "${run_dir}/command.txt" "${EXP_ROOT}/command.txt"
	python3 - "${EXP_ROOT}/window_decisions.csv" "${EXP_ROOT}/stop_events.csv" <<'PY'
import csv
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, newline="") as inf, open(dst, "w", newline="") as outf:
    reader = csv.DictReader(inf)
    fields = [
        "event",
        "window",
        "elapsed_ms",
        "decision",
        "stop_reason",
        "restart_decision",
        "local_p80_bucket",
        "remote_p20_bucket",
        "gap",
        "restart_ratio",
    ]
    writer = csv.DictWriter(outf, fieldnames=fields)
    writer.writeheader()
    for row in reader:
        if row.get("event") in {"off", "restart"}:
            writer.writerow({field: row.get(field, "") for field in fields})
PY

	log "plotting controller decisions"
	python3 "${REPO_ROOT}/design/fault_bucket_controller/plot_controller.py" \
		"${run_dir}/controller.csv" \
		--out-dir "${EXP_ROOT}/figures" \
		--prefix "controller"

	log "plotting fault-latency windows"
	python3 "${REPO_ROOT}/motivation/2_microbenchmark/plot_fault_latency_windows.py" \
		"${window_dir}" \
		--figure-dir "${EXP_ROOT}/figures" \
		--csv "${EXP_ROOT}/window_histogram_counts.csv" \
		--percentile-csv "${EXP_ROOT}/window_percentiles.csv" \
		--decision-csv "${EXP_ROOT}/window_decisions.csv"

	copy_common_figures
}

main() {
	local guest_rc copy_rc

	[[ -n "${WORKLOAD_COMMAND}" ]] || die "WORKLOAD_COMMAND must be set"
	require_file "${KERNEL}" "kernel image"
	require_file "${ROOTFS_BACKING}" "rootfs backing image"
	require_file "${SSH_KEY}" "SSH key"
	require_file "${REPO_ROOT}/VM/vmctl.sh" "VM control script"
	require_file "${REPO_ROOT}/design/fault_bucket_controller/run_guest.sh" \
		"guest controller runner"

	write_host_meta
	if [[ ! -e "${ROOTFS_OVERLAY}" ]]; then
		log "creating rootfs overlay: ${ROOTFS_OVERLAY}"
		qemu-img create -f qcow2 -F qcow2 -b "${ROOTFS_BACKING}" \
			"${ROOTFS_OVERLAY}"
	fi

	trap cleanup EXIT
	boot_vm
	stage_guest_files

	log "running guest controller workload"
	set +e
	ssh_guest "$(guest_env_command)"
	guest_rc=$?
	set -e

	log "copying guest results"
	set +e
	copy_results_from_guest
	copy_rc=$?
	set -e

	if [[ "${copy_rc}" -eq 0 ]]; then
		generate_outputs
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
	if [[ "${DELETE_VM_OVERLAY_ON_SUCCESS}" == "1" ]]; then
		rm -rf "${EXP_ROOT}/images"
	fi
	log "done: ${EXP_ROOT}"
}

main "$@"
