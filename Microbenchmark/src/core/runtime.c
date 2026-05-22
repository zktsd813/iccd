#define _GNU_SOURCE

#include "mbench.h"

#include <errno.h>
#include <stdatomic.h>
#include <string.h>

static inline uint64_t mbench_xorshift64(uint64_t *state)
{
    uint64_t x = *state;

    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    if (x == 0) {
        x = 0x9e3779b97f4a7c15ULL;
    }
    *state = x;
    return x;
}

static void mbench_runtime_set_phase_name(struct mbench_runtime *runtime,
                                          const char *name)
{
    size_t len;

    if (!runtime) {
        return;
    }

    if (!name || name[0] == '\0') {
        name = "phase";
    }

    len = strlen(name);
    if (len >= sizeof(runtime->phase_name)) {
        len = sizeof(runtime->phase_name) - 1U;
    }
    memset(runtime->phase_name, 0, sizeof(runtime->phase_name));
    memcpy(runtime->phase_name, name, len);
}

int mbench_window_init(struct mbench_window_state *window,
                       const struct mbench_config *config)
{
    if (!window || !config) {
        return -EINVAL;
    }

    memset(window, 0, sizeof(*window));
    window->arena_bytes = config->window.arena_bytes;
    window->window_bytes = config->window.window_bytes;
    atomic_init(&window->current_offset, config->window.offset_bytes);
    window->move_step_bytes = config->window.move_step_bytes;
    window->move_min_offset_bytes = config->window.move_min_offset_bytes;
    window->move_max_offset_bytes = config->window.move_max_offset_bytes;
    window->move_policy = config->window.move_policy;
    window->move_direction = 1;
    window->move_rng_state = config->seed ? config->seed : 0x9e3779b97f4a7c15ULL;

    size_t arena_max_offset = (window->arena_bytes > window->window_bytes)
        ? (window->arena_bytes - window->window_bytes)
        : 0;
    if (window->move_min_offset_bytes > arena_max_offset) {
        window->move_min_offset_bytes = arena_max_offset;
    }
    if (window->move_max_offset_bytes == 0 ||
        window->move_max_offset_bytes > arena_max_offset) {
        window->move_max_offset_bytes = arena_max_offset;
    }
    if (window->move_max_offset_bytes < window->move_min_offset_bytes) {
        window->move_max_offset_bytes = window->move_min_offset_bytes;
    }
    if (atomic_load_explicit(&window->current_offset, memory_order_relaxed) <
        window->move_min_offset_bytes) {
        atomic_store_explicit(&window->current_offset,
                              window->move_min_offset_bytes,
                              memory_order_relaxed);
    }
    if (atomic_load_explicit(&window->current_offset, memory_order_relaxed) >
        window->move_max_offset_bytes) {
        atomic_store_explicit(&window->current_offset,
                              window->move_max_offset_bytes,
                              memory_order_relaxed);
    }
    if (window->move_step_bytes == 0) {
        window->move_step_bytes = window->window_bytes;
    }
    if (window->move_step_bytes == 0) {
        window->move_step_bytes = 1;
    }
    return 0;
}

int mbench_window_advance(struct mbench_window_state *window)
{
    if (!window) {
        return -EINVAL;
    }

    size_t min_offset = window->move_min_offset_bytes;
    size_t max_offset = window->move_max_offset_bytes;
    if (window->move_policy == MBENCH_MOVE_FIXED || max_offset <= min_offset) {
        return 0;
    }

    size_t step = window->move_step_bytes ? window->move_step_bytes : window->window_bytes;
    if (step == 0) {
        step = 1;
    }
    size_t current = atomic_load_explicit(&window->current_offset, memory_order_relaxed);

    switch (window->move_policy) {
    case MBENCH_MOVE_PINGPONG:
        if (window->move_direction > 0) {
            if (current >= max_offset || current + step >= max_offset) {
                current = max_offset;
                window->move_direction = -1;
            } else {
                current += step;
            }
        } else {
            if (current <= min_offset || current - min_offset <= step) {
                current = min_offset;
                window->move_direction = 1;
            } else {
                current -= step;
            }
        }
        break;
    case MBENCH_MOVE_SWEEP:
        current += step;
        if (current > max_offset) {
            current = min_offset;
        }
        break;
    case MBENCH_MOVE_RANDOM:
        if (step == 0 || step > max_offset - min_offset) {
            current = min_offset +
                (size_t)(mbench_xorshift64(&window->move_rng_state) %
                         ((uint64_t)(max_offset - min_offset) + 1ULL));
        } else {
            size_t slots = (max_offset - min_offset) / step;
            current = min_offset +
                (size_t)(mbench_xorshift64(&window->move_rng_state) %
                         ((uint64_t)slots + 1ULL)) * step;
        }
        break;
    case MBENCH_MOVE_FIXED:
    default:
        break;
    }

    if (current < min_offset) {
        current = min_offset;
    } else if (current > max_offset) {
        current = max_offset;
    }
    atomic_store_explicit(&window->current_offset, current, memory_order_relaxed);
    return 0;
}

void mbench_window_reset(struct mbench_window_state *window)
{
    if (!window) {
        return;
    }
    atomic_store_explicit(&window->current_offset,
                          window->move_min_offset_bytes,
                          memory_order_relaxed);
    window->move_direction = 1;
}

int mbench_runtime_prepare(struct mbench_runtime *runtime,
                           struct mbench_config *config)
{
    if (!runtime || !config) {
        return -EINVAL;
    }

    int rc = mbench_config_validate(config);
    if (rc != 0) {
        return rc;
    }

    memset(runtime, 0, sizeof(*runtime));
    runtime->config = *config;
    atomic_init(&runtime->completed_ops, 0);
    atomic_init(&runtime->completed_bytes, 0);
    atomic_init(&runtime->stop_requested, 0);

    rc = mbench_window_init(&runtime->window, &runtime->config);
    if (rc != 0) {
        return rc;
    }

    rc = mbench_arena_init(&runtime->arena,
                           runtime->config.window.arena_bytes,
                           runtime->config.hugepage,
                           false);
    if (rc != 0) {
        return rc;
    }

    if (runtime->config.placement.kind != MBENCH_PLACEMENT_NONE) {
        rc = mbench_apply_placement(&runtime->config, &runtime->arena);
        if (rc != 0) {
            mbench_arena_destroy(&runtime->arena);
            return rc;
        }
    }

    if (runtime->config.prefault) {
        if (runtime->config.phase.preset == MBENCH_PHASE_PRESET_MOVE15S4G_SPLIT32 ||
            runtime->config.phase.preset == MBENCH_PHASE_PRESET_MOVE15S4G_REMOTE_SPLIT32 ||
            runtime->config.phase.preset == MBENCH_PHASE_PRESET_MOVE60S4G_REMOTE_SPLIT32 ||
            runtime->config.phase.preset == MBENCH_PHASE_PRESET_FIXED4G_REMOTE_SPLIT32 ||
            runtime->config.phase.preset == MBENCH_PHASE_PRESET_FIXED8G_REMOTE_SPLIT32) {
            rc = mbench_arena_prefault_head_local_tail_remote(&runtime->arena,
                                                              &runtime->config);
        } else if (runtime->config.placement.kind == MBENCH_PLACEMENT_WINDOW_SPLIT) {
            rc = mbench_arena_prefault_window_split(&runtime->arena,
                                                    &runtime->config);
        } else if (runtime->config.hotset.prefault_node >= 0) {
            rc = mbench_arena_prefault_hotset_node(&runtime->arena,
                                                   &runtime->config);
        } else {
            rc = mbench_arena_prefault(&runtime->arena);
        }
        if (rc != 0) {
            mbench_arena_destroy(&runtime->arena);
            return rc;
        }
    }

    runtime->sink = 0;
    runtime->phase_id = 0;
    mbench_runtime_set_phase_name(runtime, "single");
    return 0;
}

void mbench_runtime_release(struct mbench_runtime *runtime)
{
    if (!runtime) {
        return;
    }
    mbench_arena_destroy(&runtime->arena);
    memset(&runtime->window, 0, sizeof(runtime->window));
    memset(&runtime->config, 0, sizeof(runtime->config));
    atomic_init(&runtime->completed_ops, 0);
    atomic_init(&runtime->completed_bytes, 0);
    atomic_init(&runtime->stop_requested, 0);
    runtime->sink = 0;
    runtime->phase_id = 0;
    memset(runtime->phase_name, 0, sizeof(runtime->phase_name));
}

int mbench_runtime_advance_window(struct mbench_runtime *runtime)
{
    if (!runtime) {
        return -EINVAL;
    }
    return mbench_window_advance(&runtime->window);
}

int mbench_runtime_apply_phase(struct mbench_runtime *runtime,
                               const struct mbench_phase *phase)
{
    struct mbench_config phase_config;
    int rc;

    if (!runtime || !phase || runtime->arena.bytes == 0) {
        return -EINVAL;
    }

    phase_config = phase->config;
    phase_config.window.arena_bytes = runtime->arena.bytes;
    if (phase_config.window.window_bytes == 0 ||
        phase_config.window.window_bytes > runtime->arena.bytes) {
        return -EINVAL;
    }
    if (phase_config.window.offset_bytes >
        runtime->arena.bytes - phase_config.window.window_bytes) {
        phase_config.window.offset_bytes = runtime->arena.bytes - phase_config.window.window_bytes;
    }
    if (phase_config.window.move_step_bytes == 0) {
        phase_config.window.move_step_bytes = phase_config.window.window_bytes;
    }

    runtime->config = phase_config;
    rc = mbench_window_init(&runtime->window, &runtime->config);
    if (rc != 0) {
        return rc;
    }

    atomic_store_explicit(&runtime->stop_requested, 0, memory_order_relaxed);
    runtime->phase_id = phase->id;
    mbench_runtime_set_phase_name(runtime, phase->name);
    return 0;
}
