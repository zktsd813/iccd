#define _GNU_SOURCE

#include "mbench_kernels.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

static inline uint64_t mbench_xorshift64(uint64_t *state)
{
    uint64_t x = *state;

    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    *state = x;
    return x * 2685821657736338717ULL;
}

int mbench_init_pc_ring(uint32_t *ring, size_t nodes, uint64_t seed)
{
    if (ring == NULL || nodes < 2 || nodes > UINT32_MAX) {
        return -EINVAL;
    }
    if (nodes > SIZE_MAX / sizeof(*ring)) {
        return -EOVERFLOW;
    }

    uint32_t *perm = malloc(nodes * sizeof(*perm));
    if (perm == NULL) {
        return -ENOMEM;
    }

    for (size_t i = 0; i < nodes; ++i) {
        perm[i] = (uint32_t)i;
    }

    uint64_t state = seed != 0 ? seed : 0x9e3779b97f4a7c15ULL;
    for (size_t i = nodes - 1; i > 0; --i) {
        size_t j = (size_t)(mbench_xorshift64(&state) % (uint64_t)(i + 1));
        uint32_t tmp = perm[i];
        perm[i] = perm[j];
        perm[j] = tmp;
    }

    for (size_t i = 0; i + 1 < nodes; ++i) {
        ring[perm[i]] = perm[i + 1];
    }
    ring[perm[nodes - 1]] = perm[0];

    free(perm);
    return 0;
}

int mbench_init_pc_ring64(uint64_t *ring, size_t nodes, uint64_t seed)
{
    if (ring == NULL || nodes < 2) {
        return -EINVAL;
    }
    if (nodes > SIZE_MAX / sizeof(*ring)) {
        return -EOVERFLOW;
    }

    uint64_t *perm = malloc(nodes * sizeof(*perm));
    if (perm == NULL) {
        return -ENOMEM;
    }

    for (size_t i = 0; i < nodes; ++i) {
        perm[i] = (uint64_t)i;
    }

    uint64_t state = seed != 0 ? seed : 0x9e3779b97f4a7c15ULL;
    for (size_t i = nodes - 1; i > 0; --i) {
        size_t j = (size_t)(mbench_xorshift64(&state) % (uint64_t)(i + 1));
        uint64_t tmp = perm[i];
        perm[i] = perm[j];
        perm[j] = tmp;
    }

    for (size_t i = 0; i + 1 < nodes; ++i) {
        ring[perm[i]] = perm[i + 1];
    }
    ring[perm[nodes - 1]] = perm[0];

    free(perm);
    return 0;
}

static size_t mbench_gcd_size(size_t a, size_t b)
{
    while (b != 0) {
        size_t t = a % b;
        a = b;
        b = t;
    }
    return a;
}

int mbench_init_pc_ring_stride(uint32_t *ring, size_t nodes, uint64_t seed)
{
    if (ring == NULL || nodes < 2 || nodes > UINT32_MAX) {
        return -EINVAL;
    }

    size_t stride = (size_t)((seed % (uint64_t)(nodes - 1U)) + 1U);
    if ((stride & 1U) == 0) {
        stride++;
    }
    if (stride >= nodes) {
        stride = 1U;
    }
    while (mbench_gcd_size(stride, nodes) != 1U) {
        stride += 2U;
        if (stride >= nodes) {
            stride = 1U;
        }
    }

    for (size_t i = 0; i < nodes; ++i) {
        ring[i] = (uint32_t)((i + stride) % nodes);
    }

    return 0;
}

int mbench_init_pc_ring64_stride(uint64_t *ring, size_t nodes, uint64_t seed)
{
    if (ring == NULL || nodes < 2) {
        return -EINVAL;
    }

    size_t stride = (size_t)((seed % (uint64_t)(nodes - 1U)) + 1U);
    if ((stride & 1U) == 0) {
        stride++;
    }
    if (stride >= nodes) {
        stride = 1U;
    }
    while (mbench_gcd_size(stride, nodes) != 1U) {
        stride += 2U;
        if (stride >= nodes) {
            stride = 1U;
        }
    }

    for (size_t i = 0; i < nodes; ++i) {
        ring[i] = (uint64_t)((i + stride) % nodes);
    }

    return 0;
}

int mbench_init_pc_heads(uint32_t *heads, size_t chains, size_t nodes, uint64_t seed)
{
    if (heads == NULL || chains == 0 || nodes == 0 || nodes > UINT32_MAX) {
        return -EINVAL;
    }

    uint64_t state = seed != 0 ? seed : 0x6a09e667f3bcc909ULL;
    for (size_t chain = 0; chain < chains; ++chain) {
        uint64_t base = ((uint64_t)chain * (uint64_t)nodes) / (uint64_t)chains;
        uint64_t jitter = mbench_xorshift64(&state) % (uint64_t)nodes;
        heads[chain] = (uint32_t)((base + jitter) % (uint64_t)nodes);
    }

    return 0;
}

int mbench_init_pc_heads64(uint64_t *heads, size_t chains, size_t nodes, uint64_t seed)
{
    if (heads == NULL || chains == 0 || nodes == 0) {
        return -EINVAL;
    }

    uint64_t state = seed != 0 ? seed : 0x6a09e667f3bcc909ULL;
    for (size_t chain = 0; chain < chains; ++chain) {
        uint64_t base = ((uint64_t)chain * (uint64_t)nodes) / (uint64_t)chains;
        uint64_t jitter = mbench_xorshift64(&state) % (uint64_t)nodes;
        heads[chain] = (base + jitter) % (uint64_t)nodes;
    }

    return 0;
}

int mbench_run_pc(const struct mbench_pc_job *job)
{
    if (job == NULL || job->ring == NULL || job->heads == NULL ||
        job->nodes < 2 || job->chains == 0 || job->passes == 0) {
        return -EINVAL;
    }

    uint64_t checksum = 0;

    for (size_t pass = 0; pass < job->passes; ++pass) {
        for (size_t chain = 0; chain < job->chains; ++chain) {
            if (job->index_width == MBENCH_PC_INDEX_U32) {
                uint32_t *ring = job->ring;
                uint32_t *heads = job->heads;
                uint32_t idx = heads[chain];
                idx = ring[idx];
                heads[chain] = idx;
                checksum += (uint64_t)idx + 1ULL;
            } else if (job->index_width == MBENCH_PC_INDEX_U64) {
                uint64_t *ring = job->ring;
                uint64_t *heads = job->heads;
                uint64_t idx = heads[chain];
                idx = ring[idx];
                heads[chain] = idx;
                checksum += idx + 1ULL;
            } else {
                return -EINVAL;
            }
        }
    }

    if (job->sink != NULL) {
        *job->sink = checksum;
    }

    return 0;
}
