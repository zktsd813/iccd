#define _GNU_SOURCE

#include "mbench.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define MIB (1024ULL * 1024ULL)

static int expect_true(int condition, const char *message)
{
    if (condition) {
        return 0;
    }
    fprintf(stderr, "test_phase_boundary_probe: %s\n", message);
    return 1;
}

static void init_phase_config(struct mbench_config *config)
{
    mbench_config_init(config);
    config->window.arena_bytes = 64ULL * MIB;
    config->window.window_bytes = 64ULL * MIB;
    config->phase.preset = MBENCH_PHASE_PRESET_SPARSE64_WEIGHTED8G;
}

static int test_probe_parser(void)
{
    struct mbench_residency_probe_config probe;
    int failed = 0;

    failed |= expect_true(
        mbench_parse_residency_probe("local_background:0:24G", &probe) == 0 &&
        strcmp(probe.label, "local_background") == 0 &&
        probe.offset_bytes == 0 && probe.size_bytes == 24ULL * 1024ULL * MIB,
        "valid label, zero offset, and suffixed size must parse");
    failed |= expect_true(
        mbench_parse_residency_probe("remote-hotset:60G:4G", &probe) == 0 &&
        strcmp(probe.label, "remote-hotset") == 0 &&
        probe.offset_bytes == 60ULL * 1024ULL * MIB &&
        probe.size_bytes == 4ULL * 1024ULL * MIB,
        "a second generic region must parse");
    failed |= expect_true(
        mbench_parse_residency_probe("bad label:0:4M", &probe) == -EINVAL,
        "labels with whitespace must be rejected");
    failed |= expect_true(
        mbench_parse_residency_probe(
            "abcdefghijklmnopqrstuvwxyzabcdef:0:4M", &probe) == -EINVAL,
        "labels must fit the fixed machine-readable field");
    failed |= expect_true(
        mbench_parse_residency_probe("missing-size:0", &probe) == -EINVAL,
        "specifications must contain exactly two colons");
    failed |= expect_true(
        mbench_parse_residency_probe("extra:0:4M:tail", &probe) == -EINVAL,
        "specifications with extra fields must be rejected");
    failed |= expect_true(
        mbench_parse_residency_probe("empty::4M", &probe) == -EINVAL,
        "empty offsets must be rejected");
    failed |= expect_true(
        mbench_parse_residency_probe("zero:0:0", &probe) == -EINVAL,
        "zero-length probes must be rejected");
    return failed;
}

static int test_probe_cli_and_bounds(void)
{
    char *argv[] = {
        "mbench",
        "--phase-preset", "sparse64-weighted8g",
        "--arena-size", "64M",
        "--window-size", "64M",
        "--phase-boundary-probe", "local_background:0:24M",
        "--phase-boundary-probe=remote_hotset:60M:4M",
    };
    struct mbench_config config;
    int failed = 0;

    failed |= expect_true(
        mbench_config_parse(&config, (int)(sizeof(argv) / sizeof(argv[0])), argv) == 0 &&
        config.phase.boundary_probe_count == 2U &&
        strcmp(config.phase.boundary_probes[0].label, "local_background") == 0 &&
        config.phase.boundary_probes[0].size_bytes == 24ULL * MIB &&
        strcmp(config.phase.boundary_probes[1].label, "remote_hotset") == 0 &&
        config.phase.boundary_probes[1].offset_bytes == 60ULL * MIB,
        "the CLI must retain repeated probe specifications");

    init_phase_config(&config);
    config.phase.boundary_probe_count = 1U;
    failed |= expect_true(
        mbench_parse_residency_probe(
            "outside:63M:2M", &config.phase.boundary_probes[0]) == 0 &&
        mbench_config_validate(&config) == -EINVAL,
        "a probe extending past the arena must be rejected");

    init_phase_config(&config);
    config.phase.boundary_probe_count = 1U;
    failed |= expect_true(
        mbench_parse_residency_probe(
            "unaligned:1:4096", &config.phase.boundary_probes[0]) == 0 &&
        mbench_config_validate(&config) == -EINVAL,
        "probe offsets must be page aligned");

    mbench_config_init(&config);
    config.phase.boundary_probe_count = 1U;
    failed |= expect_true(
        mbench_parse_residency_probe(
            "no_phase:0:4M", &config.phase.boundary_probes[0]) == 0 &&
        mbench_config_validate(&config) == -EINVAL,
        "a boundary probe requires a phase preset");

    init_phase_config(&config);
    config.phase.boundary_probe_count = MBENCH_MAX_PHASE_BOUNDARY_PROBES + 1U;
    failed |= expect_true(mbench_config_validate(&config) == -E2BIG,
                          "the bounded probe list must reject excess entries");

    init_phase_config(&config);
    memset(config.phase.boundary_probes[0].label, 'x',
           sizeof(config.phase.boundary_probes[0].label));
    config.phase.boundary_probes[0].size_bytes = 4ULL * MIB;
    config.phase.boundary_probe_count = 1U;
    failed |= expect_true(mbench_config_validate(&config) == -EINVAL,
                          "manually supplied labels must be NUL terminated");

    init_phase_config(&config);
    failed |= expect_true(mbench_config_validate(&config) == 0 &&
                          config.phase.boundary_probe_count == 0,
                          "the default configuration must remain probe-free");
    return failed;
}

static int test_sampled_self_query(void)
{
    const size_t stride = (size_t)MBENCH_PHASE_BOUNDARY_PROBE_STRIDE;
    const size_t length = 2U * stride;
    long page_size_raw = sysconf(_SC_PAGESIZE);
    size_t page_size;
    size_t page_count;
    unsigned char *resident_before;
    unsigned char *resident_after;
    void *lazy;
    void *touched;
    int status[2];
    int rc;
    int failed = 0;

    if (!mbench_numa_supported()) {
        fprintf(stderr, "test_phase_boundary_probe: NUMA query test skipped (no numaif)\n");
        return 0;
    }
    if (page_size_raw <= 0) {
        return expect_true(0, "page size query must succeed");
    }
    page_size = (size_t)page_size_raw;
    page_count = length / page_size;
    resident_before = calloc(page_count, sizeof(*resident_before));
    resident_after = calloc(page_count, sizeof(*resident_after));
    if (!resident_before || !resident_after) {
        free(resident_before);
        free(resident_after);
        return expect_true(0, "residency vectors must allocate");
    }

    lazy = mmap(NULL, length, PROT_READ | PROT_WRITE,
                MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (lazy == MAP_FAILED) {
        free(resident_before);
        free(resident_after);
        return expect_true(0, "lazy mapping must allocate");
    }
    failed |= expect_true(mincore(lazy, length, resident_before) == 0,
                          "initial mincore query must succeed");
    rc = mbench_query_sampled_range_nodes(lazy, length, stride, status, 2U);
    failed |= expect_true(mincore(lazy, length, resident_after) == 0,
                          "post-query mincore query must succeed");
    failed |= expect_true(
        (resident_before[0] & 1U) == 0 &&
        (resident_before[stride / page_size] & 1U) == 0 &&
        (resident_after[0] & 1U) == 0 &&
        (resident_after[stride / page_size] & 1U) == 0,
        "a sampled location query must not fault untouched pages");
    (void)rc;
    munmap(lazy, length);

    touched = mmap(NULL, length, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (touched == MAP_FAILED) {
        free(resident_before);
        free(resident_after);
        return failed | expect_true(0, "touched mapping must allocate");
    }
    ((volatile unsigned char *)touched)[0] = 1U;
    ((volatile unsigned char *)touched)[stride] = 1U;
    failed |= expect_true(
        mbench_query_sampled_range_nodes(touched, length, stride, status, 1U) ==
            -EINVAL,
        "the query must reject an undersized status vector");
    failed |= expect_true(
        mbench_query_sampled_range_nodes((unsigned char *)touched + 1U,
                                         length, stride, status, 2U) == -EINVAL,
        "the query must reject an unaligned base address");
    rc = mbench_query_sampled_range_nodes(touched, length, stride, status, 2U);
    if (rc == -ENOSYS || rc == -EPERM || rc == -EACCES) {
        fprintf(stderr,
                "test_phase_boundary_probe: live node-status assertion skipped (%s)\n",
                strerror(-rc));
    } else {
        failed |= expect_true(rc == 0 && status[0] >= 0 && status[1] >= 0,
                              "self-query must report nodes for resident pages");
    }
    munmap(touched, length);
    free(resident_before);
    free(resident_after);
    return failed;
}

static uint64_t timespec_ns(const struct timespec *value)
{
    return (uint64_t)value->tv_sec * 1000000000ULL + (uint64_t)value->tv_nsec;
}

static int test_monotonic_clock_domain(void)
{
    struct timespec before = {0};
    struct timespec after = {0};
    uint64_t dispatch_start;
    uint64_t dispatch_complete;
    int failed = 0;

    failed |= expect_true(clock_gettime(CLOCK_MONOTONIC, &before) == 0,
                          "CLOCK_MONOTONIC must be readable before the helper");
    dispatch_start = mbench_clock_monotonic_ns();
    dispatch_complete = mbench_clock_monotonic_ns();
    failed |= expect_true(clock_gettime(CLOCK_MONOTONIC, &after) == 0,
                          "CLOCK_MONOTONIC must be readable after the helper");
    failed |= expect_true(
        dispatch_start >= timespec_ns(&before) &&
        dispatch_complete >= dispatch_start &&
        dispatch_complete <= timespec_ns(&after),
        "the cross-process timestamp helper must use CLOCK_MONOTONIC");
    return failed;
}

int main(void)
{
    int failed = 0;

    failed |= test_probe_parser();
    failed |= test_probe_cli_and_bounds();
    failed |= test_sampled_self_query();
    failed |= test_monotonic_clock_domain();
    return failed ? 1 : 0;
}
