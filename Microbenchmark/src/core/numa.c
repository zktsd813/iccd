#define _GNU_SOURCE

#include "mbench.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#if defined(__has_include)
#  if __has_include(<numaif.h>)
#    include <numaif.h>
#    define MBENCH_HAVE_NUMAIF 1
#  else
#    define MBENCH_HAVE_NUMAIF 0
#  endif
#else
#  define MBENCH_HAVE_NUMAIF 0
#endif

static size_t page_size(void)
{
    long ps = sysconf(_SC_PAGESIZE);
    if (ps <= 0) {
        return 4096U;
    }
    return (size_t)ps;
}

static int build_mask(const struct mbench_node_list *nodes, unsigned long *mask)
{
    if (!nodes || !mask) {
        return -EINVAL;
    }

    *mask = 0;
    for (size_t i = 0; i < nodes->count; ++i) {
        int node = nodes->nodes[i];
        if (node < 0 || node >= (int)(sizeof(unsigned long) * 8U)) {
            return -ERANGE;
        }
        *mask |= (1UL << node);
    }
    return 0;
}

int mbench_numa_supported(void)
{
    return MBENCH_HAVE_NUMAIF ? 1 : 0;
}

static int bind_range(void *addr, size_t length, const struct mbench_node_list *nodes, int mode)
{
#if MBENCH_HAVE_NUMAIF
    if (!addr || length == 0 || !nodes || nodes->count == 0) {
        return -EINVAL;
    }

    unsigned long mask = 0;
    int rc = build_mask(nodes, &mask);
    if (rc != 0) {
        return rc;
    }

    unsigned long maxnode = (unsigned long)(sizeof(unsigned long) * 8U);
    rc = mbind(addr, length, mode, &mask, maxnode, 0);
    return rc == 0 ? 0 : -errno;
#else
    (void)addr;
    (void)length;
    (void)nodes;
    (void)mode;
    return -ENOSYS;
#endif
}

int mbench_apply_placement(const struct mbench_config *config,
                           const struct mbench_arena *arena)
{
    if (!config || !arena || !arena->base || arena->bytes == 0) {
        return -EINVAL;
    }
    if (config->placement.kind == MBENCH_PLACEMENT_NONE || config->placement.nodes.count == 0) {
        return 0;
    }

    switch (config->placement.kind) {
    case MBENCH_PLACEMENT_BIND:
        return bind_range(arena->base, arena->bytes, &config->placement.nodes, MPOL_BIND);
    case MBENCH_PLACEMENT_INTERLEAVE:
        return bind_range(arena->base, arena->bytes, &config->placement.nodes, MPOL_INTERLEAVE);
    case MBENCH_PLACEMENT_PREFERRED:
        return bind_range(arena->base, arena->bytes, &config->placement.nodes, MPOL_PREFERRED);
    case MBENCH_PLACEMENT_SPLIT:
        if (config->placement.nodes.count < 2) {
            return -EINVAL;
        }
        if (config->window.window_bytes == 0 || config->window.window_bytes > arena->bytes) {
            return -EINVAL;
        }
        {
            struct mbench_node_list local = { .count = 1 };
            struct mbench_node_list remote = { .count = 1 };
            local.nodes[0] = config->placement.nodes.nodes[0];
            remote.nodes[0] = config->placement.nodes.nodes[1];
            int rc = bind_range(arena->base,
                                config->window.window_bytes,
                                &local,
                                MPOL_BIND);
            if (rc != 0) {
                return rc;
            }
            size_t cold_bytes = arena->bytes - config->window.window_bytes;
            if (cold_bytes > 0) {
                rc = bind_range((unsigned char *)arena->base + config->window.window_bytes,
                                cold_bytes,
                                &remote,
                                MPOL_BIND);
            }
            return rc;
        }
    case MBENCH_PLACEMENT_WINDOW_SPLIT:
        return 0;
    case MBENCH_PLACEMENT_NONE:
    default:
        return 0;
    }
}

int mbench_move_range_to_nodes(void *addr,
                               size_t length,
                               const int *nodes,
                               size_t node_count)
{
#if MBENCH_HAVE_NUMAIF
    if (!addr || length == 0 || !nodes || node_count == 0) {
        return -EINVAL;
    }

    size_t ps = page_size();
    size_t npages = length / ps;
    if (npages == 0) {
        return 0;
    }

    void **pages = calloc(npages, sizeof(*pages));
    int *target = calloc(npages, sizeof(*target));
    int *status = calloc(npages, sizeof(*status));
    if (!pages || !target || !status) {
        free(pages);
        free(target);
        free(status);
        return -ENOMEM;
    }

    for (size_t i = 0; i < npages; ++i) {
        pages[i] = (unsigned char *)addr + i * ps;
        target[i] = nodes[(node_count == 1) ? 0 : (i % node_count)];
    }

    int rc = move_pages(0, npages, pages, target, status, MPOL_MF_MOVE);
    free(pages);
    free(target);
    free(status);
    return rc == 0 ? 0 : -errno;
#else
    (void)addr;
    (void)length;
    (void)nodes;
    (void)node_count;
    return -ENOSYS;
#endif
}

int mbench_move_range_to_node(void *addr, size_t length, int node)
{
    int target = node;
    return mbench_move_range_to_nodes(addr, length, &target, 1);
}

int mbench_query_range_nodes(void *addr,
                             size_t length,
                             int *status_out,
                             size_t status_count)
{
#if MBENCH_HAVE_NUMAIF
    if (!addr || !status_out || length == 0) {
        return -EINVAL;
    }

    size_t ps = page_size();
    size_t npages = length / ps;
    if (status_count < npages) {
        return -EINVAL;
    }

    void **pages = calloc(npages, sizeof(*pages));
    if (!pages) {
        return -ENOMEM;
    }

    for (size_t i = 0; i < npages; ++i) {
        pages[i] = (unsigned char *)addr + i * ps;
    }

    int rc = move_pages(0, npages, pages, NULL, status_out, 0);
    free(pages);
    return rc == 0 ? 0 : -errno;
#else
    (void)addr;
    (void)length;
    (void)status_out;
    (void)status_count;
    return -ENOSYS;
#endif
}
