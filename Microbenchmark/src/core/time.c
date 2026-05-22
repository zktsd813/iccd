#define _GNU_SOURCE

#include "mbench.h"

#include <time.h>

uint64_t mbench_now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

uint64_t mbench_now_us(void)
{
    return mbench_now_ns() / 1000ULL;
}

void mbench_sleep_ms(uint32_t ms)
{
    struct timespec req;
    req.tv_sec = ms / 1000U;
    req.tv_nsec = (long)(ms % 1000U) * 1000000L;
    while (nanosleep(&req, &req) != 0) {
        continue;
    }
}

void mbench_sleep_ns(uint64_t ns)
{
    struct timespec req;
    req.tv_sec = (time_t)(ns / 1000000000ULL);
    req.tv_nsec = (long)(ns % 1000000000ULL);
    while (nanosleep(&req, &req) != 0) {
        continue;
    }
}
