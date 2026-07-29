#define _GNU_SOURCE

#include "mbench.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <unistd.h>

static const uint32_t k_default_warmup_ms = 20000U;

struct mbench_worker_ctx {
    struct mbench_runtime *runtime;
    int rc;
    _Atomic int done;
    _Atomic uint64_t dispatch_start_monotonic_ns;
    _Atomic uint64_t dispatch_complete_monotonic_ns;
};

static int write_marker_file(const char *path)
{
    int fd;
    ssize_t written;
    static const char marker[] = "ready\n";

    if (!path || path[0] == '\0') {
        return 0;
    }

    fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) {
        return -errno;
    }

    written = write(fd, marker, sizeof(marker) - 1U);
    if (written < 0) {
        int err = errno;
        close(fd);
        return -err;
    }

    if (close(fd) != 0) {
        return -errno;
    }

    return 0;
}

static int wait_for_marker_file(const char *path)
{
    if (!path || path[0] == '\0') {
        return 0;
    }

    while (access(path, F_OK) != 0) {
        if (errno != ENOENT) {
            return -errno;
        }
        mbench_sleep_ms(10U);
    }

    return 0;
}

static uint32_t forced_warmup_ms(void)
{
    const char *value = getenv("MBENCH_FORCE_WARMUP_MS");
    char *end = NULL;
    unsigned long parsed;

    if (!value || value[0] == '\0') {
        return k_default_warmup_ms;
    }

    errno = 0;
    parsed = strtoul(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || parsed > UINT32_MAX) {
        return k_default_warmup_ms;
    }

    return (uint32_t)parsed;
}

static int dispatch_mode(struct mbench_runtime *runtime)
{
    switch (runtime->config.mode) {
    case MBENCH_MODE_PC:
        return mbench_execute_pc(runtime);
    case MBENCH_MODE_BW:
        return mbench_execute_bw(runtime);
    case MBENCH_MODE_MIX:
        return mbench_execute_mix(runtime);
    case MBENCH_MODE_SKEWED_HOTSET:
        return mbench_execute_skewed_hotset(runtime);
    case MBENCH_MODE_IRREGULAR_INDEX:
        return mbench_execute_irregular_index(runtime);
    default:
        return -EINVAL;
    }
}

static void *worker_main(void *arg)
{
    struct mbench_worker_ctx *ctx = (struct mbench_worker_ctx *)arg;

    atomic_store_explicit(&ctx->dispatch_start_monotonic_ns,
                          mbench_clock_monotonic_ns(),
                          memory_order_release);
    ctx->rc = dispatch_mode(ctx->runtime);
    atomic_store_explicit(&ctx->dispatch_complete_monotonic_ns,
                          mbench_clock_monotonic_ns(),
                          memory_order_release);
    atomic_store_explicit(&ctx->done, 1, memory_order_release);
    return NULL;
}

static void print_sample(const struct mbench_runtime *runtime,
                         uint64_t elapsed_ns,
                         uint64_t phase_elapsed_ns,
                         uint64_t last_ops,
                         uint64_t last_bytes,
                         bool include_phase)
{
    uint64_t ops = atomic_load_explicit(&runtime->completed_ops, memory_order_relaxed);
    uint64_t bytes = atomic_load_explicit(&runtime->completed_bytes, memory_order_relaxed);
    size_t offset = atomic_load_explicit(&runtime->window.current_offset, memory_order_relaxed);

    if (runtime->config.report.csv) {
        if (include_phase) {
            printf("%" PRIu64 ",%" PRIu64 ",%u,%s,%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%zu\n",
                   (uint64_t)(elapsed_ns / 1000000ULL),
                   (uint64_t)(phase_elapsed_ns / 1000000ULL),
                   runtime->phase_id,
                   runtime->phase_name,
                   ops,
                   ops - last_ops,
                   bytes,
                   bytes - last_bytes,
                   offset);
            return;
        }
        printf("%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%zu\n",
               (uint64_t)(elapsed_ns / 1000000ULL),
               ops,
               ops - last_ops,
               bytes,
               bytes - last_bytes,
               offset);
        return;
    }

    if (include_phase) {
        printf("t=%" PRIu64 "ms phase_t=%" PRIu64 "ms phase=%u:%s ops=%" PRIu64 " (+%" PRIu64 ") bytes=%" PRIu64 " (+%" PRIu64 ") window=%zu\n",
               (uint64_t)(elapsed_ns / 1000000ULL),
               (uint64_t)(phase_elapsed_ns / 1000000ULL),
               runtime->phase_id,
               runtime->phase_name,
               ops,
               ops - last_ops,
               bytes,
               bytes - last_bytes,
               offset);
        return;
    }

    printf("t=%" PRIu64 "ms ops=%" PRIu64 " (+%" PRIu64 ") bytes=%" PRIu64 " (+%" PRIu64 ") window=%zu\n",
           (uint64_t)(elapsed_ns / 1000000ULL),
           ops,
           ops - last_ops,
           bytes,
           bytes - last_bytes,
           offset);
}

static int drive_runtime_phase(struct mbench_runtime *runtime,
                               struct mbench_worker_ctx *worker,
                               uint32_t duration_ms,
                               uint64_t target_ops,
                               bool emit_samples,
                               uint64_t *elapsed_ns_out)
{
    uint64_t start_ns = mbench_now_ns();
    uint64_t next_sample_ns = start_ns;
    uint64_t next_move_ns = start_ns + (uint64_t)runtime->config.timing.move_interval_ms * 1000000ULL;
    uint64_t last_ops = 0;
    uint64_t last_bytes = 0;
    uint32_t sample_ms = runtime->config.timing.sample_ms ? runtime->config.timing.sample_ms : 1000U;
    uint32_t move_ms = runtime->config.timing.move_interval_ms ? runtime->config.timing.move_interval_ms : 1000U;

    if (duration_ms == 0 && target_ops == 0) {
        if (elapsed_ns_out) {
            *elapsed_ns_out = 0;
        }
        return 0;
    }

    if (emit_samples && runtime->config.report.csv) {
        printf("time_ms,ops_total,ops_delta,bytes_total,bytes_delta,window_offset\n");
    }

    while (1) {
        uint64_t now_ns = mbench_now_ns();
        uint64_t current_ops;
        if (now_ns >= next_move_ns && runtime->window.move_policy != MBENCH_MOVE_FIXED) {
            (void)mbench_runtime_advance_window(runtime);
            next_move_ns += (uint64_t)move_ms * 1000000ULL;
        }

        if (emit_samples && now_ns >= next_sample_ns) {
            print_sample(runtime, now_ns - start_ns, now_ns - start_ns, last_ops, last_bytes, false);
            last_ops = atomic_load_explicit(&runtime->completed_ops, memory_order_relaxed);
            last_bytes = atomic_load_explicit(&runtime->completed_bytes, memory_order_relaxed);
            next_sample_ns += (uint64_t)sample_ms * 1000000ULL;
        }

        if (atomic_load_explicit(&worker->done, memory_order_acquire) != 0) {
            break;
        }

        if (atomic_load_explicit(&runtime->stop_requested, memory_order_relaxed) != 0) {
            break;
        }

        current_ops = atomic_load_explicit(&runtime->completed_ops, memory_order_relaxed);
        if (target_ops > 0 && current_ops >= target_ops) {
            break;
        }

        if (target_ops == 0 && duration_ms > 0 &&
            now_ns - start_ns >= (uint64_t)duration_ms * 1000000ULL) {
            break;
        }

        uint64_t wait_ns = target_ops > 0 ? 100000ULL : (uint64_t)move_ms * 1000000ULL;
        if (emit_samples && next_sample_ns > now_ns && next_sample_ns - now_ns < wait_ns) {
            wait_ns = next_sample_ns - now_ns;
        }
        if (runtime->window.move_policy != MBENCH_MOVE_FIXED && next_move_ns > now_ns &&
            next_move_ns - now_ns < wait_ns) {
            wait_ns = next_move_ns - now_ns;
        }
        if (target_ops == 0 && duration_ms > 0 &&
            now_ns < start_ns + (uint64_t)duration_ms * 1000000ULL &&
            start_ns + (uint64_t)duration_ms * 1000000ULL - now_ns < wait_ns) {
            wait_ns = start_ns + (uint64_t)duration_ms * 1000000ULL - now_ns;
        }
        if (target_ops > 0 && wait_ns <= 1000000ULL) {
            mbench_sleep_ns(wait_ns);
        } else if (wait_ns > 1000000ULL) {
            mbench_sleep_ms((uint32_t)(wait_ns / 1000000ULL));
        } else {
            mbench_sleep_ms(1U);
        }
    }

    if (emit_samples && target_ops > 0) {
        uint64_t ops = atomic_load_explicit(&runtime->completed_ops, memory_order_relaxed);
        uint64_t bytes = atomic_load_explicit(&runtime->completed_bytes, memory_order_relaxed);

        if (ops != last_ops || bytes != last_bytes) {
            uint64_t now_ns = mbench_now_ns();

            print_sample(runtime, now_ns - start_ns, now_ns - start_ns,
                         last_ops, last_bytes, false);
        }
    }

    if (elapsed_ns_out) {
        *elapsed_ns_out = mbench_now_ns() - start_ns;
    }
    return 0;
}

static int drive_runtime(struct mbench_runtime *runtime,
                         struct mbench_worker_ctx *worker,
                         uint64_t *measured_elapsed_ns_out)
{
    int rc;
    uint32_t warmup_ms = forced_warmup_ms();
    uint64_t warmup_elapsed_ns = 0;
    uint64_t measured_elapsed_ns = 0;

    rc = drive_runtime_phase(runtime, worker, warmup_ms, 0, false,
                             &warmup_elapsed_ns);
    if (rc != 0) {
        return rc;
    }

    if (atomic_load_explicit(&worker->done, memory_order_acquire) != 0) {
        return 0;
    }

    atomic_store_explicit(&runtime->completed_ops, 0, memory_order_relaxed);
    atomic_store_explicit(&runtime->completed_bytes, 0, memory_order_relaxed);
    if (!runtime->config.report.quiet) {
        if (runtime->config.request.target_ops > 0) {
            fprintf(stderr,
                    "warmup_complete elapsed_s=%.3Lf measurement_target_ops=%" PRIu64 "\n",
                    (long double)warmup_elapsed_ns / 1000000000.0L,
                    runtime->config.request.target_ops);
        } else {
            fprintf(stderr,
                    "warmup_complete elapsed_s=%.3Lf measurement_s=%.3Lf\n",
                    (long double)warmup_elapsed_ns / 1000000000.0L,
                    (long double)runtime->config.timing.duration_ms / 1000.0L);
        }
    }

    rc = drive_runtime_phase(runtime,
                             worker,
                             runtime->config.timing.duration_ms,
                             runtime->config.request.target_ops,
                             true,
                             &measured_elapsed_ns);
    atomic_store_explicit(&runtime->stop_requested, 1, memory_order_relaxed);
    if (measured_elapsed_ns_out) {
        *measured_elapsed_ns_out = measured_elapsed_ns;
    }
    return rc;
}

static int launch_worker_thread(struct mbench_runtime *runtime,
                                struct mbench_worker_ctx *worker,
                                pthread_t *thread)
{
    int rc;

    if (!runtime || !worker || !thread) {
        return -EINVAL;
    }

    memset(worker, 0, sizeof(*worker));
    worker->runtime = runtime;
    atomic_init(&worker->done, 0);
    atomic_init(&worker->dispatch_start_monotonic_ns, 0);
    atomic_init(&worker->dispatch_complete_monotonic_ns, 0);

    rc = pthread_create(thread, NULL, worker_main, worker);
    if (rc != 0) {
        return -rc;
    }
    return 0;
}

static int join_worker_thread(pthread_t thread, const struct mbench_worker_ctx *worker)
{
    int rc = pthread_join(thread, NULL);

    if (rc != 0) {
        return -rc;
    }
    if (worker && worker->rc != 0) {
        return worker->rc;
    }
    return 0;
}

static int drive_phase_samples(struct mbench_runtime *runtime,
                               struct mbench_worker_ctx *worker,
                               uint64_t run_start_ns,
                               uint64_t *last_ops,
                               uint64_t *last_bytes,
                               uint64_t phase_start_ops,
                               uint64_t target_ops,
                               uint64_t *phase_elapsed_ns_out)
{
    uint32_t sample_ms;
    uint32_t move_ms;
    uint64_t phase_start_ns;
    uint64_t deadline_ns;
    uint64_t next_sample_ns;
    uint64_t next_move_ns;
    uint64_t last_sample_ns = 0;

    if (!runtime || !worker || !last_ops || !last_bytes) {
        return -EINVAL;
    }

    sample_ms = runtime->config.timing.sample_ms ? runtime->config.timing.sample_ms : 1000U;
    move_ms = runtime->config.timing.move_interval_ms
        ? runtime->config.timing.move_interval_ms
        : 1000U;
    phase_start_ns = mbench_now_ns();
    deadline_ns = target_ops == 0
        ? phase_start_ns + (uint64_t)runtime->config.phase.duration_ms * 1000000ULL
        : 0;
    next_sample_ns = phase_start_ns;
    next_move_ns = phase_start_ns + (uint64_t)move_ms * 1000000ULL;

    while (1) {
        uint64_t now_ns = mbench_now_ns();

        if (now_ns >= next_move_ns && runtime->window.move_policy != MBENCH_MOVE_FIXED) {
            (void)mbench_runtime_advance_window(runtime);
            next_move_ns += (uint64_t)move_ms * 1000000ULL;
        }

        if (now_ns >= next_sample_ns) {
            print_sample(runtime,
                         now_ns - run_start_ns,
                         now_ns - phase_start_ns,
                         *last_ops,
                         *last_bytes,
                         true);
            *last_ops = atomic_load_explicit(&runtime->completed_ops, memory_order_relaxed);
            *last_bytes = atomic_load_explicit(&runtime->completed_bytes, memory_order_relaxed);
            last_sample_ns = now_ns;
            do {
                next_sample_ns += (uint64_t)sample_ms * 1000000ULL;
            } while (next_sample_ns <= now_ns);
        }

        if (atomic_load_explicit(&worker->done, memory_order_acquire) != 0) {
            break;
        }

        if (atomic_load_explicit(&runtime->stop_requested, memory_order_relaxed) != 0) {
            break;
        }

        uint64_t current_ops = atomic_load_explicit(&runtime->completed_ops,
                                                    memory_order_relaxed);
        if (target_ops > 0 && current_ops - phase_start_ops >= target_ops) {
            break;
        }

        if (target_ops == 0 && now_ns >= deadline_ns) {
            break;
        }

        uint64_t wait_ns = target_ops > 0 ? 100000ULL : 1000000ULL;
        if (next_sample_ns > now_ns && next_sample_ns - now_ns < wait_ns) {
            wait_ns = next_sample_ns - now_ns;
        }
        if (runtime->window.move_policy != MBENCH_MOVE_FIXED && next_move_ns > now_ns &&
            next_move_ns - now_ns < wait_ns) {
            wait_ns = next_move_ns - now_ns;
        }
        if (target_ops == 0 && deadline_ns > now_ns && deadline_ns - now_ns < wait_ns) {
            wait_ns = deadline_ns - now_ns;
        }
        if (wait_ns > 1000000ULL) {
            mbench_sleep_ms((uint32_t)(wait_ns / 1000000ULL));
        } else {
            mbench_sleep_ns(wait_ns);
        }
    }

    uint64_t end_ns = mbench_now_ns();
    if (end_ns > phase_start_ns &&
        (last_sample_ns == 0 || end_ns - last_sample_ns >= 1000000ULL)) {
        print_sample(runtime,
                     end_ns - run_start_ns,
                     end_ns - phase_start_ns,
                     *last_ops,
                     *last_bytes,
                     true);
        *last_ops = atomic_load_explicit(&runtime->completed_ops, memory_order_relaxed);
        *last_bytes = atomic_load_explicit(&runtime->completed_bytes, memory_order_relaxed);
    }

    if (phase_elapsed_ns_out) {
        *phase_elapsed_ns_out = end_ns - phase_start_ns;
    }
    return 0;
}

static int emit_phase_boundary_residency(
    const struct mbench_runtime *runtime,
    const struct mbench_config *base_config,
    size_t boundary_index)
{
    const size_t stride = (size_t)MBENCH_PHASE_BOUNDARY_PROBE_STRIDE;

    if (!runtime || !base_config || !runtime->arena.base) {
        return -EINVAL;
    }

    for (size_t i = 0; i < base_config->phase.boundary_probe_count; ++i) {
        const struct mbench_residency_probe_config *probe =
            &base_config->phase.boundary_probes[i];
        size_t sample_count = 1U + (probe->size_bytes - 1U) / stride;
        size_t node0 = 0;
        size_t node1 = 0;
        size_t other_nodes = 0;
        size_t errors = 0;
        int *status;
        int rc;

        if (sample_count > SIZE_MAX / sizeof(*status)) {
            return -EOVERFLOW;
        }
        status = calloc(sample_count, sizeof(*status));
        if (!status) {
            return -ENOMEM;
        }

        rc = mbench_query_sampled_range_nodes(
            (unsigned char *)runtime->arena.base + probe->offset_bytes,
            probe->size_bytes,
            stride,
            status,
            sample_count);
        if (rc == 0) {
            for (size_t sample = 0; sample < sample_count; ++sample) {
                if (status[sample] == 0) {
                    node0++;
                } else if (status[sample] == 1) {
                    node1++;
                } else if (status[sample] >= 0) {
                    other_nodes++;
                } else {
                    errors++;
                }
            }
        } else {
            errors = sample_count;
        }

        fprintf(stderr,
                "phase_boundary_residency boundary_index=%zu after_phase_id=%u before_phase_id=%u label=%s offset_bytes=%zu size_bytes=%zu stride_bytes=%zu samples=%zu node0=%zu node1=%zu other_nodes=%zu errors=%zu query_errno=%d\n",
                boundary_index,
                runtime->phase_id,
                runtime->phase_id + 1U,
                probe->label,
                probe->offset_bytes,
                probe->size_bytes,
                stride,
                sample_count,
                node0,
                node1,
                other_nodes,
                errors,
                rc < 0 ? -rc : 0);
        free(status);

        if (rc != 0) {
            return rc;
        }
    }
    return 0;
}

static int run_phase_sequence(struct mbench_runtime *runtime,
                              uint64_t *measured_elapsed_ns_out)
{
    struct mbench_config base_config;
    size_t phase_count;
    uint64_t run_start_ns;
    uint64_t last_ops = 0;
    uint64_t last_bytes = 0;
    int rc = 0;

    if (!runtime) {
        return -EINVAL;
    }

    base_config = runtime->config;
    phase_count = mbench_phase_total_count(&base_config);
    if (phase_count == 0) {
        return -EINVAL;
    }

    atomic_store_explicit(&runtime->completed_ops, 0, memory_order_relaxed);
    atomic_store_explicit(&runtime->completed_bytes, 0, memory_order_relaxed);
    atomic_store_explicit(&runtime->stop_requested, 0, memory_order_relaxed);

    if (base_config.report.csv) {
        printf("time_ms,phase_elapsed_ms,phase_id,phase_name,ops_total,ops_delta,bytes_total,bytes_delta,window_offset\n");
    }

    run_start_ns = mbench_now_ns();
    for (size_t i = 0; i < phase_count; ++i) {
        struct mbench_phase phase;
        struct mbench_worker_ctx worker;
        pthread_t worker_thread;
        uint64_t phase_elapsed_ns = 0;
        uint64_t phase_start_ops;
        uint64_t phase_achieved_ops;

        rc = mbench_phase_build(&base_config, i, &phase);
        if (rc != 0) {
            break;
        }
        rc = mbench_runtime_apply_phase(runtime, &phase);
        if (rc != 0) {
            break;
        }
        phase_start_ops = atomic_load_explicit(&runtime->completed_ops,
                                               memory_order_relaxed);

        if (!runtime->config.report.quiet) {
            fprintf(stderr,
                    "phase_start index=%zu/%zu phase_id=%u phase_name=%s duration_ms=%u target_ops=%" PRIu64 " mode=%s bw_kernel=%s threads=%d ops_per_pass=%" PRIu64 " window_bytes=%zu window_offset=%zu move_policy=%s bw_stride=%u bw_block_bytes=%zu hotset_pages=%u hotset_background_pages=%u hot_prob_pct=%u hotset_shared_window=%d hotset_tail=%d\n",
                    i + 1U,
                    phase_count,
                    runtime->phase_id,
                    runtime->phase_name,
                    runtime->config.phase.duration_ms,
                    phase.target_ops,
                    mbench_mode_name(runtime->config.mode),
                    mbench_bw_kernel_name(runtime->config.bw_kernel),
                    runtime->config.threads.total_threads,
                    runtime->config.request.ops_per_pass,
                    runtime->window.window_bytes,
                    atomic_load_explicit(&runtime->window.current_offset,
                                         memory_order_relaxed),
                    mbench_move_policy_name(runtime->window.move_policy),
                    runtime->config.bw_pattern.stride_elements,
                    runtime->config.bw_pattern.block_bytes,
                    runtime->config.hotset.hotset_pages,
                    runtime->config.hotset.background_pages,
                    runtime->config.hotset.hot_prob_pct,
                    runtime->config.hotset.shared_window ? 1 : 0,
                    runtime->config.hotset.tail ? 1 : 0);
        }

        rc = launch_worker_thread(runtime, &worker, &worker_thread);
        if (rc != 0) {
            break;
        }

        {
            uint64_t dispatch_start_monotonic_ns = 0;

            while (dispatch_start_monotonic_ns == 0) {
                dispatch_start_monotonic_ns = atomic_load_explicit(
                    &worker.dispatch_start_monotonic_ns,
                    memory_order_acquire);
                if (dispatch_start_monotonic_ns == 0) {
                    mbench_sleep_ns(1000U);
                }
            }
            fprintf(stderr,
                    "phase_start_monotonic phase_index=%zu phase_count=%zu phase_id=%u phase_name=%s clock_id=CLOCK_MONOTONIC clock_monotonic_ns=%" PRIu64 "\n",
                    i + 1U,
                    phase_count,
                    runtime->phase_id,
                    runtime->phase_name,
                    dispatch_start_monotonic_ns);
        }

        rc = drive_phase_samples(runtime,
                                 &worker,
                                 run_start_ns,
                                 &last_ops,
                                 &last_bytes,
                                 phase_start_ops,
                                 phase.target_ops,
                                 &phase_elapsed_ns);
        atomic_store_explicit(&runtime->stop_requested, 1, memory_order_relaxed);

        int join_rc = join_worker_thread(worker_thread, &worker);
        {
            uint64_t dispatch_complete_monotonic_ns = atomic_load_explicit(
                &worker.dispatch_complete_monotonic_ns,
                memory_order_acquire);

            if (dispatch_complete_monotonic_ns != 0) {
                fprintf(stderr,
                        "phase_complete_monotonic phase_index=%zu phase_count=%zu phase_id=%u phase_name=%s clock_id=CLOCK_MONOTONIC clock_monotonic_ns=%" PRIu64 "\n",
                        i + 1U,
                        phase_count,
                        runtime->phase_id,
                        runtime->phase_name,
                        dispatch_complete_monotonic_ns);
            }
        }
        if (rc == 0 && join_rc != 0) {
            rc = join_rc;
        }
        if (rc != 0) {
            break;
        }
        phase_achieved_ops = atomic_load_explicit(&runtime->completed_ops,
                                                  memory_order_relaxed) - phase_start_ops;

        if (!runtime->config.report.quiet) {
            fprintf(stderr,
                    "phase_complete phase_id=%u phase_name=%s elapsed_s=%.3Lf target_ops=%" PRIu64 " achieved_ops=%" PRIu64 "\n",
                    runtime->phase_id,
                    runtime->phase_name,
                    (long double)phase_elapsed_ns / 1000000000.0L,
                    phase.target_ops,
                    phase_achieved_ops);
        }

        if ((i % 2U) == 0 && i + 1U < phase_count &&
            base_config.phase.boundary_probe_count > 0) {
            rc = emit_phase_boundary_residency(runtime,
                                               &base_config,
                                               i / 2U + 1U);
            if (rc != 0) {
                break;
            }
        }
    }

    if (measured_elapsed_ns_out) {
        *measured_elapsed_ns_out = mbench_now_ns() - run_start_ns;
    }
    return rc;
}

static uint64_t scale_ops_to_target_duration(uint64_t ops,
                                             uint64_t elapsed_ns,
                                             uint32_t target_seconds)
{
    long double scaled;

    if (elapsed_ns == 0 || target_seconds == 0) {
        return 0;
    }

    scaled = ((long double)ops * (long double)target_seconds * 1000000000.0L) /
             (long double)elapsed_ns;
    if (scaled <= 0.0L) {
        return 0;
    }
    if (scaled >= (long double)UINT64_MAX) {
        return UINT64_MAX;
    }
    return (uint64_t)(scaled + 0.5L);
}

int main(int argc, char **argv)
{
    setbuf(stdout, NULL);

    struct mbench_config config;
    const char *ready_file = getenv("MBENCH_READY_FILE");
    const char *start_file = getenv("MBENCH_START_FILE");
    int rc = mbench_config_parse(&config, argc, argv);
    if (rc == 1) {
        return 0;
    }
    if (rc != 0) {
        fprintf(stderr, "failed to parse configuration: %s\n", strerror(-rc));
        mbench_print_usage(stderr, (argc > 0) ? argv[0] : "mbench");
        return 1;
    }

    struct mbench_runtime runtime;
    rc = mbench_runtime_prepare(&runtime, &config);
    if (rc != 0) {
        fprintf(stderr, "failed to prepare runtime: %s\n", strerror(-rc));
        return 1;
    }

    if (!runtime.config.report.quiet) {
        mbench_config_dump(stderr, &runtime.config);
    }

    rc = write_marker_file(ready_file);
    if (rc != 0) {
        fprintf(stderr, "failed to write ready file: %s\n", strerror(-rc));
        mbench_runtime_release(&runtime);
        return 1;
    }

    rc = wait_for_marker_file(start_file);
    if (rc != 0) {
        fprintf(stderr, "failed to wait for start file: %s\n", strerror(-rc));
        mbench_runtime_release(&runtime);
        return 1;
    }

    if (mbench_phase_enabled(&runtime.config)) {
        uint64_t measured_elapsed_ns = 0;

        rc = run_phase_sequence(&runtime, &measured_elapsed_ns);
        if (rc != 0) {
            fprintf(stderr, "phase run failed: %s\n", strerror(-rc));
        }

        if (runtime.config.report.emit_summary) {
            uint64_t ops = atomic_load_explicit(&runtime.completed_ops, memory_order_relaxed);
            uint64_t bytes = atomic_load_explicit(&runtime.completed_bytes, memory_order_relaxed);
            fprintf(stderr,
                    "summary phase_preset=%s phase_count=%zu last_phase=%u:%s ops=%" PRIu64 " bytes=%" PRIu64 " final_offset=%zu\n",
                    mbench_phase_preset_name(runtime.config.phase.preset),
                    mbench_phase_total_count(&runtime.config),
                    runtime.phase_id,
                    runtime.phase_name,
                    ops,
                    bytes,
                    atomic_load_explicit(&runtime.window.current_offset, memory_order_relaxed));
        }

        {
            uint64_t ops = atomic_load_explicit(&runtime.completed_ops, memory_order_relaxed);
            uint64_t ops_200s = scale_ops_to_target_duration(ops, measured_elapsed_ns, 200U);

            fprintf(stderr,
                    "ops_200s=%" PRIu64 " total_ops=%" PRIu64 " elapsed_s=%.3Lf\n",
                    ops_200s,
                    ops,
                    (long double)measured_elapsed_ns / 1000000000.0L);
        }

        {
            uint64_t ops = atomic_load_explicit(&runtime.completed_ops, memory_order_relaxed);

            fprintf(stderr,
                    "phase_run total_ops=%" PRIu64 " elapsed_s=%.6Lf\n",
                    ops,
                    (long double)measured_elapsed_ns / 1000000000.0L);
        }

        mbench_runtime_release(&runtime);
        return (rc != 0) ? 1 : 0;
    }

    struct mbench_worker_ctx worker;
    memset(&worker, 0, sizeof(worker));
    worker.runtime = &runtime;
    atomic_init(&worker.done, 0);

    pthread_t worker_thread;
    uint64_t measured_elapsed_ns = 0;
    rc = pthread_create(&worker_thread, NULL, worker_main, &worker);
    if (rc != 0) {
        fprintf(stderr, "failed to launch worker thread: %s\n", strerror(rc));
        mbench_runtime_release(&runtime);
        return 1;
    }

    rc = drive_runtime(&runtime, &worker, &measured_elapsed_ns);
    if (rc != 0) {
        fprintf(stderr, "runtime drive failed: %s\n", strerror(-rc));
    }

    int join_rc = pthread_join(worker_thread, NULL);
    if (join_rc != 0) {
        fprintf(stderr, "failed to join worker thread: %s\n", strerror(join_rc));
        mbench_runtime_release(&runtime);
        return 1;
    }

    if (worker.rc != 0) {
        fprintf(stderr, "kernel entrypoint failed: %s\n", strerror(-worker.rc));
    }

    if (runtime.config.report.emit_summary) {
        uint64_t ops = atomic_load_explicit(&runtime.completed_ops, memory_order_relaxed);
        uint64_t bytes = atomic_load_explicit(&runtime.completed_bytes, memory_order_relaxed);
        fprintf(stderr,
                "summary mode=%s ops=%" PRIu64 " bytes=%" PRIu64 " final_offset=%zu\n",
                mbench_mode_name(runtime.config.mode),
                ops,
                bytes,
                atomic_load_explicit(&runtime.window.current_offset, memory_order_relaxed));
    }

    {
        uint64_t ops = atomic_load_explicit(&runtime.completed_ops, memory_order_relaxed);
        uint64_t ops_200s = scale_ops_to_target_duration(ops, measured_elapsed_ns, 200U);

        if (runtime.config.request.target_ops > 0) {
            long double ns_per_op = ops > 0
                ? (long double)measured_elapsed_ns / (long double)ops
                : 0.0L;
            long double ops_per_s = measured_elapsed_ns > 0
                ? ((long double)ops * 1000000000.0L) / (long double)measured_elapsed_ns
                : 0.0L;

            fprintf(stderr,
                    "target_ops=%" PRIu64 " total_ops=%" PRIu64 " elapsed_s=%.6Lf ns_per_op=%.3Lf ops_per_s=%.3Lf\n",
                    runtime.config.request.target_ops,
                    ops,
                    (long double)measured_elapsed_ns / 1000000000.0L,
                    ns_per_op,
                    ops_per_s);
        } else {
            fprintf(stderr,
                    "ops_200s=%" PRIu64 " total_ops=%" PRIu64 " elapsed_s=%.3Lf\n",
                    ops_200s,
                    ops,
                    (long double)measured_elapsed_ns / 1000000000.0L);
        }
    }

    mbench_runtime_release(&runtime);
    return (worker.rc != 0) ? 1 : 0;
}
