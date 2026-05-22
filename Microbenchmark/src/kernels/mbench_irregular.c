#define _GNU_SOURCE

#include "mbench_kernels.h"

#include <errno.h>

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

static size_t mbench_binary_search_cdf(const long double *cdf,
                                       size_t count,
                                       long double target)
{
    size_t lo = 0;
    size_t hi = count;

    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2U;
        if (cdf[mid] < target) {
            lo = mid + 1U;
        } else {
            hi = mid;
        }
    }
    return (lo < count) ? lo : (count - 1U);
}

static size_t mbench_select_irregular_index(const struct mbench_irregular_job *job,
                                            uint64_t *state,
                                            size_t op,
                                            size_t *cluster_base,
                                            size_t segment_start)
{
    switch (job->dist_kind) {
    case MBENCH_INDEX_DIST_KIND_UNIFORM:
        return (size_t)(mbench_xorshift64(state) % (uint64_t)job->data_words);
    case MBENCH_INDEX_DIST_KIND_ZIPF: {
        long double target = ((long double)mbench_xorshift64(state) + 1.0L) /
            ((long double)UINT64_MAX + 1.0L);
        size_t bucket = mbench_binary_search_cdf(job->zipf_cdf, job->zipf_bucket_count, target);
        size_t bucket_start = bucket * job->zipf_bucket_words;
        size_t bucket_words = job->zipf_bucket_words;
        if (bucket_start >= job->data_words) {
            return job->data_words - 1U;
        }
        if (bucket_start + bucket_words > job->data_words) {
            bucket_words = job->data_words - bucket_start;
        }
        return bucket_start + (size_t)(mbench_xorshift64(state) % (uint64_t)bucket_words);
    }
    case MBENCH_INDEX_DIST_KIND_CLUSTERED: {
        if (job->cluster_words >= job->data_words) {
            return (size_t)(mbench_xorshift64(state) % (uint64_t)job->data_words);
        }
        if (op == 0 || (job->cluster_span_ops > 0 && (uint64_t)op % job->cluster_span_ops == 0)) {
            *cluster_base = (size_t)(mbench_xorshift64(state) %
                                     (uint64_t)(job->data_words - job->cluster_words + 1U));
        }
        return *cluster_base + (size_t)(mbench_xorshift64(state) % (uint64_t)job->cluster_words);
    }
    case MBENCH_INDEX_DIST_KIND_SEGMENTED: {
        size_t segment_width = (job->data_words + job->segment_count - 1U) / job->segment_count;
        size_t start = segment_start * segment_width;
        size_t width = segment_width;
        if (start >= job->data_words) {
            start = job->data_words - 1U;
            width = 1U;
        } else if (start + width > job->data_words) {
            width = job->data_words - start;
        }
        return start + (size_t)(mbench_xorshift64(state) % (uint64_t)width);
    }
    default:
        return 0;
    }
}

int mbench_run_irregular(const struct mbench_irregular_job *job)
{
    if (!job || !job->data || job->data_words == 0 || job->ops == 0) {
        return -EINVAL;
    }
    if (job->dist_kind == MBENCH_INDEX_DIST_KIND_ZIPF &&
        (!job->zipf_cdf || job->zipf_bucket_count == 0 || job->zipf_bucket_words == 0 ||
         job->zipf_alpha <= 0.0)) {
        return -EINVAL;
    }
    if (job->dist_kind == MBENCH_INDEX_DIST_KIND_CLUSTERED &&
        (job->cluster_words == 0 || job->cluster_span_ops == 0)) {
        return -EINVAL;
    }
    if (job->dist_kind == MBENCH_INDEX_DIST_KIND_SEGMENTED &&
        (job->segment_count == 0 || job->segment_span_ops == 0)) {
        return -EINVAL;
    }

    uint64_t state = job->seed ? job->seed : 0xbb67ae8584caa73bULL;
    uint64_t checksum = 0;
    size_t cluster_base = 0;
    size_t segment_cursor = (size_t)(mbench_xorshift64(&state) % (uint64_t)((job->segment_count == 0)
        ? 1U
        : job->segment_count));

    for (size_t op = 0; op < job->ops; ++op) {
        if (job->dist_kind == MBENCH_INDEX_DIST_KIND_SEGMENTED &&
            job->segment_span_ops > 0 && op > 0 &&
            (uint64_t)op % job->segment_span_ops == 0) {
            segment_cursor = (segment_cursor + 1U) % job->segment_count;
        }
        size_t idx = mbench_select_irregular_index(job,
                                                   &state,
                                                   op,
                                                   &cluster_base,
                                                   segment_cursor);
        uint64_t value = mbench_xorshift64(&state);

        switch (job->kind) {
        case MBENCH_INDEX_KIND_GATHER:
            checksum += job->data[idx];
            break;
        case MBENCH_INDEX_KIND_SCATTER:
            job->data[idx] = value;
            checksum += value ^ (uint64_t)idx;
            break;
        case MBENCH_INDEX_KIND_RMW:
            job->data[idx] ^= value;
            checksum += job->data[idx];
            break;
        default:
            return -EINVAL;
        }
    }

    if (job->sink) {
        *job->sink = checksum;
    }
    return 0;
}
