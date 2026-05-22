#define _GNU_SOURCE

#include "mbench.h"

#include <errno.h>
#include <sched.h>
#include <string.h>

static int set_affinity_for_cpu(cpu_set_t *set, size_t set_size, int cpu_id)
{
    if (!set || cpu_id < 0) {
        return -EINVAL;
    }

    CPU_ZERO_S(set_size, set);
    CPU_SET_S((unsigned int)cpu_id, set_size, set);
    return 0;
}

int mbench_pin_thread_cpu(pthread_t thread, int cpu_id)
{
    cpu_set_t set;
    int rc = set_affinity_for_cpu(&set, sizeof(set), cpu_id);
    if (rc != 0) {
        return rc;
    }
    rc = pthread_setaffinity_np(thread, sizeof(set), &set);
    return rc == 0 ? 0 : -errno;
}

int mbench_pin_current_cpu(int cpu_id)
{
    cpu_set_t set;
    int rc = set_affinity_for_cpu(&set, sizeof(set), cpu_id);
    if (rc != 0) {
        return rc;
    }
    rc = sched_setaffinity(0, sizeof(set), &set);
    return rc == 0 ? 0 : -errno;
}
