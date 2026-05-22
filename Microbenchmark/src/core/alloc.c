#define _GNU_SOURCE

#include "mbench.h"

#include <errno.h>
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

#ifndef MAP_HUGE_SHIFT
#define MAP_HUGE_SHIFT 26
#endif

#ifndef MAP_HUGE_2MB
#define MAP_HUGE_2MB (21 << MAP_HUGE_SHIFT)
#endif

#ifndef MAP_HUGE_1GB
#define MAP_HUGE_1GB (30 << MAP_HUGE_SHIFT)
#endif

static size_t page_size(void)
{
    long ps = sysconf(_SC_PAGESIZE);
    if (ps <= 0) {
        return 4096U;
    }
    return (size_t)ps;
}

static int touch_range(struct mbench_arena *arena, size_t offset, size_t bytes)
{
    if (!arena || !arena->base || arena->bytes == 0) {
        return -EINVAL;
    }
    if (offset > arena->bytes || bytes > arena->bytes - offset) {
        return -EINVAL;
    }

    volatile unsigned char *ptr = (volatile unsigned char *)arena->base;
    for (size_t off = offset; off < offset + bytes; off += arena->page_size) {
        ptr[off] = 0;
    }
    return 0;
}

static int touch_pages(struct mbench_arena *arena)
{
    int rc = touch_range(arena, 0, arena->bytes);
    if (rc == 0) {
        arena->prefaulted = true;
    }
    return rc;
}

int mbench_arena_prefault(struct mbench_arena *arena)
{
    return touch_pages(arena);
}

static int set_thread_mempolicy_node(int node)
{
#if MBENCH_HAVE_NUMAIF
    if (node < 0 || node >= (int)(sizeof(unsigned long) * 8U)) {
        return -ERANGE;
    }

    unsigned long mask = 1UL << node;
    unsigned long maxnode = (unsigned long)(sizeof(unsigned long) * 8U);
    int rc = set_mempolicy(MPOL_BIND, &mask, maxnode);
    return rc == 0 ? 0 : -errno;
#else
    (void)node;
    return -ENOSYS;
#endif
}

static int reset_thread_mempolicy(void)
{
#if MBENCH_HAVE_NUMAIF
    int rc = set_mempolicy(MPOL_DEFAULT, NULL, 0);
    return rc == 0 ? 0 : -errno;
#else
    return -ENOSYS;
#endif
}

static size_t hot_bytes_for_window(const struct mbench_arena *arena,
                                   const struct mbench_config *config,
                                   size_t offset)
{
    if (!arena || !config || offset >= arena->bytes) {
        return 0;
    }

    size_t window_bytes = config->window.window_bytes;
    if (window_bytes > arena->bytes - offset) {
        window_bytes = arena->bytes - offset;
    }

    size_t window_pages = window_bytes / arena->page_size;
    size_t hot_pages = config->hotset.hotset_pages;
    if (hot_pages == 0 || hot_pages > window_pages) {
        hot_pages = window_pages;
    }

    size_t hot_bytes = hot_pages * arena->page_size;
    if (hot_bytes == 0 || hot_bytes > window_bytes) {
        hot_bytes = window_bytes;
    }
    return hot_bytes;
}

static int touch_hotset_move_range(struct mbench_arena *arena,
                                   const struct mbench_config *config)
{
    size_t offset = config->window.offset_bytes;
    size_t hot_bytes = hot_bytes_for_window(arena, config, offset);
    if (hot_bytes == 0) {
        return -EINVAL;
    }

    int rc = touch_range(arena, offset, hot_bytes);
    if (rc != 0 || config->window.move_policy == MBENCH_MOVE_FIXED) {
        return rc;
    }

    size_t min_offset = config->window.move_min_offset_bytes;
    size_t max_offset = config->window.move_max_offset_bytes;
    if (max_offset <= min_offset) {
        return 0;
    }
    if (min_offset >= arena->bytes) {
        return -EINVAL;
    }
    if (max_offset >= arena->bytes) {
        max_offset = arena->bytes - 1U;
    }

    size_t step = config->window.move_step_bytes;
    if (step == 0) {
        step = config->window.window_bytes;
    }
    if (step == 0) {
        step = arena->page_size;
    }

    for (size_t off = min_offset; off <= max_offset; ) {
        hot_bytes = hot_bytes_for_window(arena, config, off);
        if (hot_bytes == 0) {
            return -EINVAL;
        }
        rc = touch_range(arena, off, hot_bytes);
        if (rc != 0) {
            return rc;
        }
        if (max_offset - off < step) {
            break;
        }
        off += step;
    }

    return 0;
}

int mbench_arena_prefault_hotset_node(struct mbench_arena *arena,
                                      const struct mbench_config *config)
{
    if (!arena || !config || !arena->base || arena->bytes == 0 ||
        config->hotset.prefault_node < 0) {
        return -EINVAL;
    }
    if (config->window.offset_bytes >= arena->bytes ||
        config->window.window_bytes == 0) {
        return -EINVAL;
    }

    size_t hot_bytes = hot_bytes_for_window(arena, config,
                                            config->window.offset_bytes);
    if (hot_bytes == 0) {
        return -EINVAL;
    }

    int rc = set_thread_mempolicy_node(config->hotset.prefault_node);
    if (rc != 0) {
        return rc;
    }

    rc = touch_hotset_move_range(arena, config);
    int reset_rc = reset_thread_mempolicy();
    if (rc != 0) {
        return rc;
    }
    if (reset_rc != 0) {
        return reset_rc;
    }

    rc = touch_pages(arena);
    if (rc == 0) {
        arena->prefaulted = true;
    }
    return rc;
}

int mbench_arena_prefault_window_split(struct mbench_arena *arena,
                                       const struct mbench_config *config)
{
    if (!arena || !config || !arena->base || arena->bytes == 0 ||
        config->placement.kind != MBENCH_PLACEMENT_WINDOW_SPLIT ||
        config->placement.nodes.count < 2) {
        return -EINVAL;
    }
    if (config->window.offset_bytes >= arena->bytes ||
        config->window.window_bytes == 0) {
        return -EINVAL;
    }

    size_t offset = config->window.offset_bytes;
    size_t window_bytes = config->window.window_bytes;
    if (window_bytes > arena->bytes - offset) {
        window_bytes = arena->bytes - offset;
    }

    size_t local_bytes = config->placement.window_split_local_bytes;
    if (local_bytes == 0) {
        local_bytes = ((window_bytes / 2U) / arena->page_size) *
            arena->page_size;
    }
    size_t remote_bytes = window_bytes - local_bytes;
    if (local_bytes == 0 || remote_bytes == 0) {
        return -EINVAL;
    }

    int rc = set_thread_mempolicy_node(config->placement.nodes.nodes[0]);
    if (rc != 0) {
        return rc;
    }

    rc = touch_range(arena, offset, local_bytes);
    if (rc != 0) {
        (void)reset_thread_mempolicy();
        return rc;
    }

    rc = set_thread_mempolicy_node(config->placement.nodes.nodes[1]);
    if (rc != 0) {
        (void)reset_thread_mempolicy();
        return rc;
    }

    rc = touch_range(arena, offset + local_bytes, remote_bytes);
    int reset_rc = reset_thread_mempolicy();
    if (rc != 0) {
        return rc;
    }
    if (reset_rc != 0) {
        return reset_rc;
    }

    if (offset > 0) {
        rc = touch_range(arena, 0, offset);
        if (rc != 0) {
            return rc;
        }
    }

    size_t window_end = offset + window_bytes;
    if (window_end < arena->bytes) {
        rc = touch_range(arena, window_end, arena->bytes - window_end);
        if (rc != 0) {
            return rc;
        }
    }

    arena->prefaulted = true;
    return 0;
}

int mbench_arena_prefault_head_local_tail_remote(struct mbench_arena *arena,
                                                 const struct mbench_config *config)
{
    if (!arena || !config || !arena->base || arena->bytes == 0 ||
        config->placement.kind != MBENCH_PLACEMENT_WINDOW_SPLIT ||
        config->placement.nodes.count < 2 ||
        config->window.window_bytes == 0) {
        return -EINVAL;
    }

    size_t local_bytes = config->placement.window_split_local_bytes;
    if (local_bytes == 0) {
        local_bytes = ((config->window.window_bytes / 2U) /
                       arena->page_size) * arena->page_size;
    }
    if (local_bytes == 0 || local_bytes >= arena->bytes) {
        return -EINVAL;
    }

    int rc = set_thread_mempolicy_node(config->placement.nodes.nodes[0]);
    if (rc != 0) {
        return rc;
    }

    rc = touch_range(arena, 0, local_bytes);
    if (rc != 0) {
        (void)reset_thread_mempolicy();
        return rc;
    }

    rc = set_thread_mempolicy_node(config->placement.nodes.nodes[1]);
    if (rc != 0) {
        (void)reset_thread_mempolicy();
        return rc;
    }

    rc = touch_range(arena, local_bytes, arena->bytes - local_bytes);
    int reset_rc = reset_thread_mempolicy();
    if (rc != 0) {
        return rc;
    }
    if (reset_rc != 0) {
        return reset_rc;
    }

    arena->prefaulted = true;
    return 0;
}

int mbench_arena_init(struct mbench_arena *arena,
                      size_t bytes,
                      enum mbench_hugepage_kind hugepage,
                      bool prefault)
{
    if (!arena || bytes == 0) {
        return -EINVAL;
    }

    memset(arena, 0, sizeof(*arena));
    arena->page_size = page_size();
    arena->hugepage = hugepage;
    arena->bytes = mbench_align_up_size(bytes, arena->page_size);

    int flags = MAP_PRIVATE | MAP_ANONYMOUS;
    switch (hugepage) {
    case MBENCH_HUGEPAGE_NONE:
        break;
    case MBENCH_HUGEPAGE_THP:
        break;
    case MBENCH_HUGEPAGE_HUGETLB_2M:
        flags |= MAP_HUGETLB;
        flags |= MAP_HUGE_2MB;
        arena->bytes = mbench_align_up_size(arena->bytes, 2ULL * 1024ULL * 1024ULL);
        break;
    case MBENCH_HUGEPAGE_HUGETLB_1G:
        flags |= MAP_HUGETLB;
        flags |= MAP_HUGE_1GB;
        arena->bytes = mbench_align_up_size(arena->bytes, 1024ULL * 1024ULL * 1024ULL);
        break;
    default:
        return -EINVAL;
    }

    void *base = mmap(NULL, arena->bytes, PROT_READ | PROT_WRITE, flags, -1, 0);
    if (base == MAP_FAILED) {
        return -errno;
    }

    arena->base = base;
    if (hugepage == MBENCH_HUGEPAGE_THP) {
        (void)madvise(arena->base, arena->bytes, MADV_HUGEPAGE);
    } else if (hugepage == MBENCH_HUGEPAGE_NONE) {
        (void)madvise(arena->base, arena->bytes, MADV_NOHUGEPAGE);
    }

    if (prefault) {
        int rc = mbench_arena_prefault(arena);
        if (rc != 0) {
            munmap(arena->base, arena->bytes);
            memset(arena, 0, sizeof(*arena));
            return rc;
        }
    }

    return 0;
}

void mbench_arena_destroy(struct mbench_arena *arena)
{
    if (!arena || !arena->base || arena->bytes == 0) {
        return;
    }
    munmap(arena->base, arena->bytes);
    memset(arena, 0, sizeof(*arena));
}
