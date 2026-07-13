/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_SCHED_SYSCTL_H
#define _LINUX_SCHED_SYSCTL_H

#include <linux/types.h>

#ifdef CONFIG_DETECT_HUNG_TASK
/* used for hung_task and block/ */
extern unsigned long sysctl_hung_task_timeout_secs;
#else
/* Avoid need for ifdefs elsewhere in the code */
enum { sysctl_hung_task_timeout_secs = 0 };
#endif

enum sched_tunable_scaling {
	SCHED_TUNABLESCALING_NONE,
	SCHED_TUNABLESCALING_LOG,
	SCHED_TUNABLESCALING_LINEAR,
	SCHED_TUNABLESCALING_END,
};

#define NUMA_BALANCING_DISABLED		0x0
#define NUMA_BALANCING_NORMAL		0x1
#define NUMA_BALANCING_MEMORY_TIERING	0x2
#define NUMA_BALANCING_TPP		0x4

#define NUMA_BALANCING_TIERING_MASK	\
	(NUMA_BALANCING_MEMORY_TIERING | NUMA_BALANCING_TPP)

static inline bool numa_balancing_mode_tiering(int mode)
{
	return mode & NUMA_BALANCING_TIERING_MASK;
}

static inline bool numa_balancing_mode_tpp(int mode)
{
	return mode & NUMA_BALANCING_TPP;
}

#ifdef CONFIG_NUMA_BALANCING
extern int sysctl_numa_balancing_mode;
extern unsigned int sysctl_numa_balancing_scan_delay;
extern unsigned int sysctl_numa_balancing_scan_period_min;
extern unsigned int sysctl_numa_balancing_scan_period_max;
extern unsigned int sysctl_numa_balancing_scan_size;
#else
#define sysctl_numa_balancing_mode	0
#endif

#endif /* _LINUX_SCHED_SYSCTL_H */
