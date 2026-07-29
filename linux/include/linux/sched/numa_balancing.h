/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_SCHED_NUMA_BALANCING_H
#define _LINUX_SCHED_NUMA_BALANCING_H

/*
 * This is the interface between the scheduler and the MM that
 * implements memory access pattern based NUMA-balancing:
 */

#include <linux/sched.h>
#include <linux/sched/sysctl.h>

struct mm_struct;
struct numa_local_fault_node_state;

#define TNF_MIGRATED	0x01
#define TNF_NO_GROUP	0x02
#define TNF_SHARED	0x04
#define TNF_FAULT_LOCAL	0x08
#define TNF_MIGRATE_FAIL 0x10
#define TNF_DEMOTED	0x20

enum numa_vmaskip_reason {
	NUMAB_SKIP_UNSUITABLE,
	NUMAB_SKIP_SHARED_RO,
	NUMAB_SKIP_INACCESSIBLE,
	NUMAB_SKIP_SCAN_DELAY,
	NUMAB_SKIP_PID_INACTIVE,
	NUMAB_SKIP_IGNORE_PID,
	NUMAB_SKIP_SEQ_COMPLETED,
};

#ifdef CONFIG_NUMA_BALANCING
extern void task_numa_fault(int last_node, int node, int pages, int flags);
extern pid_t task_numa_group_id(struct task_struct *p);
extern void set_numabalancing_state(bool enabled);
extern void numa_balancing_reset_memory_tiering(void);
#ifdef CONFIG_NUMA_BALANCING_MT
extern void sched_numa_balancing_update_state(void);
#endif
extern void task_numa_free(struct task_struct *p, bool final);
bool should_numa_migrate_memory(struct task_struct *p, struct folio *folio,
				int src_nid, int dst_cpu);
#else
static inline void task_numa_fault(int last_node, int node, int pages,
				   int flags)
{
}
static inline pid_t task_numa_group_id(struct task_struct *p)
{
	return 0;
}
static inline void set_numabalancing_state(bool enabled)
{
}
static inline void task_numa_free(struct task_struct *p, bool final)
{
}
static inline bool should_numa_migrate_memory(struct task_struct *p,
				struct folio *folio, int src_nid, int dst_cpu)
{
	return true;
}
#endif

#ifdef CONFIG_NUMA_BALANCING_MT
bool numa_local_fault_sampling_enabled(void);
bool numa_balancing_migration_enabled(void);
unsigned long numa_local_fault_policy_seq_read(void);
bool numa_account_local_fault_pte(struct folio *folio);
void numa_account_local_fault_refault(struct folio *folio,
				      unsigned long nr_pages);
void numa_account_remote_fault_latency(struct folio *folio,
				       unsigned long nr_pages);
bool numa_account_remote_scan_pte(struct mm_struct *mm, struct folio *folio);
void numa_account_fault_probe_cancel(struct folio *folio);
void numa_account_remote_scan_cycle(struct mm_struct *mm);
unsigned int task_numa_local_fault_scan_period_ms(struct task_struct *p);
unsigned int task_numa_local_fault_scan_size_mb(struct task_struct *p);
unsigned long task_numa_scan_local_faults(struct task_struct *p, int nid,
					  unsigned long max_pte_updates,
					  struct numa_local_fault_node_state *scan_state);
#else
static inline bool numa_local_fault_sampling_enabled(void)
{
	return false;
}

static inline bool numa_balancing_migration_enabled(void)
{
	return true;
}

static inline unsigned long numa_local_fault_policy_seq_read(void)
{
	return 0;
}

static inline bool numa_account_local_fault_pte(struct folio *folio)
{
	return false;
}

static inline void
numa_account_local_fault_refault(struct folio *folio, unsigned long nr_pages)
{
}

static inline void
numa_account_remote_fault_latency(struct folio *folio, unsigned long nr_pages)
{
}

static inline bool numa_account_remote_scan_pte(struct mm_struct *mm,
						struct folio *folio)
{
	return false;
}

static inline void numa_account_fault_probe_cancel(struct folio *folio)
{
}

static inline void numa_account_remote_scan_cycle(struct mm_struct *mm)
{
}

static inline unsigned int
task_numa_local_fault_scan_period_ms(struct task_struct *p)
{
	return 0;
}

static inline unsigned int
task_numa_local_fault_scan_size_mb(struct task_struct *p)
{
	return 0;
}

static inline unsigned long
task_numa_scan_local_faults(struct task_struct *p, int nid,
			    unsigned long max_pte_updates,
			    struct numa_local_fault_node_state *scan_state)
{
	return 0;
}
#endif

static inline int task_numa_balancing_mode(struct task_struct *p)
{
	return READ_ONCE(sysctl_numa_balancing_mode);
}

static inline bool task_numa_local_fault_sampling_enabled(struct task_struct *p)
{
	if (!p || !p->mm)
		return false;

	return numa_local_fault_sampling_enabled();
}

static inline unsigned long task_numa_balancing_policy_seq(struct task_struct *p)
{
	return numa_local_fault_policy_seq_read();
}

static inline int folio_numa_balancing_mode(struct folio *folio)
{
	return READ_ONCE(sysctl_numa_balancing_mode);
}

#endif /* _LINUX_SCHED_NUMA_BALANCING_H */
