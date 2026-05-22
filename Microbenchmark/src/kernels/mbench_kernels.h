#ifndef MBENCH_KERNELS_H
#define MBENCH_KERNELS_H

#include <stddef.h>
#include <stdint.h>
#include <pthread.h>

enum mbench_isa {
    MBENCH_ISA_SCALAR = 0,
    MBENCH_ISA_AVX2 = 1,
    MBENCH_ISA_AVX512 = 2,
};

enum mbench_bw_kind {
    MBENCH_BW_READ = 0,
    MBENCH_BW_WRITE = 1,
    MBENCH_BW_COPY = 2,
    MBENCH_BW_TRIAD = 3,
};

enum mbench_index_kind {
    MBENCH_INDEX_KIND_GATHER = 0,
    MBENCH_INDEX_KIND_SCATTER = 1,
    MBENCH_INDEX_KIND_RMW = 2,
};

enum mbench_index_dist_kind {
    MBENCH_INDEX_DIST_KIND_UNIFORM = 0,
    MBENCH_INDEX_DIST_KIND_ZIPF = 1,
    MBENCH_INDEX_DIST_KIND_CLUSTERED = 2,
    MBENCH_INDEX_DIST_KIND_SEGMENTED = 3,
};

enum mbench_skew_index_mode {
    MBENCH_SKEW_INDEX_XORSHIFT = 0,
    MBENCH_SKEW_INDEX_MULSHIFT = 1,
};

enum mbench_mix_role {
    MBENCH_MIX_ROLE_PC = 0,
    MBENCH_MIX_ROLE_BW = 1,
    MBENCH_MIX_ROLE_SKEWED = 2,
    MBENCH_MIX_ROLE_IRREGULAR = 3,
};

struct mbench_bw_job {
    enum mbench_bw_kind kind;
    double *dst;
    const double *src1;
    const double *src2;
    size_t elements;
    size_t block_elements;
    size_t stride_elements;
    size_t ops_per_pass;
    size_t passes;
    double triad_scalar;
    volatile double *sink;
};

struct mbench_pc_job {
    uint32_t *ring;
    uint32_t *heads;
    size_t nodes;
    size_t chains;
    size_t passes;
    volatile uint64_t *sink;
};

struct mbench_skew_job {
    uint64_t *data;
    size_t data_words;
    size_t page_words;
    size_t hot_pages;
    uint32_t hot_prob_pct;
    uint32_t read_pct;
    uint32_t write_pct;
    uint32_t rmw_pct;
    enum mbench_skew_index_mode index_mode;
    size_t ops;
    uint64_t seed;
    uint64_t state;
    int state_initialized;
    volatile uint64_t *sink;
};

struct mbench_irregular_job {
    enum mbench_index_kind kind;
    enum mbench_index_dist_kind dist_kind;
    uint64_t *data;
    size_t data_words;
    size_t cluster_words;
    uint64_t cluster_span_ops;
    size_t segment_count;
    uint64_t segment_span_ops;
    double zipf_alpha;
    long double *zipf_cdf;
    size_t zipf_bucket_count;
    size_t zipf_bucket_words;
    size_t ops;
    uint64_t seed;
    volatile uint64_t *sink;
};

struct mbench_mix_worker {
    enum mbench_mix_role role;
    union {
        struct mbench_bw_job bw;
        struct mbench_pc_job pc;
        struct mbench_skew_job skew;
        struct mbench_irregular_job irregular;
    } job;
};

enum mbench_isa mbench_detect_isa(void);

int mbench_run_bw(const struct mbench_bw_job *job);

int mbench_init_pc_ring(uint32_t *ring, size_t nodes, uint64_t seed);
int mbench_init_pc_ring_stride(uint32_t *ring, size_t nodes, uint64_t seed);
int mbench_init_pc_heads(uint32_t *heads, size_t chains, size_t nodes, uint64_t seed);
int mbench_run_pc(const struct mbench_pc_job *job);
int mbench_run_skewed_hotset(struct mbench_skew_job *job);
int mbench_run_irregular(const struct mbench_irregular_job *job);

/*
 * Compatibility aliases for code that adopted the initial kernel-local names
 * before the runner-facing API was finalized.
 */
static inline enum mbench_isa mbench_detect_bw_isa(void)
{
    return mbench_detect_isa();
}

static inline int mbench_bw_run(const struct mbench_bw_job *job)
{
    return mbench_run_bw(job);
}

static inline int mbench_pc_build_ring(uint32_t *ring, size_t nodes, uint64_t seed)
{
    return mbench_init_pc_ring(ring, nodes, seed);
}

static inline int mbench_pc_seed_heads(uint32_t *heads, size_t chains, size_t nodes, uint64_t seed)
{
    return mbench_init_pc_heads(heads, chains, nodes, seed);
}

static inline int mbench_pc_run(const struct mbench_pc_job *job)
{
    return mbench_run_pc(job);
}

#endif
