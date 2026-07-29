#define _GNU_SOURCE

#include "mbench_kernels.h"

#include <errno.h>
#include <limits.h>

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

static inline int mbench_is_power_of_two_size(size_t value)
{
    return value != 0 && (value & (value - 1U)) == 0;
}

static inline unsigned mbench_ctz_size(size_t value)
{
    return (unsigned)__builtin_ctzll((unsigned long long)value);
}

static inline size_t mbench_high_bits_index(uint64_t state, unsigned bits)
{
    if (bits == 0) {
        return 0;
    }
    if (bits >= 64U) {
        return (size_t)state;
    }
    return (size_t)(state >> (64U - bits));
}

static int mbench_run_skewed_hotset_mulshift(struct mbench_skew_job *job)
{
    size_t hot_page_bits = mbench_ctz_size(job->hot_pages);
    size_t page_word_bits = mbench_ctz_size(job->page_words);

    if (hot_page_bits > UINT_MAX - page_word_bits) {
        return -EINVAL;
    }

    unsigned hot_word_bits = (unsigned)(hot_page_bits + page_word_bits);
    if (hot_word_bits >= sizeof(size_t) * CHAR_BIT &&
        (sizeof(size_t) * CHAR_BIT) < 64U) {
        return -EINVAL;
    }

    const uint64_t stride = 0x9e3779b97f4a7c15ULL;
    uint64_t state = job->state_initialized ?
        job->state : (job->seed ? job->seed : 0x6a09e667f3bcc909ULL) * stride;
    uint64_t checksum = 0;

    for (size_t op = 0; op < job->ops; ++op) {
        state += stride;
        size_t slot = mbench_high_bits_index(state, hot_word_bits);
        checksum += job->data[slot] + (uint64_t)slot;
    }

    job->state = state;
    job->state_initialized = 1;
    if (job->sink) {
        *job->sink = checksum;
    }
    return 0;
}

int mbench_run_skewed_hotset(struct mbench_skew_job *job)
{
    if (!job || !job->data || job->data_words == 0 || job->page_words == 0 ||
        job->hot_pages == 0 || job->ops == 0 || job->hot_prob_pct > 100U ||
        job->read_pct + job->write_pct + job->rmw_pct != 100U) {
        return -EINVAL;
    }

    size_t total_pages = job->data_words / job->page_words;
    if (total_pages == 0 || job->hot_pages > total_pages) {
        return -EINVAL;
    }

    size_t cold_pages = total_pages - job->hot_pages;
    if (job->background_pages > 0 &&
        (!job->hotset_tail || job->background_pages > cold_pages)) {
        return -EINVAL;
    }
    size_t selectable_cold_pages = job->background_pages > 0
        ? job->background_pages
        : cold_pages;
    if (job->index_mode == MBENCH_SKEW_INDEX_MULSHIFT &&
        cold_pages == 0 &&
        job->hot_prob_pct == 100U &&
        job->read_pct == 100U &&
        job->write_pct == 0U &&
        job->rmw_pct == 0U &&
        mbench_is_power_of_two_size(job->hot_pages) &&
        mbench_is_power_of_two_size(job->page_words)) {
        return mbench_run_skewed_hotset_mulshift(job);
    }

    uint64_t state = job->state_initialized ?
        job->state : (job->seed ? job->seed : 0x6a09e667f3bcc909ULL);
    uint64_t checksum = 0;

    for (size_t op = 0; op < job->ops; ++op) {
        uint64_t choose = mbench_xorshift64(&state);
        uint64_t value = mbench_xorshift64(&state);
        size_t page;
        if (cold_pages == 0 || (choose % 100ULL) < (uint64_t)job->hot_prob_pct) {
            size_t hot_index =
                (size_t)(mbench_xorshift64(&state) % (uint64_t)job->hot_pages);
            page = job->hotset_tail ? cold_pages + hot_index : hot_index;
        } else {
            size_t cold_index =
                (size_t)(mbench_xorshift64(&state) %
                         (uint64_t)selectable_cold_pages);
            page = job->hotset_tail ? cold_index : job->hot_pages + cold_index;
        }

        size_t word = (size_t)(mbench_xorshift64(&state) % (uint64_t)job->page_words);
        size_t slot = page * job->page_words + word;
        uint64_t op_kind = choose % 100ULL;
        if (op_kind < (uint64_t)job->read_pct) {
            checksum += job->data[slot] + (uint64_t)slot;
        } else if (op_kind < (uint64_t)job->read_pct + (uint64_t)job->write_pct) {
            job->data[slot] = value;
            checksum += value ^ (uint64_t)slot;
        } else {
            job->data[slot] ^= value;
            checksum += job->data[slot];
        }
    }

    job->state = state;
    job->state_initialized = 1;
    if (job->sink) {
        *job->sink = checksum;
    }
    return 0;
}
