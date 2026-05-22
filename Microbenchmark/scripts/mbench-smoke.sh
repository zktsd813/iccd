#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(dirname -- "$SCRIPT_DIR")
BIN="$ROOT_DIR/mbench"

log() {
    printf '[mbench-smoke] %s\n' "$*"
}

build_if_needed() {
    if [ -x "$BIN" ]; then
        log "found existing binary: $BIN"
        return
    fi

    if [ ! -f "$ROOT_DIR/Makefile" ]; then
        log "missing $ROOT_DIR/Makefile"
        log "build the project first, then rerun this script"
        exit 1
    fi

    log "building project with make"
    make -C "$ROOT_DIR"

    if [ ! -x "$BIN" ]; then
        log "build finished but $BIN is still missing or not executable"
        exit 1
    fi
}

run_case() {
    name=$1
    shift

    log "running $name: $*"
    "$BIN" "$@" 2>&1 | sed "s/^/[${name}] /"
}

build_if_needed

run_case bw "$@" \
    --mode bw \
    --threads 1 \
    --arena-size 16M \
    --window-size 2M \
    --window-offset 0 \
    --move-policy fixed \
    --duration 2 \
    --sample-ms 250

run_case pc "$@" \
    --mode pc \
    --threads 1 \
    --arena-size 16M \
    --window-size 2M \
    --window-offset 0 \
    --pc-chains 1 \
    --move-policy fixed \
    --duration 2 \
    --sample-ms 250

run_case mix "$@" \
    --mode mix \
    --pc-threads 1 \
    --bw-threads 1 \
    --arena-size 32M \
    --window-size 4M \
    --window-offset 0 \
    --pc-chains 1 \
    --move-policy fixed \
    --duration 2 \
    --sample-ms 250
