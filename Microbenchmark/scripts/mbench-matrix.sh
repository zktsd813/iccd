#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(dirname -- "$SCRIPT_DIR")
BIN="$ROOT_DIR/mbench"

log() {
    printf '[mbench-matrix] %s\n' "$*"
}

usage() {
    cat <<'EOF'
usage: mbench-matrix.sh [--build] [--dry-run]

Sweeps a small local matrix across modes, working-set sizes, and movement settings.
The script assumes the binary is at Microbenchmark/mbench.
EOF
}

BUILD=0
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --build)
            BUILD=1
            ;;
        --dry-run)
            DRY_RUN=1
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

build_if_needed() {
    if [ -x "$BIN" ]; then
        return
    fi

    if [ "$BUILD" -ne 1 ]; then
        log "binary not found: $BIN"
        log "rerun with --build after the project Makefile is available"
        exit 1
    fi

    if [ ! -f "$ROOT_DIR/Makefile" ]; then
        log "missing $ROOT_DIR/Makefile"
        exit 1
    fi

    log "building project with make"
    make -C "$ROOT_DIR"
}

run_case() {
    label=$1
    shift
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[mbench-matrix] dry-run %s -> %s\n' "$label" "$*"
        return
    fi
    printf '[mbench-matrix] run %s -> %s\n' "$label" "$*"
    "$BIN" "$@" 2>&1 | sed "s/^/[${label}] /"
}

build_if_needed

MODES="bw pc mix"
ARENA_SIZES="16M 32M"
WINDOW_SIZES="2M 4M"
MOVE_POLICIES="fixed sweep"

for mode in $MODES; do
    for arena in $ARENA_SIZES; do
        for window in $WINDOW_SIZES; do
            for move in $MOVE_POLICIES; do
                label="${mode}-${arena}-${window}-${move}"
                case "$mode" in
                    bw)
                        run_case "$label" \
                            --mode bw \
                            --threads 1 \
                            --arena-size "$arena" \
                            --window-size "$window" \
                            --window-offset 0 \
                            --move-policy "$move" \
                            --move-step 2M \
                            --duration 1 \
                            --sample-ms 250
                        ;;
                    pc)
                        run_case "$label" \
                            --mode pc \
                            --threads 1 \
                            --arena-size "$arena" \
                            --window-size "$window" \
                            --window-offset 0 \
                            --pc-chains 1 \
                            --move-policy "$move" \
                            --move-step 2M \
                            --duration 1 \
                            --sample-ms 250
                        ;;
                    mix)
                        run_case "$label" \
                            --mode mix \
                            --pc-threads 1 \
                            --bw-threads 1 \
                            --arena-size "$arena" \
                            --window-size "$window" \
                            --window-offset 0 \
                            --pc-chains 1 \
                            --move-policy "$move" \
                            --move-step 2M \
                            --duration 1 \
                            --sample-ms 250
                        ;;
                esac
            done
        done
    done
done
