#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(dirname -- "$SCRIPT_DIR")
BIN="${BIN:-$ROOT_DIR/mbench}"

PROFILE=ladder
BUILD=0
DRY_RUN=0

usage() {
    cat <<'EOF'
usage: mbench-mlp-ladder.sh [--build] [--dry-run] [--profile low|mid|mid-aggregate|ladder]

Runs pointer-chase profiles that expose a controlled amount of memory-level
parallelism (MLP). The benchmark keeps dependent pointer chasing within each
chain, then varies the number of independent chains.

Environment knobs:
  OUT_DIR              output directory
  ARENA                arena size, default 4G
  WINDOW               active window size, default 4G
  PLACEMENT            mbench placement string, default none
  WINDOW_SPLIT_LOCAL   local part for window-split placement, optional
  THREADS              worker threads; profile default applies if unset
  CHAINS_LIST          space-separated chain counts; profile default applies
  PC_PATTERN           random or stride, default random
  OPS_PER_PASS         per-worker operations per batch, default 1000000
  SAMPLE_MS            sample period, default 1000
  DURATION_MS          measured interval via MBENCH_FORCE_DURATION_MS, default 300000
  WARMUP_MS            warmup via MBENCH_FORCE_WARMUP_MS, default 120000
  MOVE_POLICY          fixed, pingpong, sweep, random; default fixed
  MOVE_STEP            move step, default 4M
  EXTRA_ARGS           extra arguments appended to mbench

Profiles:
  low            THREADS=1, CHAINS_LIST=1
  mid            THREADS=1, CHAINS_LIST=4
  mid-aggregate  THREADS=4, CHAINS_LIST=2
  ladder         THREADS=1, CHAINS_LIST="1 2 4 8 16"
EOF
}

log() {
    printf '[mbench-mlp-ladder] %s\n' "$*" >&2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --build)
            BUILD=1
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        --profile)
            shift
            [ $# -gt 0 ] || {
                log "missing value for --profile"
                exit 1
            }
            PROFILE=$1
            ;;
        --profile=*)
            PROFILE=${1#--profile=}
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log "unknown argument: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

THREADS_WAS_SET=0
CHAINS_WAS_SET=0
[ "${THREADS+x}" ] && THREADS_WAS_SET=1
[ "${CHAINS_LIST+x}" ] && CHAINS_WAS_SET=1

case "$PROFILE" in
    low)
        [ "$THREADS_WAS_SET" -eq 1 ] || THREADS=1
        [ "$CHAINS_WAS_SET" -eq 1 ] || CHAINS_LIST="1"
        ;;
    mid)
        [ "$THREADS_WAS_SET" -eq 1 ] || THREADS=1
        [ "$CHAINS_WAS_SET" -eq 1 ] || CHAINS_LIST="4"
        ;;
    mid-aggregate)
        [ "$THREADS_WAS_SET" -eq 1 ] || THREADS=4
        [ "$CHAINS_WAS_SET" -eq 1 ] || CHAINS_LIST="2"
        ;;
    ladder)
        [ "$THREADS_WAS_SET" -eq 1 ] || THREADS=1
        [ "$CHAINS_WAS_SET" -eq 1 ] || CHAINS_LIST="1 2 4 8 16"
        ;;
    *)
        log "invalid profile: $PROFILE"
        usage
        exit 1
        ;;
esac

ARENA="${ARENA:-4G}"
WINDOW="${WINDOW:-4G}"
PLACEMENT="${PLACEMENT:-none}"
WINDOW_SPLIT_LOCAL="${WINDOW_SPLIT_LOCAL:-}"
PC_PATTERN="${PC_PATTERN:-random}"
OPS_PER_PASS="${OPS_PER_PASS:-1000000}"
SAMPLE_MS="${SAMPLE_MS:-1000}"
DURATION_MS="${DURATION_MS:-300000}"
WARMUP_MS="${WARMUP_MS:-120000}"
MOVE_POLICY="${MOVE_POLICY:-fixed}"
MOVE_STEP="${MOVE_STEP:-4M}"
OUT_DIR="${OUT_DIR:-$PWD/mbench-mlp-ladder-$(date -u +%Y%m%dT%H%M%SZ)}"
EXTRA_ARGS="${EXTRA_ARGS:-}"

build_if_needed() {
    if [ -x "$BIN" ]; then
        return
    fi

    if [ "$BUILD" -ne 1 ]; then
        log "binary not found: $BIN"
        log "rerun with --build or set BIN=/path/to/mbench"
        exit 1
    fi

    log "building project with make"
    make -C "$ROOT_DIR"
}

run_case() {
    chains=$1
    label="pc-t${THREADS}-c${chains}"
    stdout="$OUT_DIR/${label}.csv"
    stderr="$OUT_DIR/${label}.stderr"
    cmdfile="$OUT_DIR/${label}.cmd"

    set -- "$BIN" \
        --mode pc \
        --arena-size "$ARENA" \
        --window-size "$WINDOW" \
        --move-policy "$MOVE_POLICY" \
        --move-step "$MOVE_STEP" \
        --placement "$PLACEMENT" \
        --threads "$THREADS" \
        --pc-chains "$chains" \
        --pc-pattern "$PC_PATTERN" \
        --ops-per-pass "$OPS_PER_PASS" \
        --sample-ms "$SAMPLE_MS" \
        --csv

    if [ -n "$WINDOW_SPLIT_LOCAL" ]; then
        set -- "$@" --window-split-local "$WINDOW_SPLIT_LOCAL"
    fi

    if [ -n "$EXTRA_ARGS" ]; then
        # shellcheck disable=SC2086
        set -- "$@" $EXTRA_ARGS
    fi

    {
        printf 'MBENCH_FORCE_DURATION_MS=%s MBENCH_FORCE_WARMUP_MS=%s ' "$DURATION_MS" "$WARMUP_MS"
        printf '%s ' "$@"
        printf '\n'
    } > "$cmdfile"

    if [ "$DRY_RUN" -eq 1 ]; then
        log "dry-run $label -> $(cat "$cmdfile")"
        return
    fi

    log "run $label -> stdout=$stdout stderr=$stderr"
    MBENCH_FORCE_DURATION_MS="$DURATION_MS" \
        MBENCH_FORCE_WARMUP_MS="$WARMUP_MS" \
        "$@" > "$stdout" 2> "$stderr"
}

build_if_needed
mkdir -p "$OUT_DIR"

{
    printf 'profile=%s\n' "$PROFILE"
    printf 'threads=%s\n' "$THREADS"
    printf 'chains_list=%s\n' "$CHAINS_LIST"
    printf 'arena=%s\n' "$ARENA"
    printf 'window=%s\n' "$WINDOW"
    printf 'placement=%s\n' "$PLACEMENT"
    printf 'window_split_local=%s\n' "$WINDOW_SPLIT_LOCAL"
    printf 'pc_pattern=%s\n' "$PC_PATTERN"
    printf 'ops_per_pass=%s\n' "$OPS_PER_PASS"
    printf 'duration_ms=%s\n' "$DURATION_MS"
    printf 'warmup_ms=%s\n' "$WARMUP_MS"
} > "$OUT_DIR/config.txt"

for chains in $CHAINS_LIST; do
    run_case "$chains"
done

log "done OUT_DIR=$OUT_DIR"
