#include "mbench.h"

#define MBENCH_BW_READ MBENCH_KERNEL_BW_READ
#define MBENCH_BW_WRITE MBENCH_KERNEL_BW_WRITE
#define MBENCH_BW_COPY MBENCH_KERNEL_BW_COPY
#define MBENCH_BW_TRIAD MBENCH_KERNEL_BW_TRIAD
#include "../src/kernels/mbench_kernels.h"
#undef MBENCH_BW_READ
#undef MBENCH_BW_WRITE
#undef MBENCH_BW_COPY
#undef MBENCH_BW_TRIAD

#include <errno.h>
#include <stdio.h>
#include <string.h>

#define GIB (1024ULL * 1024ULL * 1024ULL)

static int expect_true(int condition, const char *message)
{
    if (condition) {
        return 0;
    }
    fprintf(stderr, "test_weighted_phase: %s\n", message);
    return 1;
}

static size_t changed_words(const uint64_t *data, size_t begin, size_t end)
{
    size_t changed = 0;

    for (size_t i = begin; i < end; ++i) {
        if (data[i] != 0) {
            ++changed;
        }
    }
    return changed;
}

static int test_hotset_tail_selection(void)
{
    enum { TOTAL_PAGES = 16, PAGE_WORDS = 8, HOT_PAGES = 4 };
    uint64_t data[TOTAL_PAGES * PAGE_WORDS];
    struct mbench_skew_job job;
    const size_t cold_words = (TOTAL_PAGES - HOT_PAGES) * PAGE_WORDS;
    const size_t hot_words = HOT_PAGES * PAGE_WORDS;
    int failed = 0;

    memset(data, 0, sizeof(data));
    memset(&job, 0, sizeof(job));
    job.data = data;
    job.data_words = TOTAL_PAGES * PAGE_WORDS;
    job.page_words = PAGE_WORDS;
    job.hot_pages = HOT_PAGES;
    job.hot_prob_pct = 100U;
    job.write_pct = 100U;
    job.index_mode = MBENCH_SKEW_INDEX_XORSHIFT;
    job.hotset_tail = 1;
    job.ops = 4096U;
    job.seed = 1U;
    failed |= expect_true(mbench_run_skewed_hotset(&job) == 0,
                          "tail-hotset kernel run must succeed");
    failed |= expect_true(changed_words(data, 0, cold_words) == 0 &&
                          changed_words(data, cold_words, cold_words + hot_words) > 0,
                          "tail-hotset selection must confine hot writes to final pages");

    memset(data, 0, sizeof(data));
    memset(&job, 0, sizeof(job));
    job.data = data;
    job.data_words = TOTAL_PAGES * PAGE_WORDS;
    job.page_words = PAGE_WORDS;
    job.hot_pages = HOT_PAGES;
    job.hot_prob_pct = 100U;
    job.write_pct = 100U;
    job.index_mode = MBENCH_SKEW_INDEX_XORSHIFT;
    job.ops = 4096U;
    job.seed = 1U;
    failed |= expect_true(mbench_run_skewed_hotset(&job) == 0,
                          "default head-hotset kernel run must succeed");
    failed |= expect_true(changed_words(data, 0, hot_words) > 0 &&
                          changed_words(data, hot_words,
                                        TOTAL_PAGES * PAGE_WORDS) == 0,
                          "default selection must keep the hotset at the window head");

    memset(data, 0, sizeof(data));
    memset(&job, 0, sizeof(job));
    job.data = data;
    job.data_words = TOTAL_PAGES * PAGE_WORDS;
    job.page_words = PAGE_WORDS;
    job.hot_pages = HOT_PAGES;
    job.background_pages = 3U;
    job.hot_prob_pct = 0U;
    job.write_pct = 100U;
    job.index_mode = MBENCH_SKEW_INDEX_XORSHIFT;
    job.hotset_tail = 1;
    job.ops = 4096U;
    job.seed = 1U;
    failed |= expect_true(mbench_run_skewed_hotset(&job) == 0,
                          "limited-background kernel run must succeed");
    failed |= expect_true(changed_words(data, 0, 3U * PAGE_WORDS) > 0 &&
                          changed_words(data, 3U * PAGE_WORDS,
                                        cold_words) == 0 &&
                          changed_words(data, cold_words,
                                        cold_words + hot_words) == 0,
                          "background limit must skip the cold gap and tail hotset");

    job.background_pages = TOTAL_PAGES - HOT_PAGES + 1U;
    failed |= expect_true(mbench_run_skewed_hotset(&job) == -EINVAL,
                          "background limit must not exceed the cold range");
    job.background_pages = 3U;
    job.hotset_tail = 0;
    failed |= expect_true(mbench_run_skewed_hotset(&job) == -EINVAL,
                          "background limit must require tail-hotset mode");
    return failed;
}

static int test_background_pages_cli(void)
{
    struct mbench_config config;
    char *valid_argv[] = {
        "mbench",
        "--mode", "skewed-hotset",
        "--arena-size", "64M",
        "--window-size", "16M",
        "--hotset-pages", "1024",
        "--hotset-tail",
        "--hotset-background-pages", "512",
    };
    char *invalid_argv[] = {
        "mbench",
        "--mode", "skewed-hotset",
        "--arena-size", "64M",
        "--window-size", "16M",
        "--hotset-pages", "1024",
        "--hotset-background-pages", "512",
    };
    char *oversized_argv[] = {
        "mbench",
        "--mode", "skewed-hotset",
        "--arena-size", "64M",
        "--window-size", "16M",
        "--hotset-pages", "1024",
        "--hotset-tail",
        "--hotset-background-pages", "4000",
    };
    int failed = 0;

    mbench_config_init(&config);
    failed |= expect_true(
        mbench_config_parse(&config,
                            (int)(sizeof(valid_argv) / sizeof(valid_argv[0])),
                            valid_argv) == 0 &&
        config.hotset.background_pages == 512U,
        "background-page CLI must parse in tail mode");

    mbench_config_init(&config);
    failed |= expect_true(
        mbench_config_parse(&config,
                            (int)(sizeof(invalid_argv) / sizeof(invalid_argv[0])),
                            invalid_argv) == -EINVAL,
        "background-page CLI must reject non-tail mode");

    mbench_config_init(&config);
    failed |= expect_true(
        mbench_config_parse(&config,
                            (int)(sizeof(oversized_argv) /
                                  sizeof(oversized_argv[0])),
                            oversized_argv) == -EINVAL,
        "background-page CLI must reject limits larger than the cold range");
    return failed;
}

int main(void)
{
    struct mbench_config config;
    struct mbench_phase phase;
    enum mbench_phase_preset preset;
    int failed = 0;

    mbench_config_init(&config);
    config.window.arena_bytes = 64ULL * GIB;
    config.window.window_bytes = 64ULL * GIB;
    config.threads.total_threads = 32;
    config.threads.bw_threads = 32;
    config.phase.phase1_target_ops = 1234567ULL;
    config.phase.phase2_target_ops = 7654321ULL;

    failed |= expect_true(
        mbench_phase_preset_from_string("sparse64-weighted8g", &preset) == 0,
        "new preset must parse");
    config.phase.preset = preset;
    failed |= expect_true(
        strcmp(mbench_phase_preset_name(config.phase.preset),
               "sparse64-weighted8g") == 0,
        "new preset must have a stable name");
    failed |= expect_true(mbench_phase_total_count(&config) == 2U,
                          "new preset must contain one phase pair");

    failed |= expect_true(mbench_phase_build(&config, 0, &phase) == 0,
                          "phase 1 must build");
    failed |= expect_true(phase.target_ops == config.phase.phase1_target_ops,
                          "phase 1 must retain its fixed-work target");
    failed |= expect_true(phase.config.mode == MBENCH_MODE_BW &&
                          phase.config.bw_kernel == MBENCH_BW_READ,
                          "phase 1 must be a bandwidth read");
    failed |= expect_true(phase.config.window.window_bytes == 64ULL * GIB &&
                          phase.config.window.offset_bytes == 0,
                          "phase 1 must cover the full 64 GiB arena");
    failed |= expect_true(phase.config.bw_pattern.stride_elements == 512U &&
                          phase.config.bw_pattern.block_bytes == 4096U &&
                          !phase.config.bw_pattern.shared_window,
                          "phase 1 must issue one private-slice read per 4 KiB page");
    failed |= expect_true(phase.config.threads.bw_threads == 32,
                          "phase 1 must use all 32 workers");

    failed |= expect_true(mbench_phase_build(&config, 1, &phase) == 0,
                          "phase 2 must build");
    failed |= expect_true(strcmp(phase.name,
                                 "friendly-weighted-tail8g-off20g") == 0,
                          "phase 2 name must be classified as friendly");
    failed |= expect_true(phase.target_ops == config.phase.phase2_target_ops,
                          "phase 2 must retain its fixed-work target");
    failed |= expect_true(phase.config.mode == MBENCH_MODE_SKEWED_HOTSET,
                          "phase 2 must use skewed hotset mode");
    failed |= expect_true(phase.config.window.window_bytes == 8ULL * GIB &&
                          phase.config.window.offset_bytes == 20ULL * GIB,
                          "phase 2 must cover [20 GiB, 28 GiB)");
    failed |= expect_true(
        phase.config.hotset.hotset_pages == (4ULL * GIB) / 4096ULL &&
        phase.config.hotset.hot_prob_pct == 90U,
        "phase 2 must direct 90 percent of accesses to a 4 GiB hotset");
    failed |= expect_true(phase.config.hotset.read_pct == 100U &&
                          phase.config.hotset.write_pct == 0U &&
                          phase.config.hotset.rmw_pct == 0U,
                          "phase 2 must be read-only");
    failed |= expect_true(phase.config.hotset.shared_window &&
                          phase.config.hotset.tail &&
                          phase.config.hotset.background_pages == 0,
                          "phase 2 must share the full window and put hot pages at its tail");
    failed |= expect_true(phase.config.hotset.index_mode ==
                          MBENCH_HOTSET_INDEX_XORSHIFT,
                          "phase 2 must use weighted xorshift selection");
    failed |= expect_true(phase.config.threads.total_threads == 32 &&
                          phase.config.threads.bw_threads == 0,
                          "phase 2 must use all 32 hotset workers");
    failed |= expect_true(mbench_phase_build(&config, 2, &phase) == -ERANGE,
                          "phase builder must reject an out-of-range phase");

    failed |= expect_true(
        mbench_phase_preset_from_string("sparse60-disjoint8g", &preset) == 0,
        "disjoint preset must parse");
    config.phase.preset = preset;
    failed |= expect_true(
        strcmp(mbench_phase_preset_name(config.phase.preset),
               "sparse60-disjoint8g") == 0,
        "disjoint preset must have a stable name");
    failed |= expect_true(mbench_phase_build(&config, 0, &phase) == 0,
                          "disjoint phase 1 must build");
    failed |= expect_true(strcmp(phase.name, "sparse-stride-read-60g") == 0 &&
                          phase.config.window.window_bytes == 60ULL * GIB &&
                          phase.config.window.offset_bytes == 0,
                          "disjoint phase 1 must cover [0 GiB, 60 GiB)");
    failed |= expect_true(
        phase.config.window.window_bytes / 32U / 4096U == 491520U,
        "disjoint phase 1 worker batch geometry must remain derivable");
    failed |= expect_true(phase.target_ops == config.phase.phase1_target_ops,
                          "disjoint phase 1 must retain its fixed-work target");

    failed |= expect_true(mbench_phase_build(&config, 1, &phase) == 0,
                          "disjoint phase 2 must build");
    failed |= expect_true(
        strcmp(phase.name, "friendly-disjoint8g-bg20-hot60") == 0,
        "disjoint phase 2 name must be classified as friendly");
    failed |= expect_true(phase.config.window.window_bytes == 44ULL * GIB &&
                          phase.config.window.offset_bytes == 20ULL * GIB,
                          "disjoint phase 2 must span [20 GiB, 64 GiB)");
    failed |= expect_true(
        phase.config.hotset.hotset_pages == (4ULL * GIB) / 4096ULL &&
        phase.config.hotset.background_pages == (4ULL * GIB) / 4096ULL &&
        phase.config.hotset.hot_prob_pct == 90U,
        "disjoint phase 2 must select 4 GiB background and hot regions");
    failed |= expect_true(phase.config.hotset.shared_window &&
                          phase.config.hotset.tail &&
                          phase.config.hotset.read_pct == 100U &&
                          phase.config.hotset.index_mode ==
                              MBENCH_HOTSET_INDEX_XORSHIFT,
                          "disjoint phase 2 must use shared read-only tail selection");
    failed |= expect_true(phase.target_ops == config.phase.phase2_target_ops,
                          "disjoint phase 2 must retain its fixed-work target");

    failed |= expect_true(
        mbench_phase_preset_from_string("sparse60-disjoint28g", &preset) == 0,
        "28 GiB disjoint preset must parse");
    config.phase.preset = preset;
    failed |= expect_true(
        strcmp(mbench_phase_preset_name(config.phase.preset),
               "sparse60-disjoint28g") == 0,
        "28 GiB disjoint preset must have a stable name");
    failed |= expect_true(mbench_phase_build(&config, 0, &phase) == 0,
                          "28 GiB disjoint phase 1 must build");
    failed |= expect_true(strcmp(phase.name, "sparse-stride-read-60g") == 0 &&
                          phase.config.window.window_bytes == 60ULL * GIB &&
                          phase.config.window.offset_bytes == 0,
                          "28 GiB preset must preserve the [0,60) GiB phase 1");
    failed |= expect_true(
        phase.config.window.window_bytes / 32U / 4096U == 491520U &&
        phase.target_ops == config.phase.phase1_target_ops,
        "28 GiB preset must preserve phase-1 accounting and target work");

    failed |= expect_true(mbench_phase_build(&config, 1, &phase) == 0,
                          "28 GiB disjoint phase 2 must build");
    failed |= expect_true(
        strcmp(phase.name, "friendly-disjoint28g-bg0-hot60") == 0,
        "28 GiB phase 2 name must be classified as friendly");
    failed |= expect_true(phase.config.window.window_bytes == 64ULL * GIB &&
                          phase.config.window.offset_bytes == 0,
                          "28 GiB phase 2 must span the full arena");
    failed |= expect_true(
        phase.config.hotset.hotset_pages == 1048576U &&
        phase.config.hotset.background_pages == 6291456U &&
        ((uint64_t)phase.config.hotset.hotset_pages +
         (uint64_t)phase.config.hotset.background_pages) * 4096ULL ==
            28ULL * GIB,
        "28 GiB phase 2 must select 24 GiB background and 4 GiB hotset");
    failed |= expect_true(phase.config.hotset.hot_prob_pct == 90U &&
                          phase.config.hotset.shared_window &&
                          phase.config.hotset.tail &&
                          phase.config.hotset.read_pct == 100U &&
                          phase.config.hotset.write_pct == 0U &&
                          phase.config.hotset.rmw_pct == 0U &&
                          phase.config.hotset.index_mode ==
                              MBENCH_HOTSET_INDEX_XORSHIFT,
                          "28 GiB phase 2 must use shared read-only tail selection");
    failed |= expect_true(phase.target_ops == config.phase.phase2_target_ops,
                          "28 GiB phase 2 must retain its fixed-work target");

    failed |= expect_true(
        mbench_phase_preset_from_string("gups60-disjoint28g", &preset) == 0,
        "GUPS-like disjoint preset must parse");
    config.phase.preset = preset;
    failed |= expect_true(
        strcmp(mbench_phase_preset_name(config.phase.preset),
               "gups60-disjoint28g") == 0,
        "GUPS-like disjoint preset must have a stable name");
    failed |= expect_true(mbench_phase_build(&config, 0, &phase) == 0,
                          "GUPS-like phase 1 must build");
    failed |= expect_true(
        strcmp(phase.name, "gups-random-rmw-60g") == 0 &&
        phase.config.mode == MBENCH_MODE_SKEWED_HOTSET &&
        phase.config.window.window_bytes == 60ULL * GIB &&
        phase.config.window.offset_bytes == 0,
        "GUPS-like phase 1 must cover the fixed [0,60) GiB range");
    failed |= expect_true(
        phase.config.hotset.hotset_pages == (60ULL * GIB) / 4096ULL &&
        phase.config.hotset.hot_prob_pct == 100U &&
        phase.config.hotset.read_pct == 0U &&
        phase.config.hotset.write_pct == 0U &&
        phase.config.hotset.rmw_pct == 100U,
        "GUPS-like phase 1 must issue uniform random RMW operations");
    failed |= expect_true(
        phase.config.hotset.shared_window &&
        !phase.config.hotset.tail &&
        phase.config.threads.total_threads == 32 &&
        phase.config.threads.bw_threads == 0,
        "GUPS-like phase 1 must share one global table across all workers");
    failed |= expect_true(phase.target_ops == config.phase.phase1_target_ops,
                          "GUPS-like phase 1 must retain its fixed-work target");

    failed |= expect_true(mbench_phase_build(&config, 1, &phase) == 0,
                          "GUPS-like phase 2 must build");
    failed |= expect_true(
        strcmp(phase.name, "friendly-disjoint28g-bg0-hot60") == 0 &&
        phase.config.window.window_bytes == 64ULL * GIB &&
        phase.config.hotset.background_pages == 6291456U &&
        phase.config.hotset.hotset_pages == 1048576U &&
        phase.config.hotset.hot_prob_pct == 90U &&
        phase.config.hotset.read_pct == 100U,
        "GUPS-like preset must retain the disjoint friendly phase");
    failed |= expect_true(phase.target_ops == config.phase.phase2_target_ops,
                          "GUPS-like phase 2 must retain its fixed-work target");

    config.phase.preset = MBENCH_PHASE_PRESET_SPARSE64_MULSHIFT4G;
    failed |= expect_true(mbench_phase_build(&config, 1, &phase) == 0,
                          "existing fixed-4GiB phase must still build");
    failed |= expect_true(phase.config.window.window_bytes == 4ULL * GIB &&
                          phase.config.window.offset_bytes == 60ULL * GIB &&
                          !phase.config.hotset.shared_window &&
                          !phase.config.hotset.tail,
                          "existing preset behavior must remain unchanged");

    failed |= test_hotset_tail_selection();
    failed |= test_background_pages_cli();

    return failed ? 1 : 0;
}
