#define _GNU_SOURCE

#include "mbench.h"

#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

static const size_t k_default_arena_bytes = 256ULL * 1024ULL * 1024ULL;
static const size_t k_default_window_bytes = 64ULL * 1024ULL * 1024ULL;
static const size_t k_default_move_step_bytes = 4ULL * 1024ULL * 1024ULL;
static const uint32_t k_default_duration_ms = 1000U;
static const uint32_t k_default_sample_ms = 1000U;
static const uint32_t k_default_move_interval_ms = 1000U;
static const uint64_t k_default_seed = 0x123456789abcdef0ULL;
static const uint32_t k_forced_duration_ms = 200000U;
static const uint32_t k_default_phase_duration_ms = 10000U;
static const uint32_t k_default_bw_stride_elements = 1U;
static const size_t k_default_index_cluster_bytes = 2ULL * 1024ULL * 1024ULL;
static const uint32_t k_default_index_cluster_span_ops = 4096U;
static const uint32_t k_default_index_segment_count = 8U;
static const uint32_t k_default_index_segment_span_ops = 4096U;
static const double k_default_index_zipf_alpha = 1.2;

static size_t page_size(void)
{
    long ps = sysconf(_SC_PAGESIZE);
    if (ps <= 0) {
        return 4096U;
    }
    return (size_t)ps;
}

static int parse_unsigned_suffix(const char *value, unsigned long long *out)
{
    char *end = NULL;
    errno = 0;
    unsigned long long raw = strtoull(value, &end, 10);
    if (errno != 0 || end == value) {
        return -EINVAL;
    }

    while (*end != '\0' && isspace((unsigned char)*end)) {
        end++;
    }

    unsigned long long scale = 1ULL;
    if (*end != '\0') {
        char suffix = (char)toupper((unsigned char)*end++);
        if (suffix == 'B') {
            if (*end != '\0') {
                return -EINVAL;
            }
        } else if (suffix == 'K') {
            scale = 1024ULL;
        } else if (suffix == 'M') {
            scale = 1024ULL * 1024ULL;
        } else if (suffix == 'G') {
            scale = 1024ULL * 1024ULL * 1024ULL;
        } else {
            return -EINVAL;
        }

        if (*end == 'B' || *end == 'b') {
            end++;
        }
        while (*end != '\0' && isspace((unsigned char)*end)) {
            end++;
        }
        if (*end != '\0') {
            return -EINVAL;
        }
    }

    if (raw > ULLONG_MAX / scale) {
        return -ERANGE;
    }

    *out = raw * scale;
    return 0;
}

static int parse_node_list(const char *value, struct mbench_node_list *nodes)
{
    char *copy = strdup(value);
    if (!copy) {
        return -ENOMEM;
    }

    nodes->count = 0;
    char *save = NULL;
    for (char *token = strtok_r(copy, ",", &save);
         token != NULL;
         token = strtok_r(NULL, ",", &save)) {
        while (*token != '\0' && isspace((unsigned char)*token)) {
            token++;
        }
        char *tail = token + strlen(token);
        while (tail > token && isspace((unsigned char)tail[-1])) {
            *--tail = '\0';
        }
        if (*token == '\0') {
            free(copy);
            return -EINVAL;
        }

        char *end = NULL;
        errno = 0;
        long node = strtol(token, &end, 10);
        if (errno != 0 || end == token || *end != '\0' || node < 0) {
            free(copy);
            return -EINVAL;
        }
        if (nodes->count >= MBENCH_MAX_NUMA_NODES) {
            free(copy);
            return -E2BIG;
        }
        nodes->nodes[nodes->count++] = (int)node;
    }

    free(copy);
    return nodes->count > 0 ? 0 : -EINVAL;
}

static const char *option_value(int *index, int argc, char **argv, const char *arg)
{
    const char *eq = strchr(arg, '=');
    if (eq != NULL) {
        return eq + 1;
    }
    if (*index + 1 >= argc) {
        return NULL;
    }
    (*index)++;
    return argv[*index];
}

const char *mbench_mode_name(enum mbench_mode mode)
{
    switch (mode) {
    case MBENCH_MODE_PC:
        return "pc";
    case MBENCH_MODE_BW:
        return "bw";
    case MBENCH_MODE_MIX:
        return "mix";
    case MBENCH_MODE_SKEWED_HOTSET:
        return "skewed-hotset";
    case MBENCH_MODE_IRREGULAR_INDEX:
        return "irregular-index";
    default:
        return "unknown";
    }
}

const char *mbench_move_policy_name(enum mbench_move_policy policy)
{
    switch (policy) {
    case MBENCH_MOVE_FIXED:
        return "fixed";
    case MBENCH_MOVE_PINGPONG:
        return "pingpong";
    case MBENCH_MOVE_SWEEP:
        return "sweep";
    case MBENCH_MOVE_RANDOM:
        return "random";
    default:
        return "unknown";
    }
}

const char *mbench_placement_name(enum mbench_placement_kind kind)
{
    switch (kind) {
    case MBENCH_PLACEMENT_NONE:
        return "none";
    case MBENCH_PLACEMENT_BIND:
        return "bind";
    case MBENCH_PLACEMENT_INTERLEAVE:
        return "interleave";
    case MBENCH_PLACEMENT_PREFERRED:
        return "preferred";
    case MBENCH_PLACEMENT_SPLIT:
        return "split";
    case MBENCH_PLACEMENT_WINDOW_SPLIT:
        return "window-split";
    case MBENCH_PLACEMENT_ARENA_SPLIT:
        return "arena-split";
    default:
        return "unknown";
    }
}

const char *mbench_bw_kernel_name(enum mbench_bw_kernel kernel)
{
    switch (kernel) {
    case MBENCH_BW_READ:
        return "read";
    case MBENCH_BW_WRITE:
        return "write";
    case MBENCH_BW_COPY:
        return "copy";
    case MBENCH_BW_TRIAD:
        return "triad";
    default:
        return "unknown";
    }
}

const char *mbench_index_kernel_name(enum mbench_index_kernel kernel)
{
    switch (kernel) {
    case MBENCH_INDEX_GATHER:
        return "gather";
    case MBENCH_INDEX_SCATTER:
        return "scatter";
    case MBENCH_INDEX_RMW:
        return "rmw";
    default:
        return "unknown";
    }
}

const char *mbench_index_distribution_name(enum mbench_index_distribution dist)
{
    switch (dist) {
    case MBENCH_INDEX_DIST_UNIFORM:
        return "uniform";
    case MBENCH_INDEX_DIST_ZIPF:
        return "zipf";
    case MBENCH_INDEX_DIST_CLUSTERED:
        return "clustered";
    case MBENCH_INDEX_DIST_SEGMENTED:
        return "segmented";
    default:
        return "unknown";
    }
}

const char *mbench_hotset_index_mode_name(enum mbench_hotset_index_mode mode)
{
    switch (mode) {
    case MBENCH_HOTSET_INDEX_XORSHIFT:
        return "xorshift";
    case MBENCH_HOTSET_INDEX_MULSHIFT:
        return "mulshift";
    default:
        return "unknown";
    }
}

static const char *mbench_pc_pattern_name(enum mbench_pc_pattern pattern)
{
    switch (pattern) {
    case MBENCH_PC_PATTERN_RANDOM:
        return "random";
    case MBENCH_PC_PATTERN_STRIDE:
        return "stride";
    default:
        return "unknown";
    }
}

const char *mbench_hugepage_name(enum mbench_hugepage_kind kind)
{
    switch (kind) {
    case MBENCH_HUGEPAGE_NONE:
        return "none";
    case MBENCH_HUGEPAGE_THP:
        return "thp";
    case MBENCH_HUGEPAGE_HUGETLB_2M:
        return "2m";
    case MBENCH_HUGEPAGE_HUGETLB_1G:
        return "1g";
    default:
        return "unknown";
    }
}

const char *mbench_phase_preset_name(enum mbench_phase_preset preset)
{
    switch (preset) {
    case MBENCH_PHASE_PRESET_NONE:
        return "none";
    case MBENCH_PHASE_PRESET_FRIENDLY_STREAM:
        return "friendly-unfriendly";
    case MBENCH_PHASE_PRESET_TAIL_HOTSET_SPARSE16:
        return "tail-hotset-sparse16";
    case MBENCH_PHASE_PRESET_TAIL_HOTSET_SPARSE24:
        return "tail-hotset-sparse24";
    case MBENCH_PHASE_PRESET_SPARSE24_TAIL_HOTSET:
        return "sparse24-tail-hotset";
    case MBENCH_PHASE_PRESET_SKEW4G_SPARSE64:
        return "skew4g-sparse64";
    case MBENCH_PHASE_PRESET_MULSHIFT4G_SPARSE24:
        return "mulshift4g-sparse24";
    case MBENCH_PHASE_PRESET_MULSHIFT4G_SPARSE64:
        return "mulshift4g-sparse64";
    case MBENCH_PHASE_PRESET_MULSHIFT4G_ROT_SPARSE24:
        return "mulshift4g-rot-sparse24";
    case MBENCH_PHASE_PRESET_MULSHIFT4G_ROT_SPARSE64:
        return "mulshift4g-rot-sparse64";
    case MBENCH_PHASE_PRESET_MULSHIFT4G_ROT_MOVE16G3S:
        return "mulshift4g-rot-move16g3s";
    case MBENCH_PHASE_PRESET_MULSHIFT4G_BLOCK2M_SPARSE64:
        return "mulshift4g-block2m-sparse64";
    case MBENCH_PHASE_PRESET_MOVE15S4G_SPLIT32:
        return "move15s4g-split32";
    case MBENCH_PHASE_PRESET_MOVE15S4G_REMOTE_SPLIT32:
        return "move15s4g-remote-split32";
    case MBENCH_PHASE_PRESET_MOVE60S4G_REMOTE_SPLIT32:
        return "move60s4g-remote-split32";
    case MBENCH_PHASE_PRESET_FIXED4G_REMOTE_SPLIT32:
        return "fixed4g-remote-split32";
    case MBENCH_PHASE_PRESET_FIXED8G_REMOTE_SPLIT32:
        return "fixed8g-remote-split32";
    case MBENCH_PHASE_PRESET_SPARSE64_MULSHIFT4G:
        return "sparse64-mulshift4g";
    case MBENCH_PHASE_PRESET_SPARSE64_WEIGHTED8G:
        return "sparse64-weighted8g";
    case MBENCH_PHASE_PRESET_SPARSE60_DISJOINT8G:
        return "sparse60-disjoint8g";
    case MBENCH_PHASE_PRESET_SPARSE60_DISJOINT28G:
        return "sparse60-disjoint28g";
    case MBENCH_PHASE_PRESET_GUPS60_DISJOINT28G:
        return "gups60-disjoint28g";
    case MBENCH_PHASE_PRESET_GUPS60_DISJOINT32G:
        return "gups60-disjoint32g";
    case MBENCH_PHASE_PRESET_GUPS60_DISJOINT48G:
        return "gups60-disjoint48g";
    case MBENCH_PHASE_PRESET_GUPS60_DISJOINT36G:
        return "gups60-disjoint36g";
    case MBENCH_PHASE_PRESET_GUPS60_DISJOINT38G:
        return "gups60-disjoint38g";
    case MBENCH_PHASE_PRESET_GUPS60_DISJOINT40G:
        return "gups60-disjoint40g";
    default:
        return "unknown";
    }
}

int mbench_mode_from_string(const char *value, enum mbench_mode *mode)
{
    if (!value || !mode) {
        return -EINVAL;
    }
    if (strcasecmp(value, "pc") == 0) {
        *mode = MBENCH_MODE_PC;
        return 0;
    }
    if (strcasecmp(value, "bw") == 0) {
        *mode = MBENCH_MODE_BW;
        return 0;
    }
    if (strcasecmp(value, "mix") == 0 || strcasecmp(value, "mixed") == 0) {
        *mode = MBENCH_MODE_MIX;
        return 0;
    }
    if (strcasecmp(value, "skewed-hotset") == 0 || strcasecmp(value, "hotset") == 0) {
        *mode = MBENCH_MODE_SKEWED_HOTSET;
        return 0;
    }
    if (strcasecmp(value, "irregular-index") == 0 || strcasecmp(value, "index") == 0) {
        *mode = MBENCH_MODE_IRREGULAR_INDEX;
        return 0;
    }
    return -EINVAL;
}

int mbench_phase_preset_from_string(const char *value,
                                    enum mbench_phase_preset *preset)
{
    if (!value || !preset) {
        return -EINVAL;
    }
    if (strcasecmp(value, "none") == 0) {
        *preset = MBENCH_PHASE_PRESET_NONE;
        return 0;
    }
    if (strcasecmp(value, "friendly-unfriendly") == 0 ||
        strcasecmp(value, "friendly-stream") == 0) {
        *preset = MBENCH_PHASE_PRESET_FRIENDLY_STREAM;
        return 0;
    }
    if (strcasecmp(value, "tail-hotset-sparse16") == 0 ||
        strcasecmp(value, "tail-hotset-vs-sparse16") == 0) {
        *preset = MBENCH_PHASE_PRESET_TAIL_HOTSET_SPARSE16;
        return 0;
    }
    if (strcasecmp(value, "tail-hotset-sparse24") == 0 ||
        strcasecmp(value, "tail-hotset-vs-sparse24") == 0) {
        *preset = MBENCH_PHASE_PRESET_TAIL_HOTSET_SPARSE24;
        return 0;
    }
    if (strcasecmp(value, "sparse24-tail-hotset") == 0 ||
        strcasecmp(value, "sparse24-vs-tail-hotset") == 0) {
        *preset = MBENCH_PHASE_PRESET_SPARSE24_TAIL_HOTSET;
        return 0;
    }
    if (strcasecmp(value, "skew4g-sparse64") == 0 ||
        strcasecmp(value, "skew4g-vs-sparse64") == 0) {
        *preset = MBENCH_PHASE_PRESET_SKEW4G_SPARSE64;
        return 0;
    }
    if (strcasecmp(value, "mulshift4g-sparse24") == 0 ||
        strcasecmp(value, "mulshift4g-vs-sparse24") == 0) {
        *preset = MBENCH_PHASE_PRESET_MULSHIFT4G_SPARSE24;
        return 0;
    }
    if (strcasecmp(value, "mulshift4g-sparse64") == 0 ||
        strcasecmp(value, "mulshift4g-vs-sparse64") == 0) {
        *preset = MBENCH_PHASE_PRESET_MULSHIFT4G_SPARSE64;
        return 0;
    }
    if (strcasecmp(value, "mulshift4g-rot-sparse24") == 0 ||
        strcasecmp(value, "mulshift4g-rotate-sparse24") == 0 ||
        strcasecmp(value, "mulshift4g-moving-sparse24") == 0) {
        *preset = MBENCH_PHASE_PRESET_MULSHIFT4G_ROT_SPARSE24;
        return 0;
    }
    if (strcasecmp(value, "mulshift4g-rot-sparse64") == 0 ||
        strcasecmp(value, "mulshift4g-rotate-sparse64") == 0 ||
        strcasecmp(value, "mulshift4g-moving-sparse64") == 0) {
        *preset = MBENCH_PHASE_PRESET_MULSHIFT4G_ROT_SPARSE64;
        return 0;
    }
    if (strcasecmp(value, "mulshift4g-rot-move16g3s") == 0 ||
        strcasecmp(value, "mulshift4g-rotate-move16g3s") == 0 ||
        strcasecmp(value, "mulshift4g-vs-move16g3s") == 0) {
        *preset = MBENCH_PHASE_PRESET_MULSHIFT4G_ROT_MOVE16G3S;
        return 0;
    }
    if (strcasecmp(value, "mulshift4g-block2m-sparse64") == 0 ||
        strcasecmp(value, "mulshift4g-vs-block2m-sparse64") == 0 ||
        strcasecmp(value, "mulshift4g-block2m-vs-sparse64") == 0) {
        *preset = MBENCH_PHASE_PRESET_MULSHIFT4G_BLOCK2M_SPARSE64;
        return 0;
    }
    if (strcasecmp(value, "move15s4g-split32") == 0 ||
        strcasecmp(value, "move15s4g-vs-split32") == 0 ||
        strcasecmp(value, "move15s4g-vs-stream32") == 0) {
        *preset = MBENCH_PHASE_PRESET_MOVE15S4G_SPLIT32;
        return 0;
    }
    if (strcasecmp(value, "move15s4g-remote-split32") == 0 ||
        strcasecmp(value, "move15s4g-remote-vs-split32") == 0 ||
        strcasecmp(value, "move15s4g-remote-vs-stream32") == 0) {
        *preset = MBENCH_PHASE_PRESET_MOVE15S4G_REMOTE_SPLIT32;
        return 0;
    }
    if (strcasecmp(value, "move60s4g-remote-split32") == 0 ||
        strcasecmp(value, "move60s4g-remote-vs-split32") == 0 ||
        strcasecmp(value, "move60s4g-remote-vs-stream32") == 0) {
        *preset = MBENCH_PHASE_PRESET_MOVE60S4G_REMOTE_SPLIT32;
        return 0;
    }
    if (strcasecmp(value, "fixed4g-remote-split32") == 0 ||
        strcasecmp(value, "fixed4g-remote-vs-split32") == 0 ||
        strcasecmp(value, "fixed4g-remote-vs-stream32") == 0) {
        *preset = MBENCH_PHASE_PRESET_FIXED4G_REMOTE_SPLIT32;
        return 0;
    }
    if (strcasecmp(value, "fixed8g-remote-split32") == 0 ||
        strcasecmp(value, "fixed8g-remote-vs-split32") == 0 ||
        strcasecmp(value, "fixed8g-remote-vs-stream32") == 0) {
        *preset = MBENCH_PHASE_PRESET_FIXED8G_REMOTE_SPLIT32;
        return 0;
    }
    if (strcasecmp(value, "sparse64-mulshift4g") == 0 ||
        strcasecmp(value, "sparse64-vs-mulshift4g") == 0) {
        *preset = MBENCH_PHASE_PRESET_SPARSE64_MULSHIFT4G;
        return 0;
    }
    if (strcasecmp(value, "sparse64-weighted8g") == 0 ||
        strcasecmp(value, "sparse64-vs-weighted8g") == 0) {
        *preset = MBENCH_PHASE_PRESET_SPARSE64_WEIGHTED8G;
        return 0;
    }
    if (strcasecmp(value, "sparse60-disjoint8g") == 0 ||
        strcasecmp(value, "sparse60-vs-disjoint8g") == 0) {
        *preset = MBENCH_PHASE_PRESET_SPARSE60_DISJOINT8G;
        return 0;
    }
    if (strcasecmp(value, "sparse60-disjoint28g") == 0 ||
        strcasecmp(value, "sparse60-vs-disjoint28g") == 0) {
        *preset = MBENCH_PHASE_PRESET_SPARSE60_DISJOINT28G;
        return 0;
    }
    if (strcasecmp(value, "gups60-disjoint28g") == 0 ||
        strcasecmp(value, "gups60-vs-disjoint28g") == 0) {
        *preset = MBENCH_PHASE_PRESET_GUPS60_DISJOINT28G;
        return 0;
    }
    if (strcasecmp(value, "gups60-disjoint32g") == 0 ||
        strcasecmp(value, "gups60-vs-disjoint32g") == 0 ||
        strcasecmp(value, "gups60-bg24-hot8g80") == 0) {
        *preset = MBENCH_PHASE_PRESET_GUPS60_DISJOINT32G;
        return 0;
    }
    if (strcasecmp(value, "gups60-disjoint48g") == 0 ||
        strcasecmp(value, "gups60-vs-disjoint48g") == 0 ||
        strcasecmp(value, "gups60-bg24-hot24g80") == 0) {
        *preset = MBENCH_PHASE_PRESET_GUPS60_DISJOINT48G;
        return 0;
    }
    if (strcasecmp(value, "gups60-disjoint36g") == 0 ||
        strcasecmp(value, "gups60-vs-disjoint36g") == 0 ||
        strcasecmp(value, "gups60-bg24-hot12g80") == 0) {
        *preset = MBENCH_PHASE_PRESET_GUPS60_DISJOINT36G;
        return 0;
    }
    if (strcasecmp(value, "gups60-disjoint38g") == 0 ||
        strcasecmp(value, "gups60-vs-disjoint38g") == 0 ||
        strcasecmp(value, "gups60-bg24-hot14g80") == 0) {
        *preset = MBENCH_PHASE_PRESET_GUPS60_DISJOINT38G;
        return 0;
    }
    if (strcasecmp(value, "gups60-disjoint40g") == 0 ||
        strcasecmp(value, "gups60-vs-disjoint40g") == 0 ||
        strcasecmp(value, "gups60-bg24-hot16g80") == 0) {
        *preset = MBENCH_PHASE_PRESET_GUPS60_DISJOINT40G;
        return 0;
    }
    return -EINVAL;
}

int mbench_move_policy_from_string(const char *value,
                                   enum mbench_move_policy *policy)
{
    if (!value || !policy) {
        return -EINVAL;
    }
    if (strcasecmp(value, "fixed") == 0) {
        *policy = MBENCH_MOVE_FIXED;
        return 0;
    }
    if (strcasecmp(value, "pingpong") == 0) {
        *policy = MBENCH_MOVE_PINGPONG;
        return 0;
    }
    if (strcasecmp(value, "sweep") == 0) {
        *policy = MBENCH_MOVE_SWEEP;
        return 0;
    }
    if (strcasecmp(value, "random") == 0 || strcasecmp(value, "rand") == 0) {
        *policy = MBENCH_MOVE_RANDOM;
        return 0;
    }
    return -EINVAL;
}

int mbench_bw_kernel_from_string(const char *value, enum mbench_bw_kernel *kernel)
{
    if (!value || !kernel) {
        return -EINVAL;
    }
    if (strcasecmp(value, "read") == 0) {
        *kernel = MBENCH_BW_READ;
        return 0;
    }
    if (strcasecmp(value, "write") == 0) {
        *kernel = MBENCH_BW_WRITE;
        return 0;
    }
    if (strcasecmp(value, "copy") == 0) {
        *kernel = MBENCH_BW_COPY;
        return 0;
    }
    if (strcasecmp(value, "triad") == 0) {
        *kernel = MBENCH_BW_TRIAD;
        return 0;
    }
    return -EINVAL;
}

int mbench_index_kernel_from_string(const char *value, enum mbench_index_kernel *kernel)
{
    if (!value || !kernel) {
        return -EINVAL;
    }
    if (strcasecmp(value, "gather") == 0) {
        *kernel = MBENCH_INDEX_GATHER;
        return 0;
    }
    if (strcasecmp(value, "scatter") == 0) {
        *kernel = MBENCH_INDEX_SCATTER;
        return 0;
    }
    if (strcasecmp(value, "rmw") == 0 || strcasecmp(value, "xor") == 0) {
        *kernel = MBENCH_INDEX_RMW;
        return 0;
    }
    return -EINVAL;
}

int mbench_index_distribution_from_string(const char *value,
                                          enum mbench_index_distribution *dist)
{
    if (!value || !dist) {
        return -EINVAL;
    }
    if (strcasecmp(value, "uniform") == 0) {
        *dist = MBENCH_INDEX_DIST_UNIFORM;
        return 0;
    }
    if (strcasecmp(value, "zipf") == 0) {
        *dist = MBENCH_INDEX_DIST_ZIPF;
        return 0;
    }
    if (strcasecmp(value, "clustered") == 0 || strcasecmp(value, "cluster") == 0) {
        *dist = MBENCH_INDEX_DIST_CLUSTERED;
        return 0;
    }
    if (strcasecmp(value, "segmented") == 0 || strcasecmp(value, "segment") == 0) {
        *dist = MBENCH_INDEX_DIST_SEGMENTED;
        return 0;
    }
    return -EINVAL;
}

int mbench_hotset_index_mode_from_string(const char *value,
                                         enum mbench_hotset_index_mode *mode)
{
    if (!value || !mode) {
        return -EINVAL;
    }
    if (strcasecmp(value, "xorshift") == 0 || strcasecmp(value, "random") == 0 ||
        strcasecmp(value, "modulo") == 0) {
        *mode = MBENCH_HOTSET_INDEX_XORSHIFT;
        return 0;
    }
    if (strcasecmp(value, "mulshift") == 0 || strcasecmp(value, "multiply-shift") == 0 ||
        strcasecmp(value, "fib") == 0 || strcasecmp(value, "fibonacci") == 0) {
        *mode = MBENCH_HOTSET_INDEX_MULSHIFT;
        return 0;
    }
    return -EINVAL;
}

static int mbench_pc_pattern_from_string(const char *value, enum mbench_pc_pattern *pattern)
{
    if (!value || !pattern) {
        return -EINVAL;
    }
    if (strcasecmp(value, "random") == 0 || strcasecmp(value, "shuffle") == 0) {
        *pattern = MBENCH_PC_PATTERN_RANDOM;
        return 0;
    }
    if (strcasecmp(value, "stride") == 0 || strcasecmp(value, "affine") == 0) {
        *pattern = MBENCH_PC_PATTERN_STRIDE;
        return 0;
    }
    return -EINVAL;
}

int mbench_hugepage_from_string(const char *value, enum mbench_hugepage_kind *kind)
{
    if (!value || !kind) {
        return -EINVAL;
    }
    if (strcasecmp(value, "none") == 0) {
        *kind = MBENCH_HUGEPAGE_NONE;
        return 0;
    }
    if (strcasecmp(value, "thp") == 0 || strcasecmp(value, "transparent") == 0) {
        *kind = MBENCH_HUGEPAGE_THP;
        return 0;
    }
    if (strcasecmp(value, "2m") == 0 || strcasecmp(value, "hugetlb2m") == 0) {
        *kind = MBENCH_HUGEPAGE_HUGETLB_2M;
        return 0;
    }
    if (strcasecmp(value, "1g") == 0 || strcasecmp(value, "hugetlb1g") == 0) {
        *kind = MBENCH_HUGEPAGE_HUGETLB_1G;
        return 0;
    }
    return -EINVAL;
}

int mbench_parse_size_bytes(const char *value, size_t *out_bytes)
{
    if (!value || !out_bytes) {
        return -EINVAL;
    }

    unsigned long long parsed = 0;
    int rc = parse_unsigned_suffix(value, &parsed);
    if (rc != 0) {
        return rc;
    }
    if (parsed > SIZE_MAX) {
        return -ERANGE;
    }

    *out_bytes = (size_t)parsed;
    return 0;
}

int mbench_parse_u32(const char *value, uint32_t *out)
{
    if (!value || !out) {
        return -EINVAL;
    }

    char *end = NULL;
    errno = 0;
    unsigned long parsed = strtoul(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || parsed > UINT32_MAX) {
        return -EINVAL;
    }

    *out = (uint32_t)parsed;
    return 0;
}

int mbench_parse_u64(const char *value, uint64_t *out)
{
    if (!value || !out) {
        return -EINVAL;
    }

    char *end = NULL;
    errno = 0;
    unsigned long long parsed = strtoull(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0') {
        return -EINVAL;
    }

    *out = (uint64_t)parsed;
    return 0;
}

int mbench_parse_double(const char *value, double *out)
{
    if (!value || !out) {
        return -EINVAL;
    }

    char *end = NULL;
    errno = 0;
    double parsed = strtod(value, &end);
    if (errno != 0 || end == value || *end != '\0') {
        return -EINVAL;
    }

    *out = parsed;
    return 0;
}

int mbench_parse_residency_probe(const char *value,
                                 struct mbench_residency_probe_config *probe)
{
    char *copy;
    char *offset_text;
    char *size_text;
    size_t label_len;
    size_t offset_bytes;
    size_t size_bytes;
    int rc;

    if (!value || !probe) {
        return -EINVAL;
    }

    copy = strdup(value);
    if (!copy) {
        return -ENOMEM;
    }

    offset_text = strchr(copy, ':');
    if (!offset_text) {
        free(copy);
        return -EINVAL;
    }
    *offset_text++ = '\0';

    size_text = strchr(offset_text, ':');
    if (!size_text || strchr(size_text + 1, ':') != NULL) {
        free(copy);
        return -EINVAL;
    }
    *size_text++ = '\0';

    label_len = strlen(copy);
    if (label_len == 0 || label_len >= sizeof(probe->label)) {
        free(copy);
        return -EINVAL;
    }
    for (size_t i = 0; i < label_len; ++i) {
        unsigned char ch = (unsigned char)copy[i];
        bool ascii_alnum = (ch >= '0' && ch <= '9') ||
            (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z');

        if (!ascii_alnum && ch != '_' && ch != '-' && ch != '.') {
            free(copy);
            return -EINVAL;
        }
    }

    rc = mbench_parse_size_bytes(offset_text, &offset_bytes);
    if (rc == 0) {
        rc = mbench_parse_size_bytes(size_text, &size_bytes);
    }
    if (rc != 0 || size_bytes == 0) {
        free(copy);
        return rc != 0 ? rc : -EINVAL;
    }

    memset(probe, 0, sizeof(*probe));
    memcpy(probe->label, copy, label_len);
    probe->offset_bytes = offset_bytes;
    probe->size_bytes = size_bytes;
    free(copy);
    return 0;
}

void mbench_config_init(struct mbench_config *config)
{
    memset(config, 0, sizeof(*config));
    config->mode = MBENCH_MODE_BW;
    config->bw_kernel = MBENCH_BW_TRIAD;
    config->hugepage = MBENCH_HUGEPAGE_NONE;
    config->prefault = true;
    config->prefault_node = -1;
    config->seed = k_default_seed;
    config->timing.duration_ms = k_default_duration_ms;
    config->timing.sample_ms = k_default_sample_ms;
    config->timing.move_interval_ms = k_default_move_interval_ms;
    config->report.csv = false;
    config->report.quiet = false;
    config->report.emit_summary = true;
    config->window.arena_bytes = k_default_arena_bytes;
    config->window.window_bytes = k_default_window_bytes;
    config->window.offset_bytes = 0;
    config->window.move_step_bytes = k_default_move_step_bytes;
    config->window.move_min_offset_bytes = 0;
    config->window.move_max_offset_bytes = 0;
    config->window.move_policy = MBENCH_MOVE_FIXED;
    config->placement.kind = MBENCH_PLACEMENT_NONE;
    config->placement.nodes.count = 0;
    config->placement.local_node = -1;
    config->placement.remote_node = -1;
    config->placement.window_split_local_bytes = 0;
    config->placement.arena_split_local_bytes = 0;
    config->placement.strict = false;
    config->threads.total_threads = 0;
    config->threads.pc_threads = 0;
    config->threads.bw_threads = 0;
    config->threads.pc_chains = 1;
    config->threads.pc_pattern = MBENCH_PC_PATTERN_RANDOM;
    config->request.ops_per_pass = 0;
    config->request.target_ops = 0;
    config->request.pause_ns = 0;
    config->bw_pattern.stride_elements = k_default_bw_stride_elements;
    config->bw_pattern.block_bytes = 0;
    config->bw_pattern.shared_window = false;
    config->hotset.hotset_pages = 0;
    config->hotset.background_pages = 0;
    config->hotset.hot_prob_pct = 90U;
    config->hotset.read_pct = 100U;
    config->hotset.write_pct = 0U;
    config->hotset.rmw_pct = 0U;
    config->hotset.index_mode = MBENCH_HOTSET_INDEX_XORSHIFT;
    config->hotset.prefault_node = -1;
    config->hotset.shared_window = false;
    config->hotset.tail = false;
    config->irregular.kernel = MBENCH_INDEX_RMW;
    config->irregular.distribution = MBENCH_INDEX_DIST_UNIFORM;
    config->irregular.zipf_alpha = k_default_index_zipf_alpha;
    config->irregular.cluster_bytes = k_default_index_cluster_bytes;
    config->irregular.cluster_span_ops = k_default_index_cluster_span_ops;
    config->irregular.segment_count = k_default_index_segment_count;
    config->irregular.segment_span_ops = k_default_index_segment_span_ops;
    config->phase.preset = MBENCH_PHASE_PRESET_NONE;
    config->phase.repeat = 1U;
    config->phase.duration_ms = k_default_phase_duration_ms;
    config->phase.phase1_target_ops = 0;
    config->phase.phase2_target_ops = 0;
}

static int finalize_thread_counts(struct mbench_config *config)
{
    if (config->threads.total_threads > 0) {
        switch (config->mode) {
        case MBENCH_MODE_PC:
            if (config->threads.pc_threads <= 0) {
                config->threads.pc_threads = config->threads.total_threads;
            }
            break;
        case MBENCH_MODE_BW:
            if (config->threads.bw_threads <= 0) {
                config->threads.bw_threads = config->threads.total_threads;
            }
            break;
        case MBENCH_MODE_MIX:
            if (config->threads.pc_threads <= 0 && config->threads.bw_threads <= 0) {
                if (config->threads.total_threads < 2) {
                    return -EINVAL;
                }
                config->threads.pc_threads = config->threads.total_threads / 2;
                config->threads.bw_threads = config->threads.total_threads - config->threads.pc_threads;
            } else if (config->threads.pc_threads <= 0) {
                config->threads.pc_threads = config->threads.total_threads - config->threads.bw_threads;
                if (config->threads.pc_threads <= 0) {
                    return -EINVAL;
                }
            } else if (config->threads.bw_threads <= 0) {
                config->threads.bw_threads = config->threads.total_threads - config->threads.pc_threads;
                if (config->threads.bw_threads <= 0) {
                    return -EINVAL;
                }
            }
            break;
        case MBENCH_MODE_SKEWED_HOTSET:
        case MBENCH_MODE_IRREGULAR_INDEX:
            break;
        default:
            return -EINVAL;
        }
    }

    switch (config->mode) {
    case MBENCH_MODE_PC:
        if (config->threads.pc_threads <= 0) {
            config->threads.pc_threads = 1;
        }
        config->threads.bw_threads = 0;
        break;
    case MBENCH_MODE_BW:
        if (config->threads.bw_threads <= 0) {
            config->threads.bw_threads = 1;
        }
        config->threads.pc_threads = 0;
        break;
    case MBENCH_MODE_MIX:
        if (config->threads.pc_threads <= 0) {
            config->threads.pc_threads = 1;
        }
        if (config->threads.bw_threads <= 0) {
            config->threads.bw_threads = 1;
        }
        break;
    case MBENCH_MODE_SKEWED_HOTSET:
    case MBENCH_MODE_IRREGULAR_INDEX:
        if (config->threads.total_threads <= 0) {
            config->threads.total_threads = 1;
        }
        config->threads.pc_threads = 0;
        config->threads.bw_threads = 0;
        break;
    default:
        return -EINVAL;
    }

    if (config->threads.pc_chains <= 0) {
        config->threads.pc_chains = 1;
    }
    return 0;
}

int mbench_config_validate(struct mbench_config *config)
{
    if (!config) {
        return -EINVAL;
    }

    size_t ps = page_size();
    config->window.arena_bytes = mbench_align_up_size(config->window.arena_bytes, ps);
    config->window.window_bytes = mbench_align_up_size(config->window.window_bytes, ps);
    config->window.offset_bytes = mbench_align_up_size(config->window.offset_bytes, ps);
    config->window.move_step_bytes = mbench_align_up_size(config->window.move_step_bytes, ps);
    config->window.move_min_offset_bytes =
        mbench_align_up_size(config->window.move_min_offset_bytes, ps);
    config->window.move_max_offset_bytes =
        mbench_align_up_size(config->window.move_max_offset_bytes, ps);
    config->placement.window_split_local_bytes =
        mbench_align_up_size(config->placement.window_split_local_bytes, ps);
    config->placement.arena_split_local_bytes =
        mbench_align_up_size(config->placement.arena_split_local_bytes, ps);
    /*
     * Ignore caller-provided duration knobs and keep every run at a fixed
     * 200-second measured window. The runtime layer adds a fixed warmup
     * before measurement so migration behavior is comparable after early
     * setup effects have settled.
     */
    {
        const char *forced_duration = getenv("MBENCH_FORCE_DURATION_MS");
        uint32_t duration_ms = k_forced_duration_ms;

        if (forced_duration && forced_duration[0] != '\0') {
            uint32_t parsed = 0;

            if (mbench_parse_u32(forced_duration, &parsed) == 0 && parsed > 0) {
                duration_ms = parsed;
            }
        }

        config->timing.duration_ms = duration_ms;
    }
    config->timing.sample_ms = config->timing.sample_ms ? config->timing.sample_ms : k_default_sample_ms;
    config->timing.move_interval_ms = config->timing.move_interval_ms ? config->timing.move_interval_ms : k_default_move_interval_ms;
    if (config->window.move_step_bytes == 0) {
        config->window.move_step_bytes = ps;
    }
    if (config->window.move_step_bytes > config->window.window_bytes) {
        config->window.move_step_bytes = config->window.window_bytes;
    }
    if (config->window.window_bytes == 0 || config->window.window_bytes > config->window.arena_bytes) {
        return -EINVAL;
    }
    size_t max_offset = config->window.arena_bytes - config->window.window_bytes;
    if (config->window.move_min_offset_bytes > max_offset) {
        config->window.move_min_offset_bytes = max_offset;
    }
    if (config->window.move_max_offset_bytes == 0 ||
        config->window.move_max_offset_bytes > max_offset) {
        config->window.move_max_offset_bytes = max_offset;
    }
    if (config->window.move_max_offset_bytes < config->window.move_min_offset_bytes) {
        config->window.move_max_offset_bytes = config->window.move_min_offset_bytes;
    }
    if (config->window.offset_bytes < config->window.move_min_offset_bytes) {
        config->window.offset_bytes = config->window.move_min_offset_bytes;
    }
    if (config->window.offset_bytes > config->window.move_max_offset_bytes) {
        config->window.offset_bytes = config->window.move_max_offset_bytes;
    }
    size_t total_pages = config->window.window_bytes / ps;
    if (total_pages == 0) {
        return -EINVAL;
    }
    if (config->hotset.hotset_pages == 0) {
        config->hotset.hotset_pages = (uint32_t)(total_pages / 8U);
        if (config->hotset.hotset_pages == 0) {
            config->hotset.hotset_pages = 1U;
        }
    }
    if ((size_t)config->hotset.hotset_pages > total_pages) {
        config->hotset.hotset_pages = (uint32_t)total_pages;
    }
    if (config->hotset.background_pages > 0 &&
        (!config->hotset.tail ||
         (size_t)config->hotset.background_pages >
             total_pages - (size_t)config->hotset.hotset_pages)) {
        return -EINVAL;
    }
    if (config->hotset.hot_prob_pct > 100U) {
        return -EINVAL;
    }
    if (config->hotset.read_pct > 100U || config->hotset.write_pct > 100U ||
        config->hotset.rmw_pct > 100U) {
        return -EINVAL;
    }
    if (config->hotset.read_pct + config->hotset.write_pct + config->hotset.rmw_pct != 100U) {
        return -EINVAL;
    }
    if (config->bw_pattern.stride_elements == 0) {
        config->bw_pattern.stride_elements = k_default_bw_stride_elements;
    }
    config->bw_pattern.block_bytes = mbench_align_up_size(config->bw_pattern.block_bytes,
                                                          sizeof(double));
    if (config->irregular.zipf_alpha <= 0.0) {
        return -EINVAL;
    }
    config->irregular.cluster_bytes = mbench_align_up_size(config->irregular.cluster_bytes,
                                                           sizeof(uint64_t));
    if (config->irregular.cluster_span_ops == 0) {
        config->irregular.cluster_span_ops = k_default_index_cluster_span_ops;
    }
    if (config->irregular.segment_count == 0) {
        config->irregular.segment_count = k_default_index_segment_count;
    }
    if (config->irregular.segment_span_ops == 0) {
        config->irregular.segment_span_ops = k_default_index_segment_span_ops;
    }
    if ((config->placement.kind == MBENCH_PLACEMENT_SPLIT ||
         config->placement.kind == MBENCH_PLACEMENT_WINDOW_SPLIT ||
         config->placement.kind == MBENCH_PLACEMENT_ARENA_SPLIT) &&
        config->placement.nodes.count < 2) {
        return -EINVAL;
    }
    if (config->placement.kind == MBENCH_PLACEMENT_WINDOW_SPLIT &&
        config->placement.window_split_local_bytes >= config->window.window_bytes &&
        config->placement.window_split_local_bytes != 0) {
        return -EINVAL;
    }
    if (config->placement.kind == MBENCH_PLACEMENT_ARENA_SPLIT) {
        if (config->placement.nodes.count != 2 ||
            config->placement.nodes.nodes[0] == config->placement.nodes.nodes[1] ||
            config->placement.arena_split_local_bytes == 0 ||
            config->placement.arena_split_local_bytes >= config->window.arena_bytes ||
            !config->prefault) {
            return -EINVAL;
        }
    } else if (config->placement.arena_split_local_bytes != 0) {
        return -EINVAL;
    }
    if (config->placement.kind == MBENCH_PLACEMENT_NONE) {
        config->placement.local_node = -1;
        config->placement.remote_node = -1;
    } else if (config->placement.nodes.count > 0) {
        config->placement.local_node = config->placement.nodes.nodes[0];
        config->placement.remote_node = (config->placement.nodes.count > 1)
            ? config->placement.nodes.nodes[1]
            : -1;
    }
    if (config->phase.repeat == 0) {
        return -EINVAL;
    }
    if (config->phase.duration_ms == 0) {
        return -EINVAL;
    }
    if ((config->phase.phase1_target_ops == 0) !=
        (config->phase.phase2_target_ops == 0)) {
        return -EINVAL;
    }
    if (config->phase.phase1_target_ops > 0 &&
        config->phase.preset == MBENCH_PHASE_PRESET_NONE) {
        return -EINVAL;
    }
    if (config->request.target_ops > 0 &&
        config->phase.preset != MBENCH_PHASE_PRESET_NONE) {
        return -EINVAL;
    }
    if (config->phase.boundary_probe_count > MBENCH_MAX_PHASE_BOUNDARY_PROBES) {
        return -E2BIG;
    }
    if (config->phase.boundary_probe_count > 0 &&
        config->phase.preset == MBENCH_PHASE_PRESET_NONE) {
        return -EINVAL;
    }
    for (size_t i = 0; i < config->phase.boundary_probe_count; ++i) {
        const struct mbench_residency_probe_config *probe =
            &config->phase.boundary_probes[i];
        size_t label_len = strnlen(probe->label, sizeof(probe->label));

        if (label_len == 0 || label_len == sizeof(probe->label) ||
            probe->size_bytes == 0 ||
            probe->offset_bytes % ps != 0 || probe->size_bytes % ps != 0 ||
            probe->offset_bytes > config->window.arena_bytes ||
            probe->size_bytes > config->window.arena_bytes - probe->offset_bytes) {
            return -EINVAL;
        }
        for (size_t ch_index = 0; ch_index < label_len; ++ch_index) {
            unsigned char ch = (unsigned char)probe->label[ch_index];
            bool ascii_alnum = (ch >= '0' && ch <= '9') ||
                (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z');

            if (!ascii_alnum && ch != '_' && ch != '-' && ch != '.') {
                return -EINVAL;
            }
        }
    }
    return finalize_thread_counts(config);
}

static int parse_placement_spec(const char *value, struct mbench_numa_config *placement)
{
    if (!value || !placement) {
        return -EINVAL;
    }

    const char *colon = strchr(value, ':');
    char kind_buf[32];
    if (colon == NULL) {
        size_t len = strlen(value);
        if (len == 0 || len >= sizeof(kind_buf)) {
            return -EINVAL;
        }
        memcpy(kind_buf, value, len + 1);
        if (strcasecmp(kind_buf, "none") == 0) {
            placement->kind = MBENCH_PLACEMENT_NONE;
            placement->nodes.count = 0;
            placement->local_node = -1;
            placement->remote_node = -1;
            placement->window_split_local_bytes = 0;
            placement->arena_split_local_bytes = 0;
            return 0;
        }
        return -EINVAL;
    }

    size_t kind_len = (size_t)(colon - value);
    if (kind_len == 0 || kind_len >= sizeof(kind_buf)) {
        return -EINVAL;
    }
    memcpy(kind_buf, value, kind_len);
    kind_buf[kind_len] = '\0';

    const char *node_spec = colon + 1;
    if (strcasecmp(kind_buf, "bind") == 0) {
        placement->kind = MBENCH_PLACEMENT_BIND;
    } else if (strcasecmp(kind_buf, "interleave") == 0) {
        placement->kind = MBENCH_PLACEMENT_INTERLEAVE;
    } else if (strcasecmp(kind_buf, "preferred") == 0) {
        placement->kind = MBENCH_PLACEMENT_PREFERRED;
    } else if (strcasecmp(kind_buf, "split") == 0) {
        placement->kind = MBENCH_PLACEMENT_SPLIT;
    } else if (strcasecmp(kind_buf, "window-split") == 0 ||
               strcasecmp(kind_buf, "windowsplit") == 0) {
        placement->kind = MBENCH_PLACEMENT_WINDOW_SPLIT;
    } else if (strcasecmp(kind_buf, "arena-split") == 0) {
        placement->kind = MBENCH_PLACEMENT_ARENA_SPLIT;
    } else {
        return -EINVAL;
    }

    int rc = parse_node_list(node_spec, &placement->nodes);
    if (rc != 0) {
        return rc;
    }

    placement->local_node = (placement->nodes.count > 0) ? placement->nodes.nodes[0] : -1;
    placement->remote_node = (placement->nodes.count > 1) ? placement->nodes.nodes[1] : -1;
    return 0;
}

int mbench_placement_from_string(const char *value,
                                 struct mbench_numa_config *placement)
{
    if (!value || !placement) {
        return -EINVAL;
    }

    return parse_placement_spec(value, placement);
}

void mbench_print_usage(FILE *out, const char *progname)
{
    fprintf(out,
            "Usage: %s [options]\n"
            "\n"
            "Core options:\n"
            "  --mode pc|bw|mix|skewed-hotset|irregular-index\n"
            "  --arena-size BYTES|K|M|G\n"
            "  --window-size BYTES|K|M|G\n"
            "  --window-offset BYTES|K|M|G\n"
            "  --move-policy fixed|pingpong|sweep|random\n"
            "  --move-step BYTES|K|M|G\n"
            "  --move-min-offset BYTES|K|M|G\n"
            "  --move-max-offset BYTES|K|M|G (0 means arena max)\n"
            "  --duration N\n"
            "  --duration-ms N\n"
            "  --sample-ms N\n"
            "  --move-interval-ms N\n"
            "  timing note: non-phase runs ignore duration knobs and use a fixed 20s warmup + 200s measured phase\n"
            "  --phase-preset none|friendly-unfriendly|tail-hotset-sparse16|tail-hotset-sparse24|sparse24-tail-hotset|skew4g-sparse64|mulshift4g-sparse24|mulshift4g-sparse64|sparse64-mulshift4g|sparse64-weighted8g|sparse60-disjoint8g|sparse60-disjoint28g|gups60-disjoint28g|gups60-disjoint32g|gups60-disjoint36g|gups60-disjoint38g|gups60-disjoint40g|gups60-disjoint48g|mulshift4g-rot-sparse24|mulshift4g-rot-sparse64|mulshift4g-rot-move16g3s|mulshift4g-block2m-sparse64|move15s4g-split32|move15s4g-remote-split32|move60s4g-remote-split32|fixed4g-remote-split32|fixed8g-remote-split32\n"
            "  --phase-ms N\n"
            "  --phase-repeat N\n"
            "  --phase-duration-ms N\n"
            "  --phase1-target-ops N (fixed work for phase 1 of every repeated pair)\n"
            "  --phase2-target-ops N (fixed work for phase 2; set both phase targets or neither)\n"
            "  --phase-boundary-probe LABEL:OFFSET:SIZE (repeatable; query one page per 1 MiB after phase 1)\n"
            "  --placement none|bind:N[,N...]|interleave:N[,N...]|preferred:N|split:N,N|window-split:N,N|arena-split:N,N\n"
            "  --window-split-local BYTES|K|M|G (override first node bytes for window-split)\n"
            "  --arena-split-local BYTES|K|M|G (required local prefix for arena-split)\n"
            "  --threads N\n"
            "  --pc-threads N\n"
            "  --bw-threads N\n"
            "  --pc-chains N\n"
            "  --pc-pattern random|stride\n"
            "  --ops-per-pass N\n"
            "  --target-ops N (non-phase measured run stops after at least N completed ops)\n"
            "  --pause-ns N\n"
            "  --bw-kernel read|write|copy|triad\n"
            "  --bw-stride N\n"
            "  --bw-block BYTES|K|M|G\n"
            "  --bw-shared-window (all BW threads scan the full window)\n"
            "  --hotset-pages N\n"
            "  --hot-prob-pct 0..100\n"
            "  --hotset-read-pct 0..100\n"
            "  --hotset-write-pct 0..100\n"
            "  --hotset-rmw-pct 0..100 (read+write+rmw must sum to 100)\n"
            "  --hotset-index-mode xorshift|mulshift\n"
            "  --prefault-node N (first-touch entire arena on node N, then reset policy)\n"
            "  --hotset-prefault-node N (first-touch hotset/window on node N, then reset policy)\n"
            "  --hotset-shared-window (all hotset threads access the full window)\n"
            "  --hotset-tail (place the hot pages at the end of the window)\n"
            "  --hotset-background-pages N (tail mode: limit background to first N pages)\n"
            "  --index-kernel gather|scatter|rmw\n"
            "  --index-distribution uniform|zipf|clustered|segmented\n"
            "  --index-zipf-alpha FLOAT\n"
            "  --index-cluster-size BYTES|K|M|G\n"
            "  --index-cluster-span-ops N\n"
            "  --index-segments N\n"
            "  --index-segment-span-ops N\n"
            "  --hugepage none|thp|2m|1g\n"
            "  --seed U64\n"
            "  --prefault / --no-prefault\n"
            "  --csv / --quiet / --no-summary\n",
            progname ? progname : "mbench");
}

void mbench_config_dump(FILE *out, const struct mbench_config *config)
{
    fprintf(out,
            "mode=%s bw_kernel=%s hugepage=%s prefault=%d prefault_node=%d seed=%llu\n"
            "arena_bytes=%zu window_bytes=%zu offset_bytes=%zu move_step_bytes=%zu move_min_offset_bytes=%zu move_max_offset_bytes=%zu move_policy=%s\n"
            "duration_ms=%u sample_ms=%u move_interval_ms=%u csv=%d quiet=%d emit_summary=%d\n"
            "ops_per_pass=%llu target_ops=%llu pause_ns=%llu pc_pattern=%s bw_stride=%u bw_block_bytes=%zu bw_shared_window=%d hotset_pages=%u hotset_background_pages=%u hot_prob_pct=%u hotset_read_pct=%u hotset_write_pct=%u hotset_rmw_pct=%u hotset_index_mode=%s hotset_prefault_node=%d hotset_shared_window=%d hotset_tail=%d\n"
            "index_kernel=%s index_distribution=%s index_zipf_alpha=%.3f index_cluster_bytes=%zu index_cluster_span_ops=%u index_segments=%u index_segment_span_ops=%u\n"
            "placement=%s nodes=",
            mbench_mode_name(config->mode),
            mbench_bw_kernel_name(config->bw_kernel),
            mbench_hugepage_name(config->hugepage),
            config->prefault ? 1 : 0,
            config->prefault_node,
            (unsigned long long)config->seed,
            config->window.arena_bytes,
            config->window.window_bytes,
            config->window.offset_bytes,
            config->window.move_step_bytes,
            config->window.move_min_offset_bytes,
            config->window.move_max_offset_bytes,
            mbench_move_policy_name(config->window.move_policy),
            config->timing.duration_ms,
            config->timing.sample_ms,
            config->timing.move_interval_ms,
            config->report.csv ? 1 : 0,
            config->report.quiet ? 1 : 0,
            config->report.emit_summary ? 1 : 0,
            (unsigned long long)config->request.ops_per_pass,
            (unsigned long long)config->request.target_ops,
            (unsigned long long)config->request.pause_ns,
            mbench_pc_pattern_name(config->threads.pc_pattern),
            config->bw_pattern.stride_elements,
            config->bw_pattern.block_bytes,
            config->bw_pattern.shared_window ? 1 : 0,
            config->hotset.hotset_pages,
            config->hotset.background_pages,
            config->hotset.hot_prob_pct,
            config->hotset.read_pct,
            config->hotset.write_pct,
            config->hotset.rmw_pct,
            mbench_hotset_index_mode_name(config->hotset.index_mode),
            config->hotset.prefault_node,
            config->hotset.shared_window ? 1 : 0,
            config->hotset.tail ? 1 : 0,
            mbench_index_kernel_name(config->irregular.kernel),
            mbench_index_distribution_name(config->irregular.distribution),
            config->irregular.zipf_alpha,
            config->irregular.cluster_bytes,
            config->irregular.cluster_span_ops,
            config->irregular.segment_count,
            config->irregular.segment_span_ops,
            mbench_placement_name(config->placement.kind));
    for (size_t i = 0; i < config->placement.nodes.count; ++i) {
        fprintf(out, "%s%d", (i == 0) ? "" : ",", config->placement.nodes.nodes[i]);
    }
    fprintf(out,
            "\ntotal_threads=%d pc_threads=%d bw_threads=%d pc_chains=%d local_node=%d remote_node=%d window_split_local_bytes=%zu arena_split_local_bytes=%zu strict=%d\n",
            config->threads.total_threads,
            config->threads.pc_threads,
            config->threads.bw_threads,
            config->threads.pc_chains,
            config->placement.local_node,
            config->placement.remote_node,
            config->placement.window_split_local_bytes,
            config->placement.arena_split_local_bytes,
            config->placement.strict ? 1 : 0);
    if (mbench_phase_enabled(config)) {
        fprintf(out,
                "phase_preset=%s phase_repeat=%u phase_duration_ms=%u phase1_target_ops=%llu phase2_target_ops=%llu phase_count=%zu\n",
                mbench_phase_preset_name(config->phase.preset),
                config->phase.repeat,
                config->phase.duration_ms,
                (unsigned long long)config->phase.phase1_target_ops,
                (unsigned long long)config->phase.phase2_target_ops,
                mbench_phase_total_count(config));
        if (config->phase.boundary_probe_count > 0) {
            fprintf(out,
                    "phase_boundary_probe_count=%zu\n",
                    config->phase.boundary_probe_count);
        }
        for (size_t i = 0; i < config->phase.boundary_probe_count; ++i) {
            const struct mbench_residency_probe_config *probe =
                &config->phase.boundary_probes[i];

            fprintf(out,
                    "phase_boundary_probe label=%s offset_bytes=%zu size_bytes=%zu stride_bytes=%llu\n",
                    probe->label,
                    probe->offset_bytes,
                    probe->size_bytes,
                    (unsigned long long)MBENCH_PHASE_BOUNDARY_PROBE_STRIDE);
        }
    }
}

int mbench_config_parse(struct mbench_config *config, int argc, char **argv)
{
    if (!config) {
        return -EINVAL;
    }

    mbench_config_init(config);

    for (int i = 1; i < argc; ++i) {
        const char *arg = argv[i];
        if (strcmp(arg, "--help") == 0 || strcmp(arg, "-h") == 0) {
            mbench_print_usage(stdout, argc > 0 ? argv[0] : "mbench");
            return 1;
        } else if (strncmp(arg, "--mode", 6) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value || mbench_mode_from_string(value, &config->mode) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--arena-size", 12) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value || mbench_parse_size_bytes(value, &config->window.arena_bytes) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--window-size", 13) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value || mbench_parse_size_bytes(value, &config->window.window_bytes) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--window-offset", 15) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value || mbench_parse_size_bytes(value, &config->window.offset_bytes) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--move-step", 11) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value || mbench_parse_size_bytes(value, &config->window.move_step_bytes) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--move-min-offset", 17) == 0 &&
                   (arg[17] == '\0' || arg[17] == '=')) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value ||
                mbench_parse_size_bytes(value, &config->window.move_min_offset_bytes) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--move-max-offset", 17) == 0 &&
                   (arg[17] == '\0' || arg[17] == '=')) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value ||
                mbench_parse_size_bytes(value, &config->window.move_max_offset_bytes) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--move-policy", 13) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value || mbench_move_policy_from_string(value, &config->window.move_policy) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--duration-ms", 13) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value || mbench_parse_u32(value, &config->timing.duration_ms) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--sample-ms", 11) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value || mbench_parse_u32(value, &config->timing.sample_ms) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--move-interval-ms", 18) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value || mbench_parse_u32(value, &config->timing.move_interval_ms) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--phase-preset", 14) == 0 &&
                   (arg[14] == '\0' || arg[14] == '=')) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value || mbench_phase_preset_from_string(value, &config->phase.preset) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--phase-repeat", 14) == 0 &&
                   (arg[14] == '\0' || arg[14] == '=')) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value || mbench_parse_u32(value, &config->phase.repeat) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--phase1-target-ops", 19) == 0 &&
                   (arg[19] == '\0' || arg[19] == '=')) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value || mbench_parse_u64(value, &config->phase.phase1_target_ops) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--phase2-target-ops", 19) == 0 &&
                   (arg[19] == '\0' || arg[19] == '=')) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value || mbench_parse_u64(value, &config->phase.phase2_target_ops) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--phase-boundary-probe", 22) == 0 &&
                   (arg[22] == '\0' || arg[22] == '=')) {
            const char *value = option_value(&i, argc, argv, arg);
            size_t probe_index = config->phase.boundary_probe_count;
            int parse_rc;

            if (!value) {
                return -EINVAL;
            }
            if (probe_index >= MBENCH_MAX_PHASE_BOUNDARY_PROBES) {
                return -E2BIG;
            }
            parse_rc = mbench_parse_residency_probe(
                value, &config->phase.boundary_probes[probe_index]);
            if (parse_rc != 0) {
                return parse_rc;
            }
            config->phase.boundary_probe_count++;
        } else if ((strncmp(arg, "--phase-ms", 10) == 0 && (arg[10] == '\0' || arg[10] == '=')) ||
                   (strncmp(arg, "--phase-duration-ms", 19) == 0 &&
                    (arg[19] == '\0' || arg[19] == '='))) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value || mbench_parse_u32(value, &config->phase.duration_ms) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--duration", 10) == 0 && (arg[10] == '\0' || arg[10] == '=')) {
            const char *value = option_value(&i, argc, argv, arg);
            uint32_t seconds = 0;
            if (!value || mbench_parse_u32(value, &seconds) != 0) {
                return -EINVAL;
            }
            if (seconds > UINT32_MAX / 1000U) {
                return -ERANGE;
            }
            config->timing.duration_ms = seconds * 1000U;
        } else if (strncmp(arg, "--placement", 11) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value || mbench_placement_from_string(value, &config->placement) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--window-split-local", 20) == 0 &&
                   (arg[20] == '\0' || arg[20] == '=')) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value ||
                mbench_parse_size_bytes(value, &config->placement.window_split_local_bytes) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--arena-split-local", 19) == 0 &&
                   (arg[19] == '\0' || arg[19] == '=')) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value ||
                mbench_parse_size_bytes(value, &config->placement.arena_split_local_bytes) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--pc-threads", 12) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            uint32_t tmp = 0;
            if (!value || mbench_parse_u32(value, &tmp) != 0) {
                return -EINVAL;
            }
            config->threads.pc_threads = (int)tmp;
        } else if (strncmp(arg, "--bw-threads", 12) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            uint32_t tmp = 0;
            if (!value || mbench_parse_u32(value, &tmp) != 0) {
                return -EINVAL;
            }
            config->threads.bw_threads = (int)tmp;
        } else if (strncmp(arg, "--threads", 9) == 0 && (arg[9] == '\0' || arg[9] == '=')) {
            const char *value = option_value(&i, argc, argv, arg);
            uint32_t tmp = 0;
            if (!value || mbench_parse_u32(value, &tmp) != 0) {
                return -EINVAL;
            }
            config->threads.total_threads = (int)tmp;
        } else if (strncmp(arg, "--pc-chains", 11) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            uint32_t tmp = 0;
            if (!value || mbench_parse_u32(value, &tmp) != 0) {
                return -EINVAL;
            }
            config->threads.pc_chains = (int)tmp;
        } else if (strncmp(arg, "--pc-pattern", 12) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value || mbench_pc_pattern_from_string(value, &config->threads.pc_pattern) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--ops-per-pass", 14) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value || mbench_parse_u64(value, &config->request.ops_per_pass) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--target-ops", 12) == 0 &&
                   (arg[12] == '\0' || arg[12] == '=')) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value || mbench_parse_u64(value, &config->request.target_ops) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--pause-ns", 10) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value || mbench_parse_u64(value, &config->request.pause_ns) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--bw-kernel", 11) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value || mbench_bw_kernel_from_string(value, &config->bw_kernel) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--bw-stride", 11) == 0 && (arg[11] == '\0' || arg[11] == '=')) {
            const char *value = option_value(&i, argc, argv, arg);
            uint32_t tmp = 0;
            if (!value || mbench_parse_u32(value, &tmp) != 0) {
                return -EINVAL;
            }
            config->bw_pattern.stride_elements = tmp;
        } else if ((strncmp(arg, "--bw-block", 10) == 0 && (arg[10] == '\0' || arg[10] == '=')) ||
                   strncmp(arg, "--bw-block-size", 15) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value || mbench_parse_size_bytes(value, &config->bw_pattern.block_bytes) != 0) {
                return -EINVAL;
            }
        } else if (strcmp(arg, "--bw-shared-window") == 0) {
            config->bw_pattern.shared_window = true;
        } else if (strncmp(arg, "--hotset-pages", 14) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            uint32_t tmp = 0;
            if (!value || mbench_parse_u32(value, &tmp) != 0) {
                return -EINVAL;
            }
            config->hotset.hotset_pages = tmp;
        } else if (strncmp(arg, "--hot-prob-pct", 14) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            uint32_t tmp = 0;
            if (!value || mbench_parse_u32(value, &tmp) != 0) {
                return -EINVAL;
            }
            config->hotset.hot_prob_pct = tmp;
        } else if (strncmp(arg, "--hotset-read-pct", 17) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            uint32_t tmp = 0;
            if (!value || mbench_parse_u32(value, &tmp) != 0) {
                return -EINVAL;
            }
            config->hotset.read_pct = tmp;
        } else if (strncmp(arg, "--hotset-write-pct", 18) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            uint32_t tmp = 0;
            if (!value || mbench_parse_u32(value, &tmp) != 0) {
                return -EINVAL;
            }
            config->hotset.write_pct = tmp;
        } else if (strncmp(arg, "--hotset-rmw-pct", 16) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            uint32_t tmp = 0;
            if (!value || mbench_parse_u32(value, &tmp) != 0) {
                return -EINVAL;
            }
            config->hotset.rmw_pct = tmp;
        } else if (strncmp(arg, "--hotset-index-mode", 19) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value ||
                mbench_hotset_index_mode_from_string(value, &config->hotset.index_mode) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--hotset-prefault-node", 22) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            unsigned long long tmp = 0;
            if (!value || parse_unsigned_suffix(value, &tmp) != 0 ||
                tmp >= MBENCH_MAX_NUMA_NODES) {
                return -EINVAL;
            }
            config->hotset.prefault_node = (int)tmp;
        } else if (strcmp(arg, "--hotset-shared-window") == 0) {
            config->hotset.shared_window = true;
        } else if (strcmp(arg, "--hotset-tail") == 0) {
            config->hotset.tail = true;
        } else if (strncmp(arg, "--hotset-background-pages", 25) == 0 &&
                   (arg[25] == '\0' || arg[25] == '=')) {
            const char *value = option_value(&i, argc, argv, arg);
            uint32_t tmp = 0;
            if (!value || mbench_parse_u32(value, &tmp) != 0) {
                return -EINVAL;
            }
            config->hotset.background_pages = tmp;
        } else if (strncmp(arg, "--index-kernel", 14) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value || mbench_index_kernel_from_string(value, &config->irregular.kernel) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--index-distribution", 20) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value ||
                mbench_index_distribution_from_string(value, &config->irregular.distribution) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--index-zipf-alpha", 18) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value || mbench_parse_double(value, &config->irregular.zipf_alpha) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--index-cluster-size", 20) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value || mbench_parse_size_bytes(value, &config->irregular.cluster_bytes) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--index-cluster-span-ops", 24) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            uint32_t tmp = 0;
            if (!value || mbench_parse_u32(value, &tmp) != 0) {
                return -EINVAL;
            }
            config->irregular.cluster_span_ops = tmp;
        } else if (strncmp(arg, "--index-segments", 16) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            uint32_t tmp = 0;
            if (!value || mbench_parse_u32(value, &tmp) != 0) {
                return -EINVAL;
            }
            config->irregular.segment_count = tmp;
        } else if (strncmp(arg, "--index-segment-span-ops", 24) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            uint32_t tmp = 0;
            if (!value || mbench_parse_u32(value, &tmp) != 0) {
                return -EINVAL;
            }
            config->irregular.segment_span_ops = tmp;
        } else if (strncmp(arg, "--hugepage", 10) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value || mbench_hugepage_from_string(value, &config->hugepage) != 0) {
                return -EINVAL;
            }
        } else if (strncmp(arg, "--seed", 6) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            if (!value || mbench_parse_u64(value, &config->seed) != 0) {
                return -EINVAL;
            }
        } else if (strcmp(arg, "--prefault") == 0) {
            config->prefault = true;
        } else if (strncmp(arg, "--prefault-node", 15) == 0) {
            const char *value = option_value(&i, argc, argv, arg);
            unsigned long long tmp = 0;
            if (!value || parse_unsigned_suffix(value, &tmp) != 0 ||
                tmp >= MBENCH_MAX_NUMA_NODES) {
                return -EINVAL;
            }
            config->prefault_node = (int)tmp;
        } else if (strcmp(arg, "--no-prefault") == 0) {
            config->prefault = false;
        } else if (strcmp(arg, "--csv") == 0) {
            config->report.csv = true;
        } else if (strcmp(arg, "--quiet") == 0) {
            config->report.quiet = true;
        } else if (strcmp(arg, "--no-summary") == 0) {
            config->report.emit_summary = false;
        } else {
            return -EINVAL;
        }
    }

    return mbench_config_validate(config);
}
