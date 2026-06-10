#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

EXP_NAME="${EXP_NAME:-btree_fault_latency_local16_10s_windows}"
EXP_ROOT="${EXP_ROOT:-${SCRIPT_DIR}/results/${EXP_NAME}}"
FIGURE_DIR="${FIGURE_DIR:-${SCRIPT_DIR}/figure}"
KERNEL="${KERNEL:-${REPO_ROOT}/linux-global-build/arch/x86/boot/bzImage}"
ROOTFS_BACKING="${ROOTFS_BACKING:-${REPO_ROOT}/experiments/20260602-pr28-smoke/images/pr28-smoke.qcow2}"
ROOTFS_OVERLAY="${ROOTFS_OVERLAY:-${EXP_ROOT}/images/btree-fault-latency.qcow2}"
SSH_KEY="${SSH_KEY:-${REPO_ROOT}/experiments/20260602-pr28-smoke/keys/id_rsa}"
SSH_PORT="${SSH_PORT:-10115}"
VM_NAME="${VM_NAME:-iccd-btree-fault-latency}"
FAST_MEM="${FAST_MEM:-16G}"
SLOW_MEM="${SLOW_MEM:-64G}"
HOST_CPUS="${HOST_CPUS:-0-31}"
GUEST_CPUS="${GUEST_CPUS:-32}"
GUEST_NODE0_CPUS="${GUEST_NODE0_CPUS:-0-31}"
FAST_HOST_NODE="${FAST_HOST_NODE:-0}"
SLOW_HOST_NODE="${SLOW_HOST_NODE:-2}"
GUEST_OUTROOT="${GUEST_OUTROOT:-/root/btree-fault-latency}"
STOP_VM_ON_EXIT="${STOP_VM_ON_EXIT:-1}"
WORKLOAD_LABEL="${WORKLOAD_LABEL:-btree_fault_latency}"
WORKLOADS_TO_STAGE="${WORKLOADS_TO_STAGE:-btree}"
WORKLOAD_COMMAND="${WORKLOAD_COMMAND:-}"
SKIP_WORKLOAD_STAGE="${SKIP_WORKLOAD_STAGE:-0}"
GAPBS_BC_HOST="${GAPBS_BC_HOST:-}"
GAPBS_BC_GUEST="${GAPBS_BC_GUEST:-/root/benchmark/gapbs/bc}"
GAPBS_GRAPH_HOST="${GAPBS_GRAPH_HOST:-}"
GAPBS_GRAPH_GUEST="${GAPBS_GRAPH_GUEST:-/root/gapbs_graphs/kron_g29.sg}"
FIGURE_PREFIX="${FIGURE_PREFIX:-btree_local16_10s_}"
SUMMARY_BASENAME="${SUMMARY_BASENAME:-btree_fault_latency}"

mkdir -p "${EXP_ROOT}/images" "${EXP_ROOT}/host-logs" \
	"${EXP_ROOT}/guest-results" "${EXP_ROOT}/summaries" "${FIGURE_DIR}"

log() {
	printf '[btree-fault-latency-host] %s\n' "$*" >&2
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
	printf 'BTREE=%q ' "/root/benchmark/vmitosis-workloads/bin/bench_btree_mt"
	printf 'WORKLOAD_LABEL=%q ' "${WORKLOAD_LABEL}"
	if [[ -n "${WORKLOAD_COMMAND}" ]]; then
		printf 'WORKLOAD_COMMAND=%q ' "${WORKLOAD_COMMAND}"
	fi
	for name in CPU_NODE OMP_THREADS MGLRU_ENABLED DEMOTION_ENABLED \
		DEMOTION_TARGET NUMA_SCAN_SIZE_MB NUMA_SCAN_PERIOD_MIN_MS \
		USE_KERNEL_DEFAULT_NUMA_SCAN NUMA_BALANCING_ON LOCAL_FAULT_RATE \
		FAULT_LATENCY_WINDOW_SECONDS MONITOR_INTERVAL_MS; do
		if [[ -n "${!name+x}" ]]; then
			printf '%s=%q ' "${name}" "${!name}"
		fi
	done
	printf '/root/run_btree_fault_latency_guest.sh'
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

stage_workloads() {
	log "staging workload(s): ${WORKLOADS_TO_STAGE}"
	if [[ "${SKIP_WORKLOAD_STAGE}" == "1" ]]; then
		log "skip default workload staging"
		return
	fi
	VM_ACTION=stage \
		PORT="${SSH_PORT}" \
		SSH_KEY="${SSH_KEY}" \
		VM_NAME="${VM_NAME}" \
		WORKLOADS="${WORKLOADS_TO_STAGE}" \
		VERIFY_PLACEMENT=1 \
		"${REPO_ROOT}/scripts/stage_workloads_to_vm.sh" \
		> "${EXP_ROOT}/host-logs/stage.log" 2>&1
}

stage_gapbs_bc_manual() {
	[[ -n "${GAPBS_BC_HOST}" ]] || return 0
	log "staging GAPBS BC binary: ${GAPBS_BC_HOST} -> ${GAPBS_BC_GUEST}"
	scp_to_guest_path "${GAPBS_BC_HOST}" "${GAPBS_BC_GUEST}" \
		> "${EXP_ROOT}/host-logs/stage-bc.log" 2>&1
	ssh_guest "chmod +x $(printf '%q' "${GAPBS_BC_GUEST}")"
}

stage_gapbs_graph() {
	[[ -n "${GAPBS_GRAPH_HOST}" ]] || return 0
	log "staging GAPBS graph: ${GAPBS_GRAPH_HOST} -> ${GAPBS_GRAPH_GUEST}"
	scp_to_guest_path "${GAPBS_GRAPH_HOST}" "${GAPBS_GRAPH_GUEST}" \
		> "${EXP_ROOT}/host-logs/stage-graph.log" 2>&1
	ssh_guest "ls -lh $(printf '%q' "${GAPBS_GRAPH_GUEST}")"
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
		printf 'workload_label=%s\n' "${WORKLOAD_LABEL}"
		printf 'workloads_to_stage=%s\n' "${WORKLOADS_TO_STAGE}"
		printf 'workload_command=%s\n' "${WORKLOAD_COMMAND}"
		printf 'skip_workload_stage=%s\n' "${SKIP_WORKLOAD_STAGE}"
		printf 'gapbs_bc_host=%s\n' "${GAPBS_BC_HOST}"
		printf 'gapbs_bc_guest=%s\n' "${GAPBS_BC_GUEST}"
		printf 'gapbs_graph_host=%s\n' "${GAPBS_GRAPH_HOST}"
		printf 'gapbs_graph_guest=%s\n' "${GAPBS_GRAPH_GUEST}"
		printf 'local_fault_rate=%s\n' "${LOCAL_FAULT_RATE:-10}"
		printf 'fault_latency_window_seconds=%s\n' "${FAULT_LATENCY_WINDOW_SECONDS:-10}"
		printf 'date_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	} > "${EXP_ROOT}/host.meta"
}

generate_outputs() {
	local case_dir window_dir figure_local
	local figure_prefix

	case_dir="$(guest_results_local_root)/on"
	window_dir="${case_dir}/fault_latency_windows"
	figure_local="${EXP_ROOT}/summaries/fault_latency_window_figures"
	figure_prefix="${FIGURE_PREFIX}"

	log "summarizing results"
	python3 "${SCRIPT_DIR}/summarize_fault_latency_workload.py" \
		"${case_dir}" \
		--experiment-root "${EXP_ROOT}" \
		--summary-dir "${EXP_ROOT}/summaries" \
		--summary-basename "${SUMMARY_BASENAME}" \
		--title "${WORKLOAD_LABEL} fault latency histogram summary"

	log "plotting fault-latency windows"
	python3 "${SCRIPT_DIR}/plot_fault_latency_windows.py" \
		"${window_dir}" \
		--figure-dir "${figure_local}" \
		--csv "${EXP_ROOT}/summaries/${SUMMARY_BASENAME}_windows.csv" \
		--percentile-csv "${EXP_ROOT}/summaries/${SUMMARY_BASENAME}_window_percentile_buckets.csv"

	shopt -s nullglob
	for figure in "${figure_local}"/*.{svg,pdf}; do
		cp "${figure}" "${FIGURE_DIR}/${figure_prefix}$(basename -- "${figure}")"
	done
	shopt -u nullglob
}

main() {
	require_file "${KERNEL}" "kernel image"
	require_file "${ROOTFS_BACKING}" "rootfs backing image"
	require_file "${SSH_KEY}" "SSH key"
	require_file "${REPO_ROOT}/scripts/stage_workloads_to_vm.sh" "workload staging script"
	require_file "${SCRIPT_DIR}/run_btree_fault_latency_guest.sh" "guest runner"
	require_file "${SCRIPT_DIR}/summarize_fault_latency_workload.py" "summary script"
	if [[ -n "${GAPBS_BC_HOST}" ]]; then
		require_file "${GAPBS_BC_HOST}" "GAPBS BC binary"
	fi
	if [[ -n "${GAPBS_GRAPH_HOST}" ]]; then
		require_file "${GAPBS_GRAPH_HOST}" "GAPBS graph"
	fi

	write_host_meta
	if [[ ! -e "${ROOTFS_OVERLAY}" ]]; then
		log "creating rootfs overlay: ${ROOTFS_OVERLAY}"
		qemu-img create -f qcow2 -F qcow2 -b "${ROOTFS_BACKING}" \
			"${ROOTFS_OVERLAY}"
	fi

	trap cleanup EXIT
	boot_vm
	stage_workloads
	stage_gapbs_bc_manual
	stage_gapbs_graph

	log "staging guest runner"
	scp_to_guest_root "${SCRIPT_DIR}/run_btree_fault_latency_guest.sh"
	ssh_guest "chmod +x /root/run_btree_fault_latency_guest.sh"

	log "running guest experiment"
	set +e
	ssh_guest "$(guest_env_command)" > "${EXP_ROOT}/host-logs/guest-run.log" 2>&1
	local guest_rc=$?
	set -e

	log "copying guest results"
	set +e
	copy_results_from_guest
	local copy_rc=$?
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
	log "done: ${EXP_ROOT}"
}

main "$@"
