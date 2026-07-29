#define _GNU_SOURCE

#include "mbench.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>

static size_t mbench_min_size(size_t a, size_t b)
{
    return (a < b) ? a : b;
}

static size_t mbench_phase_max_offset(const struct mbench_config *config,
                                      size_t window_bytes)
{
    if (!config || config->window.arena_bytes <= window_bytes) {
        return 0;
    }
    return config->window.arena_bytes - window_bytes;
}

static int mbench_phase_thread_count(const struct mbench_config *config)
{
    if (!config) {
        return 1;
    }
    if (config->threads.total_threads > 0) {
        return config->threads.total_threads;
    }
    if (config->threads.bw_threads > 0) {
        return config->threads.bw_threads;
    }
    if (config->threads.pc_threads > 0) {
        return config->threads.pc_threads;
    }
    return 1;
}

static void mbench_phase_set_name(struct mbench_phase *phase, const char *name)
{
    if (!phase || !name) {
        return;
    }
    (void)snprintf(phase->name, sizeof(phase->name), "%s", name);
}

static int mbench_build_friendly_stream_phase(const struct mbench_config *base_config,
                                              size_t phase_index,
                                              struct mbench_phase *phase)
{
    const size_t phases_per_repeat = 2U;
    size_t repeat_index = phase_index / phases_per_repeat;
    size_t phase_kind = phase_index % phases_per_repeat;
    size_t friendly_window = base_config->window.window_bytes;
    size_t stream_window = friendly_window * 4U;
    int threads = mbench_phase_thread_count(base_config);

    if (stream_window < friendly_window || stream_window > base_config->window.arena_bytes) {
        stream_window = base_config->window.arena_bytes;
    }
    stream_window = mbench_min_size(stream_window, base_config->window.arena_bytes);
    if (stream_window < friendly_window) {
        stream_window = friendly_window;
    }

    memset(phase, 0, sizeof(*phase));
    phase->id = (uint32_t)(phase_index + 1U);
    phase->duration_ms = base_config->phase.duration_ms;
    phase->config = *base_config;
    phase->config.mode = MBENCH_MODE_BW;
    phase->config.bw_kernel = MBENCH_BW_READ;
    phase->config.threads.total_threads = threads;
    phase->config.threads.bw_threads = threads;
    phase->config.threads.pc_threads = 0;
    phase->config.threads.pc_chains = 1;
    phase->config.bw_pattern.stride_elements = 1U;
    phase->config.bw_pattern.block_bytes = 0;
    phase->config.request.pause_ns = base_config->request.pause_ns;
    phase->config.timing.move_interval_ms = base_config->timing.move_interval_ms;

    if (phase_kind == 0) {
        size_t max_offset = mbench_phase_max_offset(base_config, friendly_window);
        size_t offset = 0;

        if (friendly_window > 0 && max_offset > 0) {
            size_t slots = max_offset / friendly_window;
            offset = (repeat_index % (slots + 1U)) * friendly_window;
        }

        mbench_phase_set_name(phase, "friendly-bw-reuse");
        phase->config.window.window_bytes = friendly_window;
        phase->config.window.offset_bytes = offset;
        phase->config.window.move_policy = MBENCH_MOVE_FIXED;
        phase->config.window.move_step_bytes = friendly_window;
        return 0;
    }

    mbench_phase_set_name(phase, "unfriendly-stream");
    phase->config.bw_kernel = MBENCH_BW_TRIAD;
    phase->config.window.window_bytes = stream_window;
    phase->config.window.offset_bytes = 0;
    phase->config.window.move_policy = MBENCH_MOVE_SWEEP;
    phase->config.window.move_step_bytes = friendly_window;
    if (phase->config.timing.move_interval_ms == 0 ||
        phase->config.timing.move_interval_ms > phase->duration_ms / 2U) {
        phase->config.timing.move_interval_ms = phase->duration_ms >= 4000U
            ? phase->duration_ms / 4U
            : 1000U;
    }
    return 0;
}

static int mbench_build_tail_hotset_sparse_phase(const struct mbench_config *base_config,
                                                 size_t phase_index,
                                                 struct mbench_phase *phase,
                                                 size_t sparse_gib,
                                                 bool sparse_first)
{
    const size_t phases_per_repeat = 2U;
    const size_t gib = 1024ULL * 1024ULL * 1024ULL;
    const size_t page = 4096ULL;
    const size_t friendly_window = 4ULL * gib;
    const size_t sparse_window = sparse_gib * gib;
    const size_t friendly_offset = 44ULL * gib;
    const size_t friendly_move_min = 28ULL * gib;
    const size_t friendly_move_max = 44ULL * gib;
    const size_t friendly_move_step = 4ULL * gib;
    size_t phase_kind = phase_index % phases_per_repeat;
    int threads = mbench_phase_thread_count(base_config);

    if (!base_config || !phase ||
        base_config->window.arena_bytes < friendly_offset + friendly_window ||
        base_config->window.arena_bytes < sparse_window) {
        return -EINVAL;
    }
    if (sparse_first) {
        phase_kind = (phase_kind + 1U) % phases_per_repeat;
    }

    memset(phase, 0, sizeof(*phase));
    phase->id = (uint32_t)(phase_index + 1U);
    phase->duration_ms = base_config->phase.duration_ms;
    phase->config = *base_config;
    phase->config.threads.total_threads = threads;
    phase->config.threads.pc_threads = 0;
    phase->config.threads.pc_chains = 1;
    phase->config.request.pause_ns = base_config->request.pause_ns;

    if (phase_kind == 0) {
        mbench_phase_set_name(phase, "tail-hotset-4g-move-30s");
        phase->config.mode = MBENCH_MODE_SKEWED_HOTSET;
        phase->config.threads.bw_threads = 0;
        phase->config.window.window_bytes = friendly_window;
        phase->config.window.offset_bytes = friendly_offset;
        phase->config.window.move_policy = MBENCH_MOVE_RANDOM;
        phase->config.window.move_step_bytes = friendly_move_step;
        phase->config.window.move_min_offset_bytes = friendly_move_min;
        phase->config.window.move_max_offset_bytes = friendly_move_max;
        phase->config.timing.move_interval_ms = 30000U;
        phase->config.hotset.hotset_pages = (uint32_t)(friendly_window / page);
        phase->config.hotset.hot_prob_pct = 100U;
        phase->config.hotset.read_pct = 100U;
        phase->config.hotset.write_pct = 0U;
        phase->config.hotset.rmw_pct = 0U;
        return 0;
    }

    (void)snprintf(phase->name, sizeof(phase->name),
                   "sparse-stride-read-%zug", sparse_gib);
    phase->config.mode = MBENCH_MODE_BW;
    phase->config.bw_kernel = MBENCH_BW_READ;
    phase->config.threads.bw_threads = threads;
    phase->config.window.window_bytes = sparse_window;
    phase->config.window.offset_bytes = 0;
    phase->config.window.move_policy = MBENCH_MOVE_FIXED;
    phase->config.window.move_step_bytes = sparse_window;
    phase->config.window.move_min_offset_bytes = 0;
    phase->config.window.move_max_offset_bytes = 0;
    phase->config.bw_pattern.stride_elements = 512U;
    phase->config.bw_pattern.block_bytes = 4ULL * 1024ULL;
    phase->config.timing.move_interval_ms = base_config->timing.move_interval_ms;
    return 0;
}

static int mbench_build_skew4g_sparse64_phase(const struct mbench_config *base_config,
                                              size_t phase_index,
                                              struct mbench_phase *phase)
{
    const size_t gib = 1024ULL * 1024ULL * 1024ULL;
    const size_t page = 4096ULL;
    const size_t friendly_window = 4ULL * gib;
    const size_t sparse_window = 64ULL * gib;
    size_t phase_kind = phase_index % 2U;
    int threads = mbench_phase_thread_count(base_config);

    if (!base_config || !phase ||
        base_config->window.arena_bytes < friendly_window ||
        base_config->window.arena_bytes < sparse_window) {
        return -EINVAL;
    }

    memset(phase, 0, sizeof(*phase));
    phase->id = (uint32_t)(phase_index + 1U);
    phase->duration_ms = base_config->phase.duration_ms;
    phase->config = *base_config;
    phase->config.mode = MBENCH_MODE_BW;
    phase->config.threads.total_threads = threads;
    phase->config.threads.bw_threads = threads;
    phase->config.threads.pc_threads = 0;
    phase->config.threads.pc_chains = 1;
    phase->config.request.pause_ns = base_config->request.pause_ns;
    phase->config.window.offset_bytes = 0;
    phase->config.window.move_policy = MBENCH_MOVE_FIXED;
    phase->config.window.move_min_offset_bytes = 0;
    phase->config.window.move_max_offset_bytes = 0;
    phase->config.timing.move_interval_ms = base_config->timing.move_interval_ms;

    if (phase_kind == 0) {
        mbench_phase_set_name(phase, "skew-read-4g-move-5s");
        phase->config.mode = MBENCH_MODE_SKEWED_HOTSET;
        phase->config.threads.bw_threads = 0;
        phase->config.window.window_bytes = friendly_window;
        phase->config.window.move_policy = MBENCH_MOVE_RANDOM;
        phase->config.window.move_step_bytes = friendly_window;
        phase->config.window.move_max_offset_bytes = sparse_window - friendly_window;
        phase->config.timing.move_interval_ms = 5000U;
        phase->config.hotset.hotset_pages = (uint32_t)(friendly_window / page);
        phase->config.hotset.hot_prob_pct = 100U;
        phase->config.hotset.read_pct = 100U;
        phase->config.hotset.write_pct = 0U;
        phase->config.hotset.rmw_pct = 0U;
        return 0;
    }

    mbench_phase_set_name(phase, "sparse-read-64g");
    phase->config.mode = MBENCH_MODE_BW;
    phase->config.bw_kernel = MBENCH_BW_READ;
    phase->config.threads.bw_threads = threads;
    phase->config.window.window_bytes = sparse_window;
    phase->config.window.move_policy = MBENCH_MOVE_FIXED;
    phase->config.window.move_step_bytes = sparse_window;
    phase->config.bw_pattern.stride_elements = 512U;
    phase->config.bw_pattern.block_bytes = 4ULL * 1024ULL;
    return 0;
}

static int mbench_build_mulshift4g_sparse24_phase(const struct mbench_config *base_config,
                                                  size_t phase_index,
                                                  struct mbench_phase *phase,
                                                  bool rotate_friendly)
{
    const size_t gib = 1024ULL * 1024ULL * 1024ULL;
    const size_t page = 4096ULL;
    const size_t friendly_window = 4ULL * gib;
    const size_t sparse_window = 24ULL * gib;
    const size_t fixed_friendly_offset = 44ULL * gib;
    const size_t rotating_offsets[] = {40ULL * gib, 48ULL * gib, 56ULL * gib};
    size_t phase_kind = phase_index % 2U;
    size_t friendly_offset = fixed_friendly_offset;
    int threads = mbench_phase_thread_count(base_config);

    if (phase_kind == 0 && rotate_friendly) {
        size_t friendly_index = phase_index / 2U;
        friendly_offset = rotating_offsets[friendly_index %
                                           (sizeof(rotating_offsets) / sizeof(rotating_offsets[0]))];
    }

    if (!base_config || !phase ||
        base_config->window.arena_bytes < friendly_offset + friendly_window ||
        base_config->window.arena_bytes < sparse_window) {
        return -EINVAL;
    }

    memset(phase, 0, sizeof(*phase));
    phase->id = (uint32_t)(phase_index + 1U);
    phase->duration_ms = base_config->phase.duration_ms;
    phase->config = *base_config;
    phase->config.threads.total_threads = threads;
    phase->config.threads.pc_threads = 0;
    phase->config.threads.pc_chains = 1;
    phase->config.request.pause_ns = base_config->request.pause_ns;
    phase->config.window.move_min_offset_bytes = 0;
    phase->config.window.move_max_offset_bytes = 0;
    phase->config.timing.move_interval_ms = base_config->timing.move_interval_ms;

    if (phase_kind == 0) {
        if (rotate_friendly) {
            if (friendly_offset == 40ULL * gib) {
                mbench_phase_set_name(phase, "mulshift-hotset-4g-off40g");
            } else if (friendly_offset == 48ULL * gib) {
                mbench_phase_set_name(phase, "mulshift-hotset-4g-off48g");
            } else {
                mbench_phase_set_name(phase, "mulshift-hotset-4g-off56g");
            }
        } else {
            mbench_phase_set_name(phase, "mulshift-hotset-4g-fixed");
        }
        phase->config.mode = MBENCH_MODE_SKEWED_HOTSET;
        phase->config.threads.bw_threads = 0;
        phase->config.window.window_bytes = friendly_window;
        phase->config.window.offset_bytes = friendly_offset;
        phase->config.window.move_policy = MBENCH_MOVE_FIXED;
        phase->config.window.move_step_bytes = friendly_window;
        phase->config.hotset.hotset_pages = (uint32_t)(friendly_window / page);
        phase->config.hotset.hot_prob_pct = 100U;
        phase->config.hotset.read_pct = 100U;
        phase->config.hotset.write_pct = 0U;
        phase->config.hotset.rmw_pct = 0U;
        phase->config.hotset.index_mode = MBENCH_HOTSET_INDEX_MULSHIFT;
        return 0;
    }

    mbench_phase_set_name(phase, "sparse-stride-read-24g");
    phase->config.mode = MBENCH_MODE_BW;
    phase->config.bw_kernel = MBENCH_BW_READ;
    phase->config.threads.bw_threads = threads;
    phase->config.window.window_bytes = sparse_window;
    phase->config.window.offset_bytes = 0;
    phase->config.window.move_policy = MBENCH_MOVE_FIXED;
    phase->config.window.move_step_bytes = sparse_window;
    phase->config.bw_pattern.stride_elements = 512U;
    phase->config.bw_pattern.block_bytes = 4ULL * 1024ULL;
    return 0;
}

static int mbench_build_mulshift4g_sparse64_phase(const struct mbench_config *base_config,
                                                  size_t phase_index,
                                                  struct mbench_phase *phase,
                                                  bool rotate_friendly,
                                                  bool sparse_first,
                                                  size_t sparse_block_bytes)
{
    const size_t gib = 1024ULL * 1024ULL * 1024ULL;
    const size_t page = 4096ULL;
    const size_t friendly_window = 4ULL * gib;
    const size_t sparse_window = 64ULL * gib;
    const size_t fixed_friendly_offset = 60ULL * gib;
    const size_t rotating_offsets[] = {40ULL * gib, 48ULL * gib, 56ULL * gib};
    size_t phase_kind = phase_index % 2U;
    size_t friendly_offset = fixed_friendly_offset;
    int threads = mbench_phase_thread_count(base_config);

    if (sparse_first) {
        phase_kind = (phase_kind + 1U) % 2U;
    }
    if (phase_kind == 0 && rotate_friendly) {
        size_t friendly_index = phase_index / 2U;
        friendly_offset = rotating_offsets[friendly_index %
                                           (sizeof(rotating_offsets) / sizeof(rotating_offsets[0]))];
    }

    if (!base_config || !phase ||
        base_config->window.arena_bytes < friendly_offset + friendly_window ||
        base_config->window.arena_bytes < sparse_window) {
        return -EINVAL;
    }

    memset(phase, 0, sizeof(*phase));
    phase->id = (uint32_t)(phase_index + 1U);
    phase->duration_ms = base_config->phase.duration_ms;
    phase->config = *base_config;
    phase->config.threads.total_threads = threads;
    phase->config.threads.pc_threads = 0;
    phase->config.threads.pc_chains = 1;
    phase->config.request.pause_ns = base_config->request.pause_ns;
    phase->config.window.move_min_offset_bytes = 0;
    phase->config.window.move_max_offset_bytes = 0;
    phase->config.timing.move_interval_ms = base_config->timing.move_interval_ms;

    if (phase_kind == 0) {
        if (rotate_friendly) {
            if (friendly_offset == 40ULL * gib) {
                mbench_phase_set_name(phase, "mulshift-hotset-4g-off40g");
            } else if (friendly_offset == 48ULL * gib) {
                mbench_phase_set_name(phase, "mulshift-hotset-4g-off48g");
            } else {
                mbench_phase_set_name(phase, "mulshift-hotset-4g-off56g");
            }
        } else {
            mbench_phase_set_name(phase, "mulshift-hotset-4g-fixed");
        }
        phase->config.mode = MBENCH_MODE_SKEWED_HOTSET;
        phase->config.threads.bw_threads = 0;
        phase->config.window.window_bytes = friendly_window;
        phase->config.window.offset_bytes = friendly_offset;
        phase->config.window.move_policy = MBENCH_MOVE_FIXED;
        phase->config.window.move_step_bytes = friendly_window;
        phase->config.hotset.hotset_pages = (uint32_t)(friendly_window / page);
        phase->config.hotset.hot_prob_pct = 100U;
        phase->config.hotset.read_pct = 100U;
        phase->config.hotset.write_pct = 0U;
        phase->config.hotset.rmw_pct = 0U;
        phase->config.hotset.index_mode = MBENCH_HOTSET_INDEX_MULSHIFT;
        return 0;
    }

    if (sparse_block_bytes == 2ULL * 1024ULL * 1024ULL) {
        mbench_phase_set_name(phase, "sparse-stride-read-64g-block2m");
    } else {
        mbench_phase_set_name(phase, "sparse-stride-read-64g");
    }
    phase->config.mode = MBENCH_MODE_BW;
    phase->config.bw_kernel = MBENCH_BW_READ;
    phase->config.threads.bw_threads = threads;
    phase->config.window.window_bytes = sparse_window;
    phase->config.window.offset_bytes = 0;
    phase->config.window.move_policy = MBENCH_MOVE_FIXED;
    phase->config.window.move_step_bytes = sparse_window;
    phase->config.bw_pattern.stride_elements = 512U;
    phase->config.bw_pattern.block_bytes = sparse_block_bytes;
    return 0;
}

static int mbench_build_sparse64_weighted8g_phase(const struct mbench_config *base_config,
                                                  size_t phase_index,
                                                  struct mbench_phase *phase)
{
    const size_t gib = 1024ULL * 1024ULL * 1024ULL;
    const size_t page = 4096ULL;
    const size_t sparse_window = 64ULL * gib;
    const size_t weighted_window = 8ULL * gib;
    const size_t weighted_offset = 20ULL * gib;
    const size_t hotset_bytes = 4ULL * gib;
    int threads = mbench_phase_thread_count(base_config);

    if (!base_config || !phase ||
        base_config->window.arena_bytes < sparse_window ||
        base_config->window.arena_bytes < weighted_offset + weighted_window) {
        return -EINVAL;
    }

    memset(phase, 0, sizeof(*phase));
    phase->id = (uint32_t)(phase_index + 1U);
    phase->duration_ms = base_config->phase.duration_ms;
    phase->config = *base_config;
    phase->config.threads.total_threads = threads;
    phase->config.threads.pc_threads = 0;
    phase->config.threads.pc_chains = 1;
    phase->config.request.pause_ns = base_config->request.pause_ns;
    phase->config.window.move_min_offset_bytes = 0;
    phase->config.window.move_max_offset_bytes = 0;
    phase->config.timing.move_interval_ms = base_config->timing.move_interval_ms;

    if (phase_index % 2U == 0) {
        mbench_phase_set_name(phase, "sparse-stride-read-64g");
        phase->config.mode = MBENCH_MODE_BW;
        phase->config.bw_kernel = MBENCH_BW_READ;
        phase->config.threads.bw_threads = threads;
        phase->config.window.window_bytes = sparse_window;
        phase->config.window.offset_bytes = 0;
        phase->config.window.move_policy = MBENCH_MOVE_FIXED;
        phase->config.window.move_step_bytes = sparse_window;
        phase->config.bw_pattern.stride_elements = 512U;
        phase->config.bw_pattern.block_bytes = 4ULL * 1024ULL;
        phase->config.bw_pattern.shared_window = false;
        return 0;
    }

    mbench_phase_set_name(phase, "friendly-weighted-tail8g-off20g");
    phase->config.mode = MBENCH_MODE_SKEWED_HOTSET;
    phase->config.threads.bw_threads = 0;
    phase->config.window.window_bytes = weighted_window;
    phase->config.window.offset_bytes = weighted_offset;
    phase->config.window.move_policy = MBENCH_MOVE_FIXED;
    phase->config.window.move_step_bytes = weighted_window;
    phase->config.hotset.hotset_pages = (uint32_t)(hotset_bytes / page);
    phase->config.hotset.hot_prob_pct = 90U;
    phase->config.hotset.read_pct = 100U;
    phase->config.hotset.write_pct = 0U;
    phase->config.hotset.rmw_pct = 0U;
    phase->config.hotset.index_mode = MBENCH_HOTSET_INDEX_XORSHIFT;
    phase->config.hotset.shared_window = true;
    phase->config.hotset.tail = true;
    return 0;
}

static int mbench_build_sparse60_disjoint8g_phase(const struct mbench_config *base_config,
                                                  size_t phase_index,
                                                  struct mbench_phase *phase)
{
    const size_t gib = 1024ULL * 1024ULL * 1024ULL;
    const size_t page = 4096ULL;
    const size_t sparse_window = 60ULL * gib;
    const size_t disjoint_span = 44ULL * gib;
    const size_t disjoint_offset = 20ULL * gib;
    const size_t background_bytes = 4ULL * gib;
    int rc = mbench_build_sparse64_weighted8g_phase(base_config,
                                                    phase_index,
                                                    phase);

    if (rc != 0) {
        return rc;
    }

    if (phase_index % 2U == 0) {
        mbench_phase_set_name(phase, "sparse-stride-read-60g");
        phase->config.window.window_bytes = sparse_window;
        phase->config.window.move_step_bytes = sparse_window;
        return 0;
    }

    mbench_phase_set_name(phase, "friendly-disjoint8g-bg20-hot60");
    phase->config.window.window_bytes = disjoint_span;
    phase->config.window.offset_bytes = disjoint_offset;
    phase->config.window.move_step_bytes = disjoint_span;
    phase->config.hotset.background_pages =
        (uint32_t)(background_bytes / page);
    return 0;
}

static int mbench_build_sparse60_disjoint28g_phase(const struct mbench_config *base_config,
                                                   size_t phase_index,
                                                   struct mbench_phase *phase)
{
    const size_t gib = 1024ULL * 1024ULL * 1024ULL;
    const size_t page = 4096ULL;
    const size_t full_span = 64ULL * gib;
    const size_t background_bytes = 24ULL * gib;
    int rc = mbench_build_sparse60_disjoint8g_phase(base_config,
                                                    phase_index,
                                                    phase);

    if (rc != 0 || phase_index % 2U == 0) {
        return rc;
    }

    mbench_phase_set_name(phase, "friendly-disjoint28g-bg0-hot60");
    phase->config.window.window_bytes = full_span;
    phase->config.window.offset_bytes = 0;
    phase->config.window.move_step_bytes = full_span;
    phase->config.hotset.background_pages =
        (uint32_t)(background_bytes / page);
    return 0;
}

static int mbench_build_gups60_disjoint28g_phase(const struct mbench_config *base_config,
                                                 size_t phase_index,
                                                 struct mbench_phase *phase)
{
    const size_t gib = 1024ULL * 1024ULL * 1024ULL;
    const size_t page = 4096ULL;
    const size_t random_window = 60ULL * gib;
    int rc = mbench_build_sparse60_disjoint28g_phase(base_config,
                                                     phase_index,
                                                     phase);

    if (rc != 0 || phase_index % 2U != 0) {
        return rc;
    }

    mbench_phase_set_name(phase, "gups-random-rmw-60g");
    phase->config.mode = MBENCH_MODE_SKEWED_HOTSET;
    phase->config.threads.bw_threads = 0;
    phase->config.threads.pc_threads = 0;
    phase->config.window.window_bytes = random_window;
    phase->config.window.offset_bytes = 0;
    phase->config.window.move_policy = MBENCH_MOVE_FIXED;
    phase->config.window.move_step_bytes = random_window;
    phase->config.window.move_min_offset_bytes = 0;
    phase->config.window.move_max_offset_bytes = 0;
    phase->config.hotset.hotset_pages = (uint32_t)(random_window / page);
    phase->config.hotset.background_pages = 0;
    phase->config.hotset.hot_prob_pct = 100U;
    phase->config.hotset.read_pct = 0U;
    phase->config.hotset.write_pct = 0U;
    phase->config.hotset.rmw_pct = 100U;
    phase->config.hotset.index_mode = MBENCH_HOTSET_INDEX_XORSHIFT;
    phase->config.hotset.shared_window = true;
    phase->config.hotset.tail = false;
    return 0;
}

static int mbench_build_gups60_disjoint_bg24_hot_phase(
    const struct mbench_config *base_config,
    size_t phase_index,
    struct mbench_phase *phase,
    size_t hotset_gib,
    const char *phase_name)
{
    const size_t gib = 1024ULL * 1024ULL * 1024ULL;
    const size_t page = 4096ULL;
    const size_t full_span = 64ULL * gib;
    const size_t background_bytes = 24ULL * gib;
    const size_t hotset_bytes = hotset_gib * gib;
    int rc = mbench_build_gups60_disjoint28g_phase(base_config,
                                                   phase_index,
                                                   phase);

    if (rc != 0 || phase_index % 2U == 0) {
        return rc;
    }

    mbench_phase_set_name(phase, phase_name);
    phase->config.window.window_bytes = full_span;
    phase->config.window.offset_bytes = 0;
    phase->config.window.move_step_bytes = full_span;
    phase->config.hotset.hotset_pages = (uint32_t)(hotset_bytes / page);
    phase->config.hotset.background_pages =
        (uint32_t)(background_bytes / page);
    phase->config.hotset.hot_prob_pct = 80U;
    phase->config.hotset.read_pct = 100U;
    phase->config.hotset.write_pct = 0U;
    phase->config.hotset.rmw_pct = 0U;
    phase->config.hotset.index_mode = MBENCH_HOTSET_INDEX_XORSHIFT;
    phase->config.hotset.shared_window = true;
    phase->config.hotset.tail = true;
    return 0;
}

static int mbench_build_gups60_disjoint32g_phase(const struct mbench_config *base_config,
                                                 size_t phase_index,
                                                 struct mbench_phase *phase)
{
    return mbench_build_gups60_disjoint_bg24_hot_phase(
        base_config,
        phase_index,
        phase,
        8ULL,
        "friendly-disjoint32g-bg0-hot56");
}

static int mbench_build_gups60_disjoint36g_phase(const struct mbench_config *base_config,
                                                 size_t phase_index,
                                                 struct mbench_phase *phase)
{
    return mbench_build_gups60_disjoint_bg24_hot_phase(
        base_config,
        phase_index,
        phase,
        12ULL,
        "friendly-disjoint36g-bg0-hot52");
}

static int mbench_build_gups60_disjoint38g_phase(const struct mbench_config *base_config,
                                                 size_t phase_index,
                                                 struct mbench_phase *phase)
{
    return mbench_build_gups60_disjoint_bg24_hot_phase(
        base_config,
        phase_index,
        phase,
        14ULL,
        "friendly-disjoint38g-bg0-hot50");
}

static int mbench_build_gups60_disjoint40g_phase(const struct mbench_config *base_config,
                                                 size_t phase_index,
                                                 struct mbench_phase *phase)
{
    return mbench_build_gups60_disjoint_bg24_hot_phase(
        base_config,
        phase_index,
        phase,
        16ULL,
        "friendly-disjoint40g-bg0-hot48");
}

static int mbench_build_gups60_disjoint48g_phase(const struct mbench_config *base_config,
                                                 size_t phase_index,
                                                 struct mbench_phase *phase)
{
    return mbench_build_gups60_disjoint_bg24_hot_phase(
        base_config,
        phase_index,
        phase,
        24ULL,
        "friendly-disjoint48g-bg0-hot40");
}

static int mbench_build_mulshift4g_move16g3s_phase(const struct mbench_config *base_config,
                                                   size_t phase_index,
                                                   struct mbench_phase *phase)
{
    const size_t gib = 1024ULL * 1024ULL * 1024ULL;
    const size_t page = 4096ULL;
    const size_t friendly_window = 4ULL * gib;
    const size_t unfriendly_window = 16ULL * gib;
    const size_t rotating_offsets[] = {0ULL * gib, 24ULL * gib, 48ULL * gib};
    size_t phase_kind = phase_index % 2U;
    size_t friendly_index = phase_index / 2U;
    size_t friendly_offset = rotating_offsets[friendly_index %
                                               (sizeof(rotating_offsets) / sizeof(rotating_offsets[0]))];
    int threads = mbench_phase_thread_count(base_config);

    if (!base_config || !phase ||
        base_config->window.arena_bytes < friendly_offset + friendly_window ||
        base_config->window.arena_bytes < unfriendly_window) {
        return -EINVAL;
    }

    memset(phase, 0, sizeof(*phase));
    phase->id = (uint32_t)(phase_index + 1U);
    phase->duration_ms = base_config->phase.duration_ms;
    phase->config = *base_config;
    phase->config.mode = MBENCH_MODE_SKEWED_HOTSET;
    phase->config.threads.total_threads = threads;
    phase->config.threads.bw_threads = 0;
    phase->config.threads.pc_threads = 0;
    phase->config.threads.pc_chains = 1;
    phase->config.request.pause_ns = base_config->request.pause_ns;
    phase->config.hotset.hot_prob_pct = 100U;
    phase->config.hotset.read_pct = 100U;
    phase->config.hotset.write_pct = 0U;
    phase->config.hotset.rmw_pct = 0U;
    phase->config.hotset.index_mode = MBENCH_HOTSET_INDEX_MULSHIFT;

    if (phase_kind == 0) {
        if (friendly_offset == 0ULL) {
            mbench_phase_set_name(phase, "mulshift-hotset-4g-off0g");
        } else if (friendly_offset == 24ULL * gib) {
            mbench_phase_set_name(phase, "mulshift-hotset-4g-off24g");
        } else {
            mbench_phase_set_name(phase, "mulshift-hotset-4g-off48g");
        }
        phase->config.window.window_bytes = friendly_window;
        phase->config.window.offset_bytes = friendly_offset;
        phase->config.window.move_policy = MBENCH_MOVE_FIXED;
        phase->config.window.move_step_bytes = friendly_window;
        phase->config.window.move_min_offset_bytes = 0;
        phase->config.window.move_max_offset_bytes = 0;
        phase->config.hotset.hotset_pages = (uint32_t)(friendly_window / page);
        phase->config.timing.move_interval_ms = base_config->timing.move_interval_ms;
        return 0;
    }

    mbench_phase_set_name(phase, "mulshift-hotset-16g-move-3s");
    phase->config.window.window_bytes = unfriendly_window;
    phase->config.window.offset_bytes = 0;
    phase->config.window.move_policy = MBENCH_MOVE_RANDOM;
    phase->config.window.move_step_bytes = 4ULL * gib;
    phase->config.window.move_min_offset_bytes = 0;
    phase->config.window.move_max_offset_bytes = base_config->window.arena_bytes - unfriendly_window;
    phase->config.timing.move_interval_ms = 3000U;
    phase->config.hotset.hotset_pages = (uint32_t)(unfriendly_window / page);
    return 0;
}

static int mbench_build_move4g_split32_phase(const struct mbench_config *base_config,
                                             size_t phase_index,
                                             struct mbench_phase *phase,
                                             size_t friendly_window_gib,
                                             bool friendly_remote_only,
                                             bool friendly_fixed_remote,
                                             uint32_t friendly_move_interval_ms,
                                             const char *friendly_name)
{
    const size_t gib = 1024ULL * 1024ULL * 1024ULL;
    const size_t page = 4096ULL;
    const size_t friendly_window = friendly_window_gib * gib;
    const size_t unfriendly_window = 32ULL * gib;
    size_t phase_kind = phase_index % 2U;
    int threads = mbench_phase_thread_count(base_config);

    if (!base_config || !phase ||
        base_config->window.arena_bytes < friendly_window ||
        base_config->window.arena_bytes < unfriendly_window) {
        return -EINVAL;
    }

    memset(phase, 0, sizeof(*phase));
    phase->id = (uint32_t)(phase_index + 1U);
    phase->duration_ms = base_config->phase.duration_ms;
    phase->config = *base_config;
    phase->config.threads.total_threads = threads;
    phase->config.threads.pc_threads = 0;
    phase->config.threads.pc_chains = 1;
    phase->config.request.pause_ns = base_config->request.pause_ns;
    phase->config.window.offset_bytes = 0;
    phase->config.window.move_min_offset_bytes = 0;

    if (phase_kind == 0) {
        mbench_phase_set_name(phase, friendly_name);
        phase->config.mode = MBENCH_MODE_SKEWED_HOTSET;
        phase->config.threads.bw_threads = 0;
        phase->config.window.window_bytes = friendly_window;
        phase->config.window.move_policy = friendly_fixed_remote ?
            MBENCH_MOVE_FIXED : MBENCH_MOVE_RANDOM;
        phase->config.window.move_step_bytes = friendly_window;
        if (friendly_remote_only || friendly_fixed_remote) {
            phase->config.window.move_min_offset_bytes = 16ULL * gib;
        }
        if (friendly_fixed_remote) {
            phase->config.window.offset_bytes = 16ULL * gib;
        }
        phase->config.window.move_max_offset_bytes =
            friendly_fixed_remote ? 16ULL * gib :
            base_config->window.arena_bytes - friendly_window;
        phase->config.timing.move_interval_ms = friendly_move_interval_ms;
        phase->config.hotset.hotset_pages = (uint32_t)(friendly_window / page);
        phase->config.hotset.hot_prob_pct = 100U;
        phase->config.hotset.read_pct = 100U;
        phase->config.hotset.write_pct = 0U;
        phase->config.hotset.rmw_pct = 0U;
        phase->config.hotset.index_mode = MBENCH_HOTSET_INDEX_MULSHIFT;
        return 0;
    }

    mbench_phase_set_name(phase, "stream-read-32g-split16-4k");
    phase->config.mode = MBENCH_MODE_BW;
    phase->config.bw_kernel = MBENCH_BW_READ;
    phase->config.threads.bw_threads = threads;
    phase->config.window.window_bytes = unfriendly_window;
    phase->config.window.move_policy = MBENCH_MOVE_FIXED;
    phase->config.window.move_step_bytes = unfriendly_window;
    phase->config.window.move_max_offset_bytes = 0;
    phase->config.timing.move_interval_ms = base_config->timing.move_interval_ms;
    phase->config.bw_pattern.stride_elements = 512U;
    phase->config.bw_pattern.block_bytes = 4ULL * 1024ULL;
    return 0;
}

bool mbench_phase_enabled(const struct mbench_config *config)
{
    return config && config->phase.preset != MBENCH_PHASE_PRESET_NONE;
}

size_t mbench_phase_total_count(const struct mbench_config *config)
{
    if (!mbench_phase_enabled(config)) {
        return 0;
    }
    switch (config->phase.preset) {
    case MBENCH_PHASE_PRESET_FRIENDLY_STREAM:
    case MBENCH_PHASE_PRESET_TAIL_HOTSET_SPARSE16:
    case MBENCH_PHASE_PRESET_SPARSE24_TAIL_HOTSET:
    case MBENCH_PHASE_PRESET_TAIL_HOTSET_SPARSE24:
    case MBENCH_PHASE_PRESET_SKEW4G_SPARSE64:
    case MBENCH_PHASE_PRESET_MULSHIFT4G_SPARSE24:
    case MBENCH_PHASE_PRESET_MULSHIFT4G_SPARSE64:
    case MBENCH_PHASE_PRESET_MULSHIFT4G_ROT_SPARSE24:
    case MBENCH_PHASE_PRESET_MULSHIFT4G_ROT_SPARSE64:
    case MBENCH_PHASE_PRESET_MULSHIFT4G_ROT_MOVE16G3S:
    case MBENCH_PHASE_PRESET_MULSHIFT4G_BLOCK2M_SPARSE64:
    case MBENCH_PHASE_PRESET_MOVE15S4G_SPLIT32:
    case MBENCH_PHASE_PRESET_MOVE15S4G_REMOTE_SPLIT32:
    case MBENCH_PHASE_PRESET_MOVE60S4G_REMOTE_SPLIT32:
    case MBENCH_PHASE_PRESET_FIXED4G_REMOTE_SPLIT32:
    case MBENCH_PHASE_PRESET_FIXED8G_REMOTE_SPLIT32:
    case MBENCH_PHASE_PRESET_SPARSE64_MULSHIFT4G:
    case MBENCH_PHASE_PRESET_SPARSE64_WEIGHTED8G:
    case MBENCH_PHASE_PRESET_SPARSE60_DISJOINT8G:
    case MBENCH_PHASE_PRESET_SPARSE60_DISJOINT28G:
    case MBENCH_PHASE_PRESET_GUPS60_DISJOINT28G:
    case MBENCH_PHASE_PRESET_GUPS60_DISJOINT32G:
    case MBENCH_PHASE_PRESET_GUPS60_DISJOINT36G:
    case MBENCH_PHASE_PRESET_GUPS60_DISJOINT38G:
    case MBENCH_PHASE_PRESET_GUPS60_DISJOINT40G:
    case MBENCH_PHASE_PRESET_GUPS60_DISJOINT48G:
        return (size_t)config->phase.repeat * 2U;
    case MBENCH_PHASE_PRESET_NONE:
    default:
        return 0;
    }
}

static int mbench_phase_build_config(const struct mbench_config *base_config,
                                     size_t phase_index,
                                     struct mbench_phase *phase)
{
    if (!base_config || !phase || !mbench_phase_enabled(base_config)) {
        return -EINVAL;
    }
    if (phase_index >= mbench_phase_total_count(base_config)) {
        return -ERANGE;
    }

    switch (base_config->phase.preset) {
    case MBENCH_PHASE_PRESET_FRIENDLY_STREAM:
        return mbench_build_friendly_stream_phase(base_config, phase_index, phase);
    case MBENCH_PHASE_PRESET_TAIL_HOTSET_SPARSE16:
        return mbench_build_tail_hotset_sparse_phase(base_config, phase_index, phase, 16U, false);
    case MBENCH_PHASE_PRESET_TAIL_HOTSET_SPARSE24:
        return mbench_build_tail_hotset_sparse_phase(base_config, phase_index, phase, 24U, false);
    case MBENCH_PHASE_PRESET_SPARSE24_TAIL_HOTSET:
        return mbench_build_tail_hotset_sparse_phase(base_config, phase_index, phase, 24U, true);
    case MBENCH_PHASE_PRESET_SKEW4G_SPARSE64:
        return mbench_build_skew4g_sparse64_phase(base_config, phase_index, phase);
    case MBENCH_PHASE_PRESET_MULSHIFT4G_SPARSE24:
        return mbench_build_mulshift4g_sparse24_phase(base_config, phase_index, phase, false);
    case MBENCH_PHASE_PRESET_MULSHIFT4G_SPARSE64:
        return mbench_build_mulshift4g_sparse64_phase(base_config, phase_index, phase,
                                                       false, false, 4ULL * 1024ULL);
    case MBENCH_PHASE_PRESET_SPARSE64_MULSHIFT4G:
        return mbench_build_mulshift4g_sparse64_phase(base_config, phase_index, phase,
                                                       false, true, 4ULL * 1024ULL);
    case MBENCH_PHASE_PRESET_SPARSE64_WEIGHTED8G:
        return mbench_build_sparse64_weighted8g_phase(base_config, phase_index, phase);
    case MBENCH_PHASE_PRESET_SPARSE60_DISJOINT8G:
        return mbench_build_sparse60_disjoint8g_phase(base_config, phase_index, phase);
    case MBENCH_PHASE_PRESET_SPARSE60_DISJOINT28G:
        return mbench_build_sparse60_disjoint28g_phase(base_config, phase_index, phase);
    case MBENCH_PHASE_PRESET_GUPS60_DISJOINT28G:
        return mbench_build_gups60_disjoint28g_phase(base_config, phase_index, phase);
    case MBENCH_PHASE_PRESET_GUPS60_DISJOINT32G:
        return mbench_build_gups60_disjoint32g_phase(base_config, phase_index, phase);
    case MBENCH_PHASE_PRESET_GUPS60_DISJOINT36G:
        return mbench_build_gups60_disjoint36g_phase(base_config, phase_index, phase);
    case MBENCH_PHASE_PRESET_GUPS60_DISJOINT38G:
        return mbench_build_gups60_disjoint38g_phase(base_config, phase_index, phase);
    case MBENCH_PHASE_PRESET_GUPS60_DISJOINT40G:
        return mbench_build_gups60_disjoint40g_phase(base_config, phase_index, phase);
    case MBENCH_PHASE_PRESET_GUPS60_DISJOINT48G:
        return mbench_build_gups60_disjoint48g_phase(base_config, phase_index, phase);
    case MBENCH_PHASE_PRESET_MULSHIFT4G_ROT_SPARSE24:
        return mbench_build_mulshift4g_sparse24_phase(base_config, phase_index, phase, true);
    case MBENCH_PHASE_PRESET_MULSHIFT4G_ROT_SPARSE64:
        return mbench_build_mulshift4g_sparse64_phase(base_config, phase_index, phase,
                                                       true, false, 4ULL * 1024ULL);
    case MBENCH_PHASE_PRESET_MULSHIFT4G_ROT_MOVE16G3S:
        return mbench_build_mulshift4g_move16g3s_phase(base_config, phase_index, phase);
    case MBENCH_PHASE_PRESET_MULSHIFT4G_BLOCK2M_SPARSE64:
        return mbench_build_mulshift4g_sparse64_phase(base_config, phase_index, phase,
                                                       false, false,
                                                       2ULL * 1024ULL * 1024ULL);
    case MBENCH_PHASE_PRESET_MOVE15S4G_SPLIT32:
        return mbench_build_move4g_split32_phase(base_config, phase_index, phase,
                                                 4ULL, false, false, 15000U,
                                                 "move15s-hotset-4g-rss64");
    case MBENCH_PHASE_PRESET_MOVE15S4G_REMOTE_SPLIT32:
        return mbench_build_move4g_split32_phase(base_config, phase_index, phase,
                                                 4ULL, true, false, 15000U,
                                                 "move15s-hotset-4g-remote");
    case MBENCH_PHASE_PRESET_MOVE60S4G_REMOTE_SPLIT32:
        return mbench_build_move4g_split32_phase(base_config, phase_index, phase,
                                                 4ULL, true, false, 60000U,
                                                 "move60s-hotset-4g-remote");
    case MBENCH_PHASE_PRESET_FIXED4G_REMOTE_SPLIT32:
        return mbench_build_move4g_split32_phase(base_config, phase_index, phase,
                                                 4ULL, true, true, 0U,
                                                 "fixed4g-hotset-remote");
    case MBENCH_PHASE_PRESET_FIXED8G_REMOTE_SPLIT32:
        return mbench_build_move4g_split32_phase(base_config, phase_index, phase,
                                                 8ULL, true, true, 0U,
                                                 "fixed8g-hotset-remote");
    case MBENCH_PHASE_PRESET_NONE:
    default:
        return -EINVAL;
    }
}

int mbench_phase_build(const struct mbench_config *base_config,
                       size_t phase_index,
                       struct mbench_phase *phase)
{
    int rc = mbench_phase_build_config(base_config, phase_index, phase);

    if (rc != 0) {
        return rc;
    }

    phase->target_ops = (phase_index % 2U == 0)
        ? base_config->phase.phase1_target_ops
        : base_config->phase.phase2_target_ops;
    return 0;
}
