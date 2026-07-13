#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CANONICAL_SWEEP="${CANONICAL_SWEEP:-${REPO_ROOT}/motivation/3_realworld/VM/scripts/run_vm_sweep_guest.sh}"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

require_fixed_value() {
  local name="$1" expected="$2" actual="${!1:-${2}}"
  [[ "${actual}" == "${expected}" ]] ||
    die "${name} must be ${expected} for the current protocol (got ${actual})"
  printf -v "${name}" '%s' "${expected}"
  export "${name}"
}

validate_configs() {
  local config
  [[ -n "${CONFIGS}" ]] || die "CONFIGS must not be empty"
  for config in ${CONFIGS}; do
    case "${config}" in
      off|on|tpp|ours) ;;
      *) die "unknown config '${config}'; expected off, on, tpp, or ours" ;;
    esac
  done
}

main() {
  (($# == 0)) || die "command-line options are not supported; configure the canonical sweep with environment variables"
  CONFIGS="${CONFIGS:-off on tpp ours}"
  validate_configs

  [[ "${GAPBS_GRAPH_MODE:-generated}" == "generated" ]] ||
    die "only generated GAPBS graphs are supported"
  [[ -z "${GRAPH:-}" ]] ||
    die "GRAPH is obsolete; PR and BC are generated in the measured path"
  require_fixed_value GAPBS_GRAPH_SCALE 29
  require_fixed_value NUMA_SCAN_SIZE_MB 256
  require_fixed_value LOCAL_FAULT_SCAN_SIZE_MB 64
  require_fixed_value LOCAL_FAULT_SCAN_PERIOD_MS 1000

  [[ -x "${CANONICAL_SWEEP}" ]] ||
    die "canonical guest sweep is not executable: ${CANONICAL_SWEEP}"

  export CONFIGS
  exec "${CANONICAL_SWEEP}"
}

main "$@"
