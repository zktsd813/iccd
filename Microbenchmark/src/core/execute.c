#define _GNU_SOURCE

#include "mbench.h"

#define MBENCH_BW_READ MBENCH_KERNEL_BW_READ
#define MBENCH_BW_WRITE MBENCH_KERNEL_BW_WRITE
#define MBENCH_BW_COPY MBENCH_KERNEL_BW_COPY
#define MBENCH_BW_TRIAD MBENCH_KERNEL_BW_TRIAD
#include "../kernels/mbench_kernels.h"
#undef MBENCH_BW_READ
#undef MBENCH_BW_WRITE
#undef MBENCH_BW_COPY
#undef MBENCH_BW_TRIAD

#include <errno.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

static uint64_t mbench_div_round_up_u64(uint64_t value, uint64_t divisor)
{
    return (value + divisor - 1ULL) / divisor;
}

static int mbench_u64_to_size(uint64_t value, size_t *out)
{
    if (!out) {
        return -EINVAL;
    }
    if (value > SIZE_MAX) {
        return -ERANGE;
    }
    *out = (size_t)value;
    return 0;
}

static uint64_t mbench_requested_ops(const struct mbench_runtime *runtime, uint64_t fallback)
{
    if (runtime->config.request.ops_per_pass > 0) {
        return runtime->config.request.ops_per_pass;
    }
    return fallback;
}

static size_t mbench_bw_capacity_elements(enum mbench_bw_kernel kernel, size_t bytes)
{
    switch (kernel) {
    case MBENCH_BW_READ:
    case MBENCH_BW_WRITE:
        return bytes / sizeof(double);
    case MBENCH_BW_COPY:
        return bytes / (2U * sizeof(double));
    case MBENCH_BW_TRIAD:
        return bytes / (3U * sizeof(double));
    default:
        return 0;
    }
}

static size_t mbench_min_size(size_t a, size_t b)
{
    return (a < b) ? a : b;
}

static size_t mbench_bw_block_elements(const struct mbench_runtime *runtime, size_t capacity)
{
    size_t block_elements;

    if (runtime->config.bw_pattern.block_bytes == 0) {
        return capacity;
    }
    block_elements = mbench_bw_capacity_elements(runtime->config.bw_kernel,
                                                 runtime->config.bw_pattern.block_bytes);
    if (block_elements == 0) {
        block_elements = 1;
    }
    if (block_elements > capacity) {
        block_elements = capacity;
    }
    return block_elements;
}

static size_t mbench_bw_ops_per_pass(size_t elements, size_t block_elements, size_t stride_elements)
{
    size_t ops = 0;

    if (elements == 0 || block_elements == 0 || stride_elements == 0) {
        return 0;
    }
    for (size_t block_start = 0; block_start < elements; block_start += block_elements) {
        size_t block_len = mbench_min_size(block_elements, elements - block_start);
        ops += (block_len + stride_elements - 1U) / stride_elements;
    }
    return ops;
}

static int mbench_prepare_zipf_state(struct mbench_irregular_job *job)
{
    size_t bucket_count;
    long double total = 0.0L;
    long double cumulative = 0.0L;

    if (!job) {
        return -EINVAL;
    }
    if (job->dist_kind != MBENCH_INDEX_DIST_KIND_ZIPF) {
        return 0;
    }
    bucket_count = mbench_min_size(job->data_words, 4096U);
    if (bucket_count == 0) {
        return -EINVAL;
    }
    job->zipf_cdf = calloc(bucket_count, sizeof(*job->zipf_cdf));
    if (!job->zipf_cdf) {
        return -ENOMEM;
    }
    job->zipf_bucket_count = bucket_count;
    job->zipf_bucket_words = (job->data_words + bucket_count - 1U) / bucket_count;

    for (size_t i = 0; i < bucket_count; ++i) {
        total += 1.0L / powl((long double)(i + 1U), (long double)job->zipf_alpha);
    }
    if (total <= 0.0L) {
        free(job->zipf_cdf);
        job->zipf_cdf = NULL;
        return -EINVAL;
    }
    for (size_t i = 0; i < bucket_count; ++i) {
        cumulative += 1.0L / powl((long double)(i + 1U), (long double)job->zipf_alpha);
        job->zipf_cdf[i] = cumulative / total;
    }
    job->zipf_cdf[bucket_count - 1U] = 1.0L;
    return 0;
}

static int mbench_build_bw_job_slice(const struct mbench_runtime *runtime,
                                     struct mbench_bw_job *job,
                                     unsigned char *base,
                                     size_t slice_bytes)
{
    if (!runtime || !job || !base) {
        return -EINVAL;
    }

    size_t capacity = mbench_bw_capacity_elements(runtime->config.bw_kernel, slice_bytes);
    size_t stride_elements = runtime->config.bw_pattern.stride_elements > 0
        ? (size_t)runtime->config.bw_pattern.stride_elements
        : 1U;
    if (capacity == 0) {
        return -EINVAL;
    }

    size_t elements = capacity;
    size_t block_elements = mbench_bw_block_elements(runtime, elements);
    size_t ops_per_pass = mbench_bw_ops_per_pass(elements, block_elements, stride_elements);
    if (ops_per_pass == 0) {
        return -EINVAL;
    }
    uint64_t requested_ops = mbench_requested_ops(runtime, (uint64_t)ops_per_pass);

    uint64_t passes_u64 = mbench_div_round_up_u64(requested_ops, (uint64_t)ops_per_pass);
    size_t passes = 0;
    int rc = mbench_u64_to_size(passes_u64, &passes);
    if (rc != 0) {
        return rc;
    }

    memset(job, 0, sizeof(*job));
    job->kind = (enum mbench_bw_kind)runtime->config.bw_kernel;
    job->elements = elements;
    job->block_elements = block_elements;
    job->stride_elements = stride_elements;
    job->ops_per_pass = ops_per_pass;
    job->passes = passes;
    job->triad_scalar = 3.0;
    job->sink = NULL;

    switch (runtime->config.bw_kernel) {
    case MBENCH_BW_READ:
        job->src1 = (const double *)base;
        break;
    case MBENCH_BW_WRITE:
        job->dst = (double *)base;
        break;
    case MBENCH_BW_COPY:
        job->dst = (double *)base;
        job->src1 = (const double *)(base + elements * sizeof(double));
        break;
    case MBENCH_BW_TRIAD:
        job->dst = (double *)base;
        job->src1 = (const double *)(base + elements * sizeof(double));
        job->src2 = (const double *)(base + 2U * elements * sizeof(double));
        break;
    default:
        return -EINVAL;
    }

    return 0;
}

static int mbench_build_pc_job_slice(const struct mbench_runtime *runtime,
                                     struct mbench_pc_job *job,
                                     unsigned char *base,
                                     size_t slice_bytes,
                                     uint64_t seed)
{
    if (!runtime || !job || !base) {
        return -EINVAL;
    }

    size_t chains = (runtime->config.threads.pc_chains > 0)
        ? (size_t)runtime->config.threads.pc_chains
        : 1U;
    size_t total_slots = slice_bytes / sizeof(uint32_t);
    if (total_slots <= chains + 1U) {
        return -EINVAL;
    }

    size_t nodes = total_slots - chains;
    uint64_t requested_ops = mbench_requested_ops(runtime, (uint64_t)nodes * (uint64_t)chains);
    uint64_t passes_u64 = mbench_div_round_up_u64(requested_ops, (uint64_t)chains);
    size_t passes = 0;
    int rc = mbench_u64_to_size(passes_u64, &passes);
    if (rc != 0) {
        return rc;
    }

    uint32_t *ring = (uint32_t *)base;
    uint32_t *heads = ring + nodes;
    if (runtime->config.threads.pc_pattern == MBENCH_PC_PATTERN_STRIDE) {
        rc = mbench_init_pc_ring_stride(ring, nodes, seed);
    } else {
        rc = mbench_init_pc_ring(ring, nodes, seed);
    }
    if (rc != 0) {
        return rc;
    }
    rc = mbench_init_pc_heads(heads, chains, nodes, seed + 1U);
    if (rc != 0) {
        return rc;
    }

    memset(job, 0, sizeof(*job));
    job->ring = ring;
    job->heads = heads;
    job->nodes = nodes;
    job->chains = chains;
    job->passes = passes;
    job->sink = NULL;
    return 0;
}

static size_t mbench_slice_span(size_t total_bytes, size_t count)
{
    if (count == 0) {
        return 0;
    }
    return total_bytes / count;
}

static size_t mbench_random_ops_count(size_t bytes)
{
    size_t ops = bytes / 64U;
    if (ops < 4096U) {
        ops = 4096U;
    }
    if (ops > (1U << 20)) {
        ops = (1U << 20);
    }
    return ops;
}

static int mbench_build_skew_job_slice(const struct mbench_runtime *runtime,
                                       struct mbench_skew_job *job,
                                       unsigned char *base,
                                       size_t slice_bytes,
                                       uint64_t seed)
{
    if (!runtime || !job || !base || runtime->arena.page_size == 0) {
        return -EINVAL;
    }

    size_t data_words = slice_bytes / sizeof(uint64_t);
    size_t page_words = runtime->arena.page_size / sizeof(uint64_t);
    if (data_words == 0 || page_words == 0) {
        return -EINVAL;
    }

    size_t total_pages = data_words / page_words;
    if (total_pages == 0) {
        return -EINVAL;
    }

    size_t hot_pages = runtime->config.hotset.hotset_pages;
    if (hot_pages == 0 || hot_pages > total_pages) {
        hot_pages = total_pages;
    }

    uint64_t requested_ops = mbench_requested_ops(runtime, (uint64_t)mbench_random_ops_count(slice_bytes));
    size_t ops = 0;
    int rc = mbench_u64_to_size(requested_ops, &ops);
    if (rc != 0) {
        return rc;
    }

    memset(job, 0, sizeof(*job));
    job->data = (uint64_t *)base;
    job->data_words = data_words;
    job->page_words = page_words;
    job->hot_pages = hot_pages;
    job->hot_prob_pct = runtime->config.hotset.hot_prob_pct;
    job->read_pct = runtime->config.hotset.read_pct;
    job->write_pct = runtime->config.hotset.write_pct;
    job->rmw_pct = runtime->config.hotset.rmw_pct;
    job->index_mode = runtime->config.hotset.index_mode == MBENCH_HOTSET_INDEX_MULSHIFT
        ? MBENCH_SKEW_INDEX_MULSHIFT
        : MBENCH_SKEW_INDEX_XORSHIFT;
    job->ops = ops;
    job->seed = seed;
    job->sink = NULL;
    return 0;
}

static int mbench_build_irregular_job_slice(const struct mbench_runtime *runtime,
                                            struct mbench_irregular_job *job,
                                            unsigned char *base,
                                            size_t slice_bytes,
                                            uint64_t seed)
{
    if (!runtime || !job || !base) {
        return -EINVAL;
    }

    size_t data_words = slice_bytes / sizeof(uint64_t);
    if (data_words == 0) {
        return -EINVAL;
    }

    enum mbench_index_kind kind;
    enum mbench_index_dist_kind dist_kind;
    switch (runtime->config.irregular.kernel) {
    case MBENCH_INDEX_GATHER:
        kind = MBENCH_INDEX_KIND_GATHER;
        break;
    case MBENCH_INDEX_SCATTER:
        kind = MBENCH_INDEX_KIND_SCATTER;
        break;
    case MBENCH_INDEX_RMW:
        kind = MBENCH_INDEX_KIND_RMW;
        break;
    default:
        return -EINVAL;
    }

    switch (runtime->config.irregular.distribution) {
    case MBENCH_INDEX_DIST_UNIFORM:
        dist_kind = MBENCH_INDEX_DIST_KIND_UNIFORM;
        break;
    case MBENCH_INDEX_DIST_ZIPF:
        dist_kind = MBENCH_INDEX_DIST_KIND_ZIPF;
        break;
    case MBENCH_INDEX_DIST_CLUSTERED:
        dist_kind = MBENCH_INDEX_DIST_KIND_CLUSTERED;
        break;
    case MBENCH_INDEX_DIST_SEGMENTED:
        dist_kind = MBENCH_INDEX_DIST_KIND_SEGMENTED;
        break;
    default:
        return -EINVAL;
    }

    uint64_t requested_ops = mbench_requested_ops(runtime, (uint64_t)mbench_random_ops_count(slice_bytes));
    size_t ops = 0;
    int rc = mbench_u64_to_size(requested_ops, &ops);
    if (rc != 0) {
        return rc;
    }

    memset(job, 0, sizeof(*job));
    job->kind = kind;
    job->dist_kind = dist_kind;
    job->data = (uint64_t *)base;
    job->data_words = data_words;
    job->cluster_words = runtime->config.irregular.cluster_bytes / sizeof(uint64_t);
    if (job->cluster_words == 0) {
        job->cluster_words = 1U;
    }
    if (job->cluster_words > data_words) {
        job->cluster_words = data_words;
    }
    job->cluster_span_ops = runtime->config.irregular.cluster_span_ops;
    job->segment_count = runtime->config.irregular.segment_count;
    if (job->segment_count == 0) {
        job->segment_count = 1U;
    }
    if (job->segment_count > data_words) {
        job->segment_count = data_words;
    }
    job->segment_span_ops = runtime->config.irregular.segment_span_ops;
    job->zipf_alpha = runtime->config.irregular.zipf_alpha;
    job->ops = ops;
    job->seed = seed;
    job->sink = NULL;
    return mbench_prepare_zipf_state(job);
}

static uint64_t mbench_bw_job_ops(const struct mbench_bw_job *job)
{
    return (uint64_t)job->ops_per_pass * (uint64_t)job->passes;
}

static uint64_t mbench_bw_job_bytes(const struct mbench_bw_job *job)
{
    uint64_t ops = mbench_bw_job_ops(job);
    switch (job->kind) {
    case MBENCH_BW_READ:
    case MBENCH_BW_WRITE:
        return ops * sizeof(double);
    case MBENCH_BW_COPY:
        return ops * 2U * sizeof(double);
    case MBENCH_BW_TRIAD:
        return ops * 3U * sizeof(double);
    default:
        return 0;
    }
}

static uint64_t mbench_pc_job_ops(const struct mbench_pc_job *job)
{
    return (uint64_t)job->passes * (uint64_t)job->chains;
}

static uint64_t mbench_pc_job_bytes(const struct mbench_pc_job *job)
{
    return mbench_pc_job_ops(job) * 64U;
}

static uint64_t mbench_skew_job_ops(const struct mbench_skew_job *job)
{
    return (uint64_t)job->ops;
}

static uint64_t mbench_skew_job_bytes(const struct mbench_skew_job *job)
{
    uint64_t per_op = ((uint64_t)job->read_pct * 64U) +
        ((uint64_t)job->write_pct * 64U) +
        ((uint64_t)job->rmw_pct * 128U);
    return (mbench_skew_job_ops(job) * per_op) / 100U;
}

static uint64_t mbench_irregular_job_ops(const struct mbench_irregular_job *job)
{
    return (uint64_t)job->ops;
}

static uint64_t mbench_irregular_job_bytes(const struct mbench_irregular_job *job)
{
    switch (job->kind) {
    case MBENCH_INDEX_KIND_GATHER:
    case MBENCH_INDEX_KIND_SCATTER:
        return mbench_irregular_job_ops(job) * 64U;
    case MBENCH_INDEX_KIND_RMW:
        return mbench_irregular_job_ops(job) * 128U;
    default:
        return 0;
    }
}

struct mbench_persistent_worker_ctx {
    struct mbench_runtime *runtime;
    enum mbench_mix_role role;
    size_t role_index;
    size_t role_count;
    size_t region_offset_bytes;
    size_t region_bytes;
    int rc;
};

static void mbench_free_worker_job(struct mbench_mix_worker *worker)
{
    if (worker && worker->role == MBENCH_MIX_ROLE_IRREGULAR) {
        free(worker->job.irregular.zipf_cdf);
        worker->job.irregular.zipf_cdf = NULL;
    }
}

static int mbench_run_worker_job(struct mbench_mix_worker *worker)
{
    switch (worker->role) {
    case MBENCH_MIX_ROLE_PC:
        return mbench_run_pc(&worker->job.pc);
    case MBENCH_MIX_ROLE_BW:
        return mbench_run_bw(&worker->job.bw);
    case MBENCH_MIX_ROLE_SKEWED:
        return mbench_run_skewed_hotset(&worker->job.skew);
    case MBENCH_MIX_ROLE_IRREGULAR:
        return mbench_run_irregular(&worker->job.irregular);
    default:
        return -EINVAL;
    }
}

static void mbench_account_worker(struct mbench_runtime *runtime,
                                  const struct mbench_mix_worker *worker)
{
    switch (worker->role) {
    case MBENCH_MIX_ROLE_PC:
        atomic_fetch_add_explicit(&runtime->completed_ops,
                                  mbench_pc_job_ops(&worker->job.pc),
                                  memory_order_relaxed);
        atomic_fetch_add_explicit(&runtime->completed_bytes,
                                  mbench_pc_job_bytes(&worker->job.pc),
                                  memory_order_relaxed);
        break;
    case MBENCH_MIX_ROLE_BW:
        atomic_fetch_add_explicit(&runtime->completed_ops,
                                  mbench_bw_job_ops(&worker->job.bw),
                                  memory_order_relaxed);
        atomic_fetch_add_explicit(&runtime->completed_bytes,
                                  mbench_bw_job_bytes(&worker->job.bw),
                                  memory_order_relaxed);
        break;
    case MBENCH_MIX_ROLE_SKEWED:
        atomic_fetch_add_explicit(&runtime->completed_ops,
                                  mbench_skew_job_ops(&worker->job.skew),
                                  memory_order_relaxed);
        atomic_fetch_add_explicit(&runtime->completed_bytes,
                                  mbench_skew_job_bytes(&worker->job.skew),
                                  memory_order_relaxed);
        break;
    case MBENCH_MIX_ROLE_IRREGULAR:
        atomic_fetch_add_explicit(&runtime->completed_ops,
                                  mbench_irregular_job_ops(&worker->job.irregular),
                                  memory_order_relaxed);
        atomic_fetch_add_explicit(&runtime->completed_bytes,
                                  mbench_irregular_job_bytes(&worker->job.irregular),
                                  memory_order_relaxed);
        break;
    default:
        break;
    }
}

static int mbench_build_persistent_worker_job(struct mbench_persistent_worker_ctx *ctx,
                                              size_t window_offset,
                                              struct mbench_mix_worker *worker)
{
    struct mbench_runtime *runtime = ctx->runtime;
    size_t slice_bytes;
    unsigned char *base;
    uint64_t seed_base;

    if (!runtime || !worker || ctx->role_count == 0 ||
        ctx->role_index >= ctx->role_count ||
        ctx->region_offset_bytes > runtime->window.window_bytes ||
        ctx->region_bytes > runtime->window.window_bytes - ctx->region_offset_bytes) {
        return -EINVAL;
    }

    slice_bytes = mbench_slice_span(ctx->region_bytes, ctx->role_count);
    if (slice_bytes == 0) {
        return -EINVAL;
    }

    base = (unsigned char *)runtime->arena.base + window_offset +
        ctx->region_offset_bytes + ctx->role_index * slice_bytes;
    seed_base = runtime->config.seed ^ (uint64_t)window_offset;
    memset(worker, 0, sizeof(*worker));
    worker->role = ctx->role;

    switch (ctx->role) {
    case MBENCH_MIX_ROLE_PC:
        return mbench_build_pc_job_slice(runtime,
                                         &worker->job.pc,
                                         base,
                                         slice_bytes,
                                         seed_base + (uint64_t)(2U * ctx->role_index + 1U));
    case MBENCH_MIX_ROLE_BW:
        return mbench_build_bw_job_slice(runtime, &worker->job.bw, base, slice_bytes);
    case MBENCH_MIX_ROLE_SKEWED:
        return mbench_build_skew_job_slice(runtime,
                                           &worker->job.skew,
                                           base,
                                           slice_bytes,
                                           seed_base + (uint64_t)(2U * ctx->role_index + 1U));
    case MBENCH_MIX_ROLE_IRREGULAR:
        return mbench_build_irregular_job_slice(
            runtime,
            &worker->job.irregular,
            base,
            slice_bytes,
            (seed_base ^ 0x9e3779b97f4a7c15ULL) +
                (uint64_t)(2U * ctx->role_index + 1U));
    default:
        return -EINVAL;
    }
}

static void *mbench_persistent_worker_thread_main(void *arg)
{
    struct mbench_persistent_worker_ctx *ctx = arg;
    struct mbench_runtime *runtime = ctx->runtime;
    struct mbench_mix_worker worker;
    bool have_job = false;
    size_t built_offset = 0;
    int rc = 0;

    memset(&worker, 0, sizeof(worker));

    while (atomic_load_explicit(&runtime->stop_requested, memory_order_relaxed) == 0) {
        size_t window_offset = atomic_load_explicit(&runtime->window.current_offset,
                                                    memory_order_relaxed);

        if (!have_job || built_offset != window_offset) {
            if (have_job) {
                mbench_free_worker_job(&worker);
                have_job = false;
            }
            rc = mbench_build_persistent_worker_job(ctx, window_offset, &worker);
            if (rc != 0) {
                break;
            }
            built_offset = window_offset;
            have_job = true;
        }

        rc = mbench_run_worker_job(&worker);
        if (rc != 0) {
            break;
        }

        mbench_account_worker(runtime, &worker);

        if (runtime->config.request.pause_ns > 0 &&
            atomic_load_explicit(&runtime->stop_requested, memory_order_relaxed) == 0) {
            mbench_sleep_ns(runtime->config.request.pause_ns);
        }
    }

    if (have_job) {
        mbench_free_worker_job(&worker);
    }
    ctx->rc = rc;
    return NULL;
}

static size_t mbench_count_or_one(int configured_count)
{
    return configured_count > 0 ? (size_t)configured_count : 1U;
}

static int mbench_persistent_worker_count(const struct mbench_runtime *runtime,
                                          size_t *worker_count_out)
{
    size_t pc_workers;
    size_t bw_workers;

    if (!runtime || !worker_count_out) {
        return -EINVAL;
    }

    switch (runtime->config.mode) {
    case MBENCH_MODE_PC:
        *worker_count_out = mbench_count_or_one(runtime->config.threads.pc_threads);
        return 0;
    case MBENCH_MODE_BW:
        *worker_count_out = mbench_count_or_one(runtime->config.threads.bw_threads);
        return 0;
    case MBENCH_MODE_SKEWED_HOTSET:
    case MBENCH_MODE_IRREGULAR_INDEX:
        *worker_count_out = mbench_count_or_one(runtime->config.threads.total_threads);
        return 0;
    case MBENCH_MODE_MIX:
        pc_workers = runtime->config.threads.pc_threads > 0
            ? (size_t)runtime->config.threads.pc_threads
            : 0U;
        bw_workers = runtime->config.threads.bw_threads > 0
            ? (size_t)runtime->config.threads.bw_threads
            : 0U;
        if (pc_workers + bw_workers == 0) {
            return -EINVAL;
        }
        *worker_count_out = pc_workers + bw_workers;
        return 0;
    default:
        return -EINVAL;
    }
}

static int mbench_init_persistent_contexts(struct mbench_runtime *runtime,
                                           struct mbench_persistent_worker_ctx *ctxs,
                                           size_t worker_count)
{
    size_t pc_workers;
    size_t bw_workers;
    size_t pc_region_bytes;
    size_t bw_region_bytes;
    size_t idx = 0;

    if (!runtime || !ctxs || worker_count == 0) {
        return -EINVAL;
    }

    switch (runtime->config.mode) {
    case MBENCH_MODE_PC:
        for (size_t i = 0; i < worker_count; ++i) {
            ctxs[i].runtime = runtime;
            ctxs[i].role = MBENCH_MIX_ROLE_PC;
            ctxs[i].role_index = i;
            ctxs[i].role_count = worker_count;
            ctxs[i].region_offset_bytes = 0;
            ctxs[i].region_bytes = runtime->window.window_bytes;
        }
        return 0;
    case MBENCH_MODE_BW:
        for (size_t i = 0; i < worker_count; ++i) {
            ctxs[i].runtime = runtime;
            ctxs[i].role = MBENCH_MIX_ROLE_BW;
            ctxs[i].role_index = runtime->config.bw_pattern.shared_window ? 0 : i;
            ctxs[i].role_count = runtime->config.bw_pattern.shared_window ? 1 : worker_count;
            ctxs[i].region_offset_bytes = 0;
            ctxs[i].region_bytes = runtime->window.window_bytes;
        }
        return 0;
    case MBENCH_MODE_SKEWED_HOTSET:
        for (size_t i = 0; i < worker_count; ++i) {
            ctxs[i].runtime = runtime;
            ctxs[i].role = MBENCH_MIX_ROLE_SKEWED;
            ctxs[i].role_index = i;
            ctxs[i].role_count = worker_count;
            ctxs[i].region_offset_bytes = 0;
            ctxs[i].region_bytes = runtime->window.window_bytes;
        }
        return 0;
    case MBENCH_MODE_IRREGULAR_INDEX:
        for (size_t i = 0; i < worker_count; ++i) {
            ctxs[i].runtime = runtime;
            ctxs[i].role = MBENCH_MIX_ROLE_IRREGULAR;
            ctxs[i].role_index = i;
            ctxs[i].role_count = worker_count;
            ctxs[i].region_offset_bytes = 0;
            ctxs[i].region_bytes = runtime->window.window_bytes;
        }
        return 0;
    case MBENCH_MODE_MIX:
        pc_workers = runtime->config.threads.pc_threads > 0
            ? (size_t)runtime->config.threads.pc_threads
            : 0U;
        bw_workers = runtime->config.threads.bw_threads > 0
            ? (size_t)runtime->config.threads.bw_threads
            : 0U;
        pc_region_bytes = (runtime->window.window_bytes * pc_workers) / worker_count;
        if (pc_region_bytes > runtime->window.window_bytes) {
            pc_region_bytes = runtime->window.window_bytes;
        }
        bw_region_bytes = runtime->window.window_bytes - pc_region_bytes;

        for (size_t i = 0; i < pc_workers; ++i, ++idx) {
            ctxs[idx].runtime = runtime;
            ctxs[idx].role = MBENCH_MIX_ROLE_PC;
            ctxs[idx].role_index = i;
            ctxs[idx].role_count = pc_workers;
            ctxs[idx].region_offset_bytes = 0;
            ctxs[idx].region_bytes = pc_region_bytes;
        }
        for (size_t i = 0; i < bw_workers; ++i, ++idx) {
            ctxs[idx].runtime = runtime;
            ctxs[idx].role = MBENCH_MIX_ROLE_BW;
            ctxs[idx].role_index = i;
            ctxs[idx].role_count = bw_workers;
            ctxs[idx].region_offset_bytes = pc_region_bytes;
            ctxs[idx].region_bytes = bw_region_bytes;
        }
        return idx == worker_count ? 0 : -EINVAL;
    default:
        return -EINVAL;
    }
}

static int mbench_execute_persistent(struct mbench_runtime *runtime)
{
    size_t worker_count = 0;
    pthread_t *threads;
    struct mbench_persistent_worker_ctx *ctxs;
    int rc;
    size_t started = 0;

    rc = mbench_persistent_worker_count(runtime, &worker_count);
    if (rc != 0) {
        return rc;
    }

    threads = calloc(worker_count, sizeof(*threads));
    ctxs = calloc(worker_count, sizeof(*ctxs));
    if (!threads || !ctxs) {
        free(threads);
        free(ctxs);
        return -ENOMEM;
    }

    rc = mbench_init_persistent_contexts(runtime, ctxs, worker_count);
    if (rc != 0) {
        free(ctxs);
        free(threads);
        return rc;
    }

    for (size_t i = 0; i < worker_count; ++i) {
        int err = pthread_create(&threads[i], NULL,
                                 mbench_persistent_worker_thread_main, &ctxs[i]);
        if (err != 0) {
            rc = -err;
            atomic_store_explicit(&runtime->stop_requested, 1, memory_order_relaxed);
            break;
        }
        started++;
    }

    for (size_t i = 0; i < started; ++i) {
        int err = pthread_join(threads[i], NULL);
        if (rc == 0 && err != 0) {
            rc = -err;
        }
        if (rc == 0 && ctxs[i].rc != 0) {
            rc = ctxs[i].rc;
        }
    }

    free(ctxs);
    free(threads);
    return rc;
}

int mbench_execute_bw(struct mbench_runtime *runtime)
{
    return mbench_execute_persistent(runtime);
}

int mbench_execute_pc(struct mbench_runtime *runtime)
{
    return mbench_execute_persistent(runtime);
}

int mbench_execute_mix(struct mbench_runtime *runtime)
{
    return mbench_execute_persistent(runtime);
}

int mbench_execute_skewed_hotset(struct mbench_runtime *runtime)
{
    return mbench_execute_persistent(runtime);
}

int mbench_execute_irregular_index(struct mbench_runtime *runtime)
{
    return mbench_execute_persistent(runtime);
}
