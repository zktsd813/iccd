#ifndef MBENCH_H
#define MBENCH_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdatomic.h>
#include <pthread.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MBENCH_MAX_NUMA_NODES 16
#define MBENCH_PHASE_NAME_MAX 32

enum mbench_mode {
    MBENCH_MODE_PC = 0,
    MBENCH_MODE_BW = 1,
    MBENCH_MODE_MIX = 2,
    MBENCH_MODE_SKEWED_HOTSET = 3,
    MBENCH_MODE_IRREGULAR_INDEX = 4,
};

enum mbench_move_policy {
    MBENCH_MOVE_FIXED = 0,
    MBENCH_MOVE_PINGPONG = 1,
    MBENCH_MOVE_SWEEP = 2,
    MBENCH_MOVE_RANDOM = 3,
};

enum mbench_placement_kind {
    MBENCH_PLACEMENT_NONE = 0,
    MBENCH_PLACEMENT_BIND = 1,
    MBENCH_PLACEMENT_INTERLEAVE = 2,
    MBENCH_PLACEMENT_PREFERRED = 3,
    MBENCH_PLACEMENT_SPLIT = 4,
    MBENCH_PLACEMENT_WINDOW_SPLIT = 5,
};

enum mbench_bw_kernel {
    MBENCH_BW_READ = 0,
    MBENCH_BW_WRITE = 1,
    MBENCH_BW_COPY = 2,
    MBENCH_BW_TRIAD = 3,
};

enum mbench_index_kernel {
    MBENCH_INDEX_GATHER = 0,
    MBENCH_INDEX_SCATTER = 1,
    MBENCH_INDEX_RMW = 2,
};

enum mbench_index_distribution {
    MBENCH_INDEX_DIST_UNIFORM = 0,
    MBENCH_INDEX_DIST_ZIPF = 1,
    MBENCH_INDEX_DIST_CLUSTERED = 2,
    MBENCH_INDEX_DIST_SEGMENTED = 3,
};

enum mbench_hotset_index_mode {
    MBENCH_HOTSET_INDEX_XORSHIFT = 0,
    MBENCH_HOTSET_INDEX_MULSHIFT = 1,
};

enum mbench_pc_pattern {
    MBENCH_PC_PATTERN_RANDOM = 0,
    MBENCH_PC_PATTERN_STRIDE = 1,
};

enum mbench_hugepage_kind {
    MBENCH_HUGEPAGE_NONE = 0,
    MBENCH_HUGEPAGE_THP = 1,
    MBENCH_HUGEPAGE_HUGETLB_2M = 2,
    MBENCH_HUGEPAGE_HUGETLB_1G = 3,
};

enum mbench_phase_preset {
    MBENCH_PHASE_PRESET_NONE = 0,
    MBENCH_PHASE_PRESET_FRIENDLY_STREAM = 1,
    MBENCH_PHASE_PRESET_TAIL_HOTSET_SPARSE16 = 2,
    MBENCH_PHASE_PRESET_TAIL_HOTSET_SPARSE24 = 3,
    MBENCH_PHASE_PRESET_SPARSE24_TAIL_HOTSET = 4,
    MBENCH_PHASE_PRESET_SKEW4G_SPARSE64 = 5,
    MBENCH_PHASE_PRESET_MULSHIFT4G_SPARSE24 = 6,
    MBENCH_PHASE_PRESET_MULSHIFT4G_SPARSE64 = 7,
    MBENCH_PHASE_PRESET_MULSHIFT4G_ROT_SPARSE24 = 8,
    MBENCH_PHASE_PRESET_MULSHIFT4G_ROT_SPARSE64 = 9,
    MBENCH_PHASE_PRESET_MULSHIFT4G_ROT_MOVE16G3S = 10,
    MBENCH_PHASE_PRESET_MULSHIFT4G_BLOCK2M_SPARSE64 = 11,
    MBENCH_PHASE_PRESET_MOVE15S4G_SPLIT32 = 12,
    MBENCH_PHASE_PRESET_MOVE15S4G_REMOTE_SPLIT32 = 13,
    MBENCH_PHASE_PRESET_MOVE60S4G_REMOTE_SPLIT32 = 14,
    MBENCH_PHASE_PRESET_FIXED4G_REMOTE_SPLIT32 = 15,
    MBENCH_PHASE_PRESET_FIXED8G_REMOTE_SPLIT32 = 16,
};

struct mbench_node_list {
    int nodes[MBENCH_MAX_NUMA_NODES];
    size_t count;
};

struct mbench_timing_config {
    uint32_t duration_ms;
    uint32_t sample_ms;
    uint32_t move_interval_ms;
};

struct mbench_report_config {
    bool csv;
    bool quiet;
    bool emit_summary;
};

struct mbench_window_config {
    size_t arena_bytes;
    size_t window_bytes;
    size_t offset_bytes;
    size_t move_step_bytes;
    size_t move_min_offset_bytes;
    size_t move_max_offset_bytes;
    enum mbench_move_policy move_policy;
};

struct mbench_numa_config {
    enum mbench_placement_kind kind;
    struct mbench_node_list nodes;
    int local_node;
    int remote_node;
    size_t window_split_local_bytes;
    bool strict;
};

struct mbench_thread_config {
    int total_threads;
    int pc_threads;
    int bw_threads;
    int pc_chains;
    enum mbench_pc_pattern pc_pattern;
};

struct mbench_request_config {
    uint64_t ops_per_pass;
    uint64_t pause_ns;
};

struct mbench_bw_pattern_config {
    uint32_t stride_elements;
    size_t block_bytes;
    bool shared_window;
};

struct mbench_hotset_config {
    uint32_t hotset_pages;
    uint32_t hot_prob_pct;
    uint32_t read_pct;
    uint32_t write_pct;
    uint32_t rmw_pct;
    enum mbench_hotset_index_mode index_mode;
    int prefault_node;
};

struct mbench_irregular_config {
    enum mbench_index_kernel kernel;
    enum mbench_index_distribution distribution;
    double zipf_alpha;
    size_t cluster_bytes;
    uint32_t cluster_span_ops;
    uint32_t segment_count;
    uint32_t segment_span_ops;
};

struct mbench_phase_config {
    enum mbench_phase_preset preset;
    uint32_t repeat;
    uint32_t duration_ms;
};

struct mbench_config {
    enum mbench_mode mode;
    enum mbench_bw_kernel bw_kernel;
    enum mbench_hugepage_kind hugepage;
    bool prefault;
    uint64_t seed;
    struct mbench_timing_config timing;
    struct mbench_report_config report;
    struct mbench_window_config window;
    struct mbench_numa_config placement;
    struct mbench_thread_config threads;
    struct mbench_request_config request;
    struct mbench_bw_pattern_config bw_pattern;
    struct mbench_hotset_config hotset;
    struct mbench_irregular_config irregular;
    struct mbench_phase_config phase;
};

struct mbench_phase {
    uint32_t id;
    char name[MBENCH_PHASE_NAME_MAX];
    uint32_t duration_ms;
    struct mbench_config config;
};

struct mbench_arena {
    void *base;
    size_t bytes;
    size_t page_size;
    enum mbench_hugepage_kind hugepage;
    bool prefaulted;
};

struct mbench_window_state {
    size_t arena_bytes;
    size_t window_bytes;
    _Atomic size_t current_offset;
    size_t move_step_bytes;
    size_t move_min_offset_bytes;
    size_t move_max_offset_bytes;
    enum mbench_move_policy move_policy;
    int move_direction;
    uint64_t move_rng_state;
};

struct mbench_runtime {
    struct mbench_config config;
    struct mbench_arena arena;
    struct mbench_window_state window;
    _Atomic uint64_t completed_ops;
    _Atomic uint64_t completed_bytes;
    _Atomic int stop_requested;
    uint64_t sink;
    uint32_t phase_id;
    char phase_name[MBENCH_PHASE_NAME_MAX];
};

static inline size_t mbench_align_up_size(size_t value, size_t align)
{
    if (align == 0) {
        return value;
    }
    return (value + align - 1) / align * align;
}

static inline unsigned char *mbench_arena_ptr(const struct mbench_arena *arena)
{
    return (unsigned char *)arena->base;
}

static inline unsigned char *mbench_window_ptr(const struct mbench_arena *arena,
                                               const struct mbench_window_state *window)
{
    return (unsigned char *)arena->base + atomic_load_explicit(&window->current_offset,
                                                               memory_order_relaxed);
}

static inline size_t mbench_window_max_offset(const struct mbench_window_state *window)
{
    return (window->arena_bytes > window->window_bytes)
        ? (window->arena_bytes - window->window_bytes)
        : 0;
}

static inline unsigned char *mbench_runtime_window_ptr(const struct mbench_runtime *rt)
{
    return (unsigned char *)rt->arena.base +
        atomic_load_explicit(&rt->window.current_offset, memory_order_relaxed);
}

static inline size_t mbench_runtime_window_max_offset(const struct mbench_runtime *rt)
{
    return mbench_window_max_offset(&rt->window);
}

const char *mbench_mode_name(enum mbench_mode mode);
const char *mbench_move_policy_name(enum mbench_move_policy policy);
const char *mbench_placement_name(enum mbench_placement_kind kind);
const char *mbench_bw_kernel_name(enum mbench_bw_kernel kernel);
const char *mbench_index_kernel_name(enum mbench_index_kernel kernel);
const char *mbench_index_distribution_name(enum mbench_index_distribution dist);
const char *mbench_hotset_index_mode_name(enum mbench_hotset_index_mode mode);
const char *mbench_hugepage_name(enum mbench_hugepage_kind kind);
const char *mbench_phase_preset_name(enum mbench_phase_preset preset);

int mbench_mode_from_string(const char *value, enum mbench_mode *mode);
int mbench_move_policy_from_string(const char *value,
                                   enum mbench_move_policy *policy);
int mbench_placement_from_string(const char *value,
                                 struct mbench_numa_config *placement);
int mbench_bw_kernel_from_string(const char *value,
                                 enum mbench_bw_kernel *kernel);
int mbench_index_kernel_from_string(const char *value,
                                    enum mbench_index_kernel *kernel);
int mbench_index_distribution_from_string(const char *value,
                                          enum mbench_index_distribution *dist);
int mbench_hotset_index_mode_from_string(const char *value,
                                         enum mbench_hotset_index_mode *mode);
int mbench_hugepage_from_string(const char *value,
                                enum mbench_hugepage_kind *kind);
int mbench_phase_preset_from_string(const char *value,
                                    enum mbench_phase_preset *preset);
int mbench_parse_size_bytes(const char *value, size_t *out_bytes);
int mbench_parse_u32(const char *value, uint32_t *out);
int mbench_parse_u64(const char *value, uint64_t *out);
int mbench_parse_double(const char *value, double *out);

void mbench_config_init(struct mbench_config *config);
int mbench_config_validate(struct mbench_config *config);
int mbench_config_parse(struct mbench_config *config, int argc, char **argv);
void mbench_print_usage(FILE *out, const char *progname);
void mbench_config_dump(FILE *out, const struct mbench_config *config);

bool mbench_phase_enabled(const struct mbench_config *config);
size_t mbench_phase_total_count(const struct mbench_config *config);
int mbench_phase_build(const struct mbench_config *base_config,
                       size_t phase_index,
                       struct mbench_phase *phase);

uint64_t mbench_now_ns(void);
uint64_t mbench_now_us(void);
void mbench_sleep_ms(uint32_t ms);
void mbench_sleep_ns(uint64_t ns);

int mbench_arena_init(struct mbench_arena *arena,
                      size_t bytes,
                      enum mbench_hugepage_kind hugepage,
                      bool prefault);
int mbench_arena_prefault(struct mbench_arena *arena);
int mbench_arena_prefault_hotset_node(struct mbench_arena *arena,
                                      const struct mbench_config *config);
int mbench_arena_prefault_window_split(struct mbench_arena *arena,
                                       const struct mbench_config *config);
int mbench_arena_prefault_head_local_tail_remote(struct mbench_arena *arena,
                                                 const struct mbench_config *config);
void mbench_arena_destroy(struct mbench_arena *arena);

int mbench_window_init(struct mbench_window_state *window,
                       const struct mbench_config *config);
int mbench_window_advance(struct mbench_window_state *window);
void mbench_window_reset(struct mbench_window_state *window);

int mbench_runtime_prepare(struct mbench_runtime *runtime,
                           struct mbench_config *config);
void mbench_runtime_release(struct mbench_runtime *runtime);
int mbench_runtime_advance_window(struct mbench_runtime *runtime);
int mbench_runtime_apply_phase(struct mbench_runtime *runtime,
                               const struct mbench_phase *phase);

int mbench_execute_pc(struct mbench_runtime *runtime);
int mbench_execute_bw(struct mbench_runtime *runtime);
int mbench_execute_mix(struct mbench_runtime *runtime);
int mbench_execute_skewed_hotset(struct mbench_runtime *runtime);
int mbench_execute_irregular_index(struct mbench_runtime *runtime);

int mbench_pin_thread_cpu(pthread_t thread, int cpu_id);
int mbench_pin_current_cpu(int cpu_id);

int mbench_numa_supported(void);
int mbench_apply_placement(const struct mbench_config *config,
                           const struct mbench_arena *arena);
int mbench_move_range_to_node(void *addr, size_t length, int node);
int mbench_move_range_to_nodes(void *addr,
                               size_t length,
                               const int *nodes,
                               size_t node_count);
int mbench_query_range_nodes(void *addr,
                             size_t length,
                             int *status_out,
                             size_t status_count);

#ifdef __cplusplus
}
#endif

#endif /* MBENCH_H */
