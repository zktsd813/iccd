/* SPDX-License-Identifier: GPL-2.0 */
#undef TRACE_SYSTEM
#define TRACE_SYSTEM migrate

#if !defined(_TRACE_MIGRATE_H) || defined(TRACE_HEADER_MULTI_READ)
#define _TRACE_MIGRATE_H

#include <linux/tracepoint.h>

#define MIGRATE_MODE						\
	EM( MIGRATE_ASYNC,	"MIGRATE_ASYNC")		\
	EM( MIGRATE_SYNC_LIGHT,	"MIGRATE_SYNC_LIGHT")		\
	EMe(MIGRATE_SYNC,	"MIGRATE_SYNC")


#define MIGRATE_REASON						\
	EM( MR_COMPACTION,	"compaction")			\
	EM( MR_MEMORY_FAILURE,	"memory_failure")		\
	EM( MR_MEMORY_HOTPLUG,	"memory_hotplug")		\
	EM( MR_SYSCALL,		"syscall_or_cpuset")		\
	EM( MR_MEMPOLICY_MBIND,	"mempolicy_mbind")		\
	EM( MR_NUMA_MISPLACED,	"numa_misplaced")		\
	EM( MR_CONTIG_RANGE,	"contig_range")			\
	EM( MR_LONGTERM_PIN,	"longterm_pin")			\
	EM( MR_DEMOTION,	"demotion")			\
	EMe(MR_DAMON,		"damon")

#define MIGRATE_STAGE							\
	EM( MIGRATE_STAGE_SYSCALL_GET_ARGS,	"syscall_get_args")	\
	EM( MIGRATE_STAGE_SYSCALL_DO_PAGES_MOVE, "syscall_do_pages_move") \
	EM( MIGRATE_STAGE_SYSCALL_MIGRATE_LIST, "syscall_migrate_list") \
	EM( MIGRATE_STAGE_SYSCALL_STORE_STATUS, "syscall_store_status") \
	EM( MIGRATE_STAGE_SYSCALL_VALIDATE_NODE, "syscall_validate_node") \
	EM( MIGRATE_STAGE_SYSCALL_LRU_DISABLE, "syscall_lru_disable")	\
	EM( MIGRATE_STAGE_SYSCALL_LRU_ENABLE,	"syscall_lru_enable")	\
	EM( MIGRATE_STAGE_LRU_DISABLE_ATOMIC_INC, "lru_disable_atomic_inc") \
	EM( MIGRATE_STAGE_LRU_DISABLE_RCU_SYNC, "lru_disable_rcu_sync") \
	EM( MIGRATE_STAGE_LRU_DISABLE_DRAIN_ALL, "lru_disable_drain_all") \
	EM( MIGRATE_STAGE_SYSCALL_LOOKUP,	"syscall_lookup")	\
	EM( MIGRATE_STAGE_SYSCALL_ISOLATE,	"syscall_isolate")	\
	EM( MIGRATE_STAGE_SYSCALL_LOOKUP_ISOLATE, "syscall_lookup_isolate") \
	EM( MIGRATE_STAGE_NUMA_PREPARE_ISOLATE,	"numa_prepare_isolate") \
	EM( MIGRATE_STAGE_ALLOC_DST,		"alloc_dst")		\
	EM( MIGRATE_STAGE_UNMAP_PREPARE,	"unmap_prepare")	\
	EM( MIGRATE_STAGE_UNMAP,		"unmap_migration_pte") \
	EM( MIGRATE_STAGE_TLB_FLUSH_BATCH,	"tlb_flush_batch")	\
	EM( MIGRATE_STAGE_COPY_MOVE,		"copy_move")		\
	EM( MIGRATE_STAGE_POST_COPY_LRU,	"post_copy_lru")	\
	EM( MIGRATE_STAGE_MOVE_FINALIZE,	"move_finalize")	\
	EM( MIGRATE_STAGE_MIGRATE_HUGETLB,	"migrate_hugetlb")	\
	EM( MIGRATE_STAGE_MIGRATE_BATCH_SELECT, "migrate_batch_select") \
	EM( MIGRATE_STAGE_MIGRATE_BATCH_CALL, "migrate_batch_call")	\
	EM( MIGRATE_STAGE_MIGRATE_SPLIT_RETRY, "migrate_split_retry") \
	EM( MIGRATE_STAGE_MIGRATE_FINALIZE,	"migrate_finalize")	\
	EM( MIGRATE_STAGE_BATCH_UNMAP_LOOP,	"batch_unmap_loop")	\
	EM( MIGRATE_STAGE_BATCH_MOVE_LOOP,	"batch_move_loop")	\
	EM( MIGRATE_STAGE_BATCH_CLEANUP_UNDO,	"batch_cleanup_undo") \
	EMe(MIGRATE_STAGE_REMAP,		"remap_remove_migration_pte")

#ifndef _TRACE_MIGRATE_STAGE_ENUM
#define _TRACE_MIGRATE_STAGE_ENUM
enum migrate_stage {
#undef EM
#undef EMe
#define EM(a, b)	a,
#define EMe(a, b)	a
	MIGRATE_STAGE
};
#endif

/*
 * First define the enums in the above macros to be exported to userspace
 * via TRACE_DEFINE_ENUM().
 */
#undef EM
#undef EMe
#define EM(a, b)	TRACE_DEFINE_ENUM(a);
#define EMe(a, b)	TRACE_DEFINE_ENUM(a);

MIGRATE_MODE
MIGRATE_REASON
MIGRATE_STAGE

/*
 * Now redefine the EM() and EMe() macros to map the enums to the strings
 * that will be printed in the output.
 */
#undef EM
#undef EMe
#define EM(a, b)	{a, b},
#define EMe(a, b)	{a, b}

TRACE_EVENT(mm_migrate_pages,

	TP_PROTO(unsigned long succeeded, unsigned long failed,
		 unsigned long thp_succeeded, unsigned long thp_failed,
		 unsigned long thp_split, unsigned long large_folio_split,
		 enum migrate_mode mode, int reason),

	TP_ARGS(succeeded, failed, thp_succeeded, thp_failed,
		thp_split, large_folio_split, mode, reason),

	TP_STRUCT__entry(
		__field(	unsigned long,		succeeded)
		__field(	unsigned long,		failed)
		__field(	unsigned long,		thp_succeeded)
		__field(	unsigned long,		thp_failed)
		__field(	unsigned long,		thp_split)
		__field(	unsigned long,		large_folio_split)
		__field(	enum migrate_mode,	mode)
		__field(	int,			reason)
	),

	TP_fast_assign(
		__entry->succeeded			= succeeded;
		__entry->failed				= failed;
		__entry->thp_succeeded		= thp_succeeded;
		__entry->thp_failed			= thp_failed;
		__entry->thp_split			= thp_split;
		__entry->large_folio_split	= large_folio_split;
		__entry->mode				= mode;
		__entry->reason				= reason;
	),

	TP_printk("nr_succeeded=%lu nr_failed=%lu nr_thp_succeeded=%lu nr_thp_failed=%lu nr_thp_split=%lu nr_split=%lu mode=%s reason=%s",
		__entry->succeeded,
		__entry->failed,
		__entry->thp_succeeded,
		__entry->thp_failed,
		__entry->thp_split,
		__entry->large_folio_split,
		__print_symbolic(__entry->mode, MIGRATE_MODE),
		__print_symbolic(__entry->reason, MIGRATE_REASON))
);

TRACE_EVENT(mm_migrate_pages_start,

	TP_PROTO(enum migrate_mode mode, int reason),

	TP_ARGS(mode, reason),

	TP_STRUCT__entry(
		__field(enum migrate_mode, mode)
		__field(int, reason)
	),

	TP_fast_assign(
		__entry->mode	= mode;
		__entry->reason	= reason;
	),

	TP_printk("mode=%s reason=%s",
		  __print_symbolic(__entry->mode, MIGRATE_MODE),
		  __print_symbolic(__entry->reason, MIGRATE_REASON))
);

TRACE_EVENT(mm_migrate_stage,

	TP_PROTO(int stage, int mode, int reason, int order,
		 int src_nid, int dst_nid, unsigned long nr_pages,
		 u64 duration_ns, int rc),

	TP_ARGS(stage, mode, reason, order, src_nid, dst_nid, nr_pages,
		duration_ns, rc),

	TP_STRUCT__entry(
		__field(	int,		stage)
		__field(	int,		mode)
		__field(	int,		reason)
		__field(	int,		order)
		__field(	int,		src_nid)
		__field(	int,		dst_nid)
		__field(	unsigned long,	nr_pages)
		__field(	u64,		duration_ns)
		__field(	int,		rc)
	),

	TP_fast_assign(
		__entry->stage		= stage;
		__entry->mode		= mode;
		__entry->reason		= reason;
		__entry->order		= order;
		__entry->src_nid	= src_nid;
		__entry->dst_nid	= dst_nid;
		__entry->nr_pages	= nr_pages;
		__entry->duration_ns	= duration_ns;
		__entry->rc		= rc;
	),

	TP_printk("stage=%s mode=%s reason=%s order=%d src_nid=%d dst_nid=%d nr_pages=%lu duration_ns=%llu rc=%d",
		__print_symbolic(__entry->stage, MIGRATE_STAGE),
		__print_symbolic(__entry->mode, MIGRATE_MODE),
		__print_symbolic(__entry->reason, MIGRATE_REASON),
		__entry->order,
		__entry->src_nid,
		__entry->dst_nid,
		__entry->nr_pages,
		__entry->duration_ns,
		__entry->rc)
);

DECLARE_EVENT_CLASS(migration_pte,

		TP_PROTO(unsigned long addr, unsigned long pte, int order),

		TP_ARGS(addr, pte, order),

		TP_STRUCT__entry(
			__field(unsigned long, addr)
			__field(unsigned long, pte)
			__field(int, order)
		),

		TP_fast_assign(
			__entry->addr = addr;
			__entry->pte = pte;
			__entry->order = order;
		),

		TP_printk("addr=%lx, pte=%lx order=%d", __entry->addr, __entry->pte, __entry->order)
);

DEFINE_EVENT(migration_pte, set_migration_pte,
	TP_PROTO(unsigned long addr, unsigned long pte, int order),
	TP_ARGS(addr, pte, order)
);

DEFINE_EVENT(migration_pte, remove_migration_pte,
	TP_PROTO(unsigned long addr, unsigned long pte, int order),
	TP_ARGS(addr, pte, order)
);

#endif /* _TRACE_MIGRATE_H */

/* This part must be outside protection */
#include <trace/define_trace.h>
