// SPDX-License-Identifier: GPL-2.0
#include <linux/atomic.h>
#include <linux/capability.h>
#include <linux/cpu.h>
#include <linux/jiffies.h>
#include <linux/kobject.h>
#include <linux/memcontrol.h>
#include <linux/memory-tiers.h>
#include <linux/memory_hotplug.h>
#include <linux/mm.h>
#include <linux/mmzone.h>
#include <linux/page_ext.h>
#include <linux/percpu.h>
#include <linux/rmap.h>
#include <linux/sched.h>
#include <linux/sched/numa_balancing.h>
#include <linux/sched/sysctl.h>
#include <linux/slab.h>
#include <linux/sort.h>
#include <linux/spinlock.h>
#include <linux/sysfs.h>

#include "internal.h"

#define NUMA_LOCAL_FAULT_RATE_MAX		100U
#define NUMA_LOCAL_FAULT_SCAN_PERIOD_MS_DEF	1000U
#define NUMA_LOCAL_FAULT_SCAN_SIZE_MB_DEF	64U
#define NUMA_FAULT_LATENCY_PPM			1000000ULL
#define NUMA_FAULT_LATENCY_NS_PER_MS		1000000ULL
#define NUMA_FAULT_LATENCY_KLL_LEVELS		16
#define NUMA_FAULT_LATENCY_KLL_LEVEL_CAPACITY	64
#define NUMA_FAULT_LATENCY_KLL_MAX_ITEMS	\
	(NUMA_FAULT_LATENCY_KLL_LEVELS * NUMA_FAULT_LATENCY_KLL_LEVEL_CAPACITY)

struct numa_local_fault_page_ext {
	atomic64_t local_state;
};

struct numa_fault_latency_kll_item {
	u32 value_ms;
	u64 weight;
};

struct numa_fault_latency_kll {
	u32 seq;
	u64 total_weight;
	u16 level_count[NUMA_FAULT_LATENCY_KLL_LEVELS];
	u8 compact_parity[NUMA_FAULT_LATENCY_KLL_LEVELS];
	struct numa_fault_latency_kll_item
		levels[NUMA_FAULT_LATENCY_KLL_LEVELS]
		      [NUMA_FAULT_LATENCY_KLL_LEVEL_CAPACITY];
};

struct numa_fault_latency_sketch_cpu {
	spinlock_t lock;
	struct numa_fault_latency_kll local;
	struct numa_fault_latency_kll remote;
};

struct numa_fault_latency_sketch_snapshot {
	struct numa_fault_latency_kll_item *local_items;
	struct numa_fault_latency_kll_item *remote_items;
	unsigned int local_items_count;
	unsigned int remote_items_count;
	unsigned int item_capacity;
	u64 local_total;
	u64 remote_total;
};

static u32 numa_local_fault_rate;
static u32 numa_local_fault_scan_period_ms =
	NUMA_LOCAL_FAULT_SCAN_PERIOD_MS_DEF;
static u32 numa_local_fault_scan_size_mb =
	NUMA_LOCAL_FAULT_SCAN_SIZE_MB_DEF;
static atomic_long_t numa_local_fault_policy_seq = ATOMIC_LONG_INIT(1);
static atomic_t numa_local_fault_window_seq = ATOMIC_INIT(1);
static u32 numa_balancing_migration_enabled_state = 1;
static u32 numa_remote_quantile_rank_ppm;
static DEFINE_PER_CPU(struct numa_fault_latency_sketch_cpu,
			      numa_fault_latency_sketch_pcpu);
static atomic64_t numa_remote_scan_cycles;

static bool numa_local_fault_page_ext_need(void)
{
	return true;
}

struct page_ext_operations numa_local_fault_page_ext_ops = {
	.size = sizeof(struct numa_local_fault_page_ext),
	.need = numa_local_fault_page_ext_need,
};

static void numa_local_fault_bump_policy_seq(void)
{
	atomic_long_inc(&numa_local_fault_policy_seq);
	sched_numa_balancing_update_state();
}

bool numa_local_fault_sampling_enabled(void)
{
	return READ_ONCE(numa_local_fault_rate) > 0;
}

bool numa_balancing_migration_enabled(void)
{
	return READ_ONCE(numa_balancing_migration_enabled_state) != 0;
}

unsigned long numa_local_fault_policy_seq_read(void)
{
	return atomic_long_read(&numa_local_fault_policy_seq);
}

unsigned int task_numa_local_fault_scan_period_ms(struct task_struct *p)
{
	if (!p || !p->mm || !numa_local_fault_sampling_enabled())
		return 0;

	return READ_ONCE(numa_local_fault_scan_period_ms);
}

unsigned int task_numa_local_fault_scan_size_mb(struct task_struct *p)
{
	if (!p || !p->mm || !numa_local_fault_sampling_enabled())
		return 0;

	return READ_ONCE(numa_local_fault_scan_size_mb);
}

static bool numa_local_fault_select_pfn(struct folio *folio, u32 rate,
					unsigned int bias)
{
	unsigned long pfn = folio_pfn(folio);
	u32 period;

	if (rate >= NUMA_LOCAL_FAULT_RATE_MAX)
		return true;

	if (NUMA_LOCAL_FAULT_RATE_MAX % rate == 0) {
		period = NUMA_LOCAL_FAULT_RATE_MAX / rate;
		return pfn % period == bias % period;
	}

	period = NUMA_LOCAL_FAULT_RATE_MAX;
	return (pfn + period - (bias % period)) % period < rate;
}

static u32 numa_local_fault_window_seq_read(void)
{
	int seq = atomic_read(&numa_local_fault_window_seq);

	if (seq > 0)
		return (u32)seq;

	atomic_set(&numa_local_fault_window_seq, 1);
	return 1;
}

static u64 numa_fault_latency_ms_to_ns(u32 latency_ms)
{
	return (u64)latency_ms * NUMA_FAULT_LATENCY_NS_PER_MS;
}

static int numa_fault_latency_kll_item_cmp(const void *a, const void *b)
{
	const struct numa_fault_latency_kll_item *ia = a;
	const struct numa_fault_latency_kll_item *ib = b;

	if (ia->value_ms < ib->value_ms)
		return -1;
	if (ia->value_ms > ib->value_ms)
		return 1;
	return 0;
}

static void numa_fault_latency_kll_reset(struct numa_fault_latency_kll *sketch,
					 u32 seq)
{
	memset(sketch->level_count, 0, sizeof(sketch->level_count));
	memset(sketch->compact_parity, 0, sizeof(sketch->compact_parity));
	sketch->seq = seq;
	sketch->total_weight = 0;
}

static void numa_fault_latency_kll_insert_weighted(
	struct numa_fault_latency_kll *sketch, unsigned int level,
	struct numa_fault_latency_kll_item item);

static void numa_fault_latency_kll_compact_top(
	struct numa_fault_latency_kll *sketch)
{
	struct numa_fault_latency_kll_item promoted[
		NUMA_FAULT_LATENCY_KLL_LEVEL_CAPACITY / 2];
	struct numa_fault_latency_kll_item leftover = { };
	struct numa_fault_latency_kll_item *items;
	unsigned int top = NUMA_FAULT_LATENCY_KLL_LEVELS - 1;
	unsigned int count = sketch->level_count[top];
	unsigned int paired, parity, keep = 0, out = 0, i;
	bool has_leftover;

	if (count < 2)
		return;

	items = sketch->levels[top];
	sort(items, count, sizeof(items[0]),
	     numa_fault_latency_kll_item_cmp, NULL);

	paired = count & ~1U;
	parity = sketch->compact_parity[top]++ & 1U;
	has_leftover = count & 1;
	if (has_leftover)
		leftover = items[count - 1];

	for (i = 0; i < paired; i += 2) {
		promoted[out].value_ms = items[i + parity].value_ms;
		promoted[out].weight = items[i].weight + items[i + 1].weight;
		out++;
	}

	if (has_leftover)
		items[keep++] = leftover;
	for (i = 0; i < out; i++)
		items[keep++] = promoted[i];
	sketch->level_count[top] = keep;
}

static void numa_fault_latency_kll_compact_level(
	struct numa_fault_latency_kll *sketch, unsigned int level)
{
	struct numa_fault_latency_kll_item promoted[
		NUMA_FAULT_LATENCY_KLL_LEVEL_CAPACITY / 2];
	struct numa_fault_latency_kll_item leftover = { };
	struct numa_fault_latency_kll_item *items;
	unsigned int count, paired, parity, keep = 0, out = 0, i;
	bool has_leftover;

	if (level >= NUMA_FAULT_LATENCY_KLL_LEVELS)
		return;
	if (level == NUMA_FAULT_LATENCY_KLL_LEVELS - 1) {
		numa_fault_latency_kll_compact_top(sketch);
		return;
	}

	count = sketch->level_count[level];
	if (count < 2)
		return;

	items = sketch->levels[level];
	sort(items, count, sizeof(items[0]),
	     numa_fault_latency_kll_item_cmp, NULL);

	paired = count & ~1U;
	parity = sketch->compact_parity[level]++ & 1U;
	has_leftover = count & 1;
	if (has_leftover)
		leftover = items[count - 1];

	for (i = 0; i < paired; i += 2) {
		promoted[out].value_ms = items[i + parity].value_ms;
		promoted[out].weight = items[i].weight + items[i + 1].weight;
		out++;
	}
	if (has_leftover)
		items[keep++] = leftover;
	sketch->level_count[level] = keep;

	for (i = 0; i < out; i++)
		numa_fault_latency_kll_insert_weighted(sketch, level + 1,
						       promoted[i]);
}

static void numa_fault_latency_kll_insert_weighted(
	struct numa_fault_latency_kll *sketch, unsigned int level,
	struct numa_fault_latency_kll_item item)
{
	if (level >= NUMA_FAULT_LATENCY_KLL_LEVELS)
		level = NUMA_FAULT_LATENCY_KLL_LEVELS - 1;

	while (sketch->level_count[level] >=
	       NUMA_FAULT_LATENCY_KLL_LEVEL_CAPACITY)
		numa_fault_latency_kll_compact_level(sketch, level);

	sketch->levels[level][sketch->level_count[level]++] = item;
}

static void numa_fault_latency_kll_add(struct numa_fault_latency_kll *sketch,
				       u32 seq, unsigned int latency_ms,
				       unsigned long nr_pages)
{
	struct numa_fault_latency_kll_item item = {
		.value_ms = latency_ms,
		.weight = nr_pages,
	};

	if (!seq || !nr_pages)
		return;
	if (sketch->seq != seq)
		numa_fault_latency_kll_reset(sketch, seq);

	sketch->total_weight += nr_pages;
	numa_fault_latency_kll_insert_weighted(sketch, 0, item);
}

static void numa_fault_latency_sketch_add(bool local, u32 seq,
					  unsigned int latency_ms,
					  unsigned long nr_pages)
{
	struct numa_fault_latency_sketch_cpu *pcpu;
	unsigned long flags;

	if (!seq || !nr_pages)
		return;

	pcpu = get_cpu_ptr(&numa_fault_latency_sketch_pcpu);
	spin_lock_irqsave(&pcpu->lock, flags);
	if (local)
		numa_fault_latency_kll_add(&pcpu->local, seq, latency_ms,
					   nr_pages);
	else
		numa_fault_latency_kll_add(&pcpu->remote, seq, latency_ms,
					   nr_pages);
	spin_unlock_irqrestore(&pcpu->lock, flags);
	put_cpu_ptr(pcpu);
}

static unsigned int numa_fault_latency_kll_copy_items(
	struct numa_fault_latency_kll_item *dst, unsigned int capacity,
	const struct numa_fault_latency_kll *sketch)
{
	unsigned int copied = 0, level, i;

	for (level = 0; level < NUMA_FAULT_LATENCY_KLL_LEVELS; level++) {
		for (i = 0; i < sketch->level_count[level]; i++) {
			if (copied >= capacity)
				return copied;
			dst[copied++] = sketch->levels[level][i];
		}
	}

	return copied;
}

static int numa_fault_latency_snapshot_alloc(
	struct numa_fault_latency_sketch_snapshot *snapshot)
{
	unsigned int capacity =
		num_possible_cpus() * NUMA_FAULT_LATENCY_KLL_MAX_ITEMS;

	memset(snapshot, 0, sizeof(*snapshot));
	snapshot->item_capacity = capacity;
	snapshot->local_items = kvcalloc(capacity,
					 sizeof(snapshot->local_items[0]),
					 GFP_KERNEL);
	if (!snapshot->local_items)
		return -ENOMEM;

	snapshot->remote_items = kvcalloc(capacity,
					  sizeof(snapshot->remote_items[0]),
					  GFP_KERNEL);
	if (!snapshot->remote_items) {
		kvfree(snapshot->local_items);
		snapshot->local_items = NULL;
		return -ENOMEM;
	}

	return 0;
}

static void numa_fault_latency_snapshot_free(
	struct numa_fault_latency_sketch_snapshot *snapshot)
{
	kvfree(snapshot->local_items);
	kvfree(snapshot->remote_items);
}

static void numa_fault_latency_snapshot_collect(
	struct numa_fault_latency_sketch_snapshot *snapshot, u32 seq)
{
	struct numa_fault_latency_sketch_cpu *pcpu;
	unsigned long flags;
	unsigned int cpu, copied;

	for_each_possible_cpu(cpu) {
		pcpu = per_cpu_ptr(&numa_fault_latency_sketch_pcpu, cpu);
		spin_lock_irqsave(&pcpu->lock, flags);
		if (pcpu->local.seq == seq) {
			snapshot->local_total += pcpu->local.total_weight;
			copied = numa_fault_latency_kll_copy_items(
				snapshot->local_items +
					snapshot->local_items_count,
				snapshot->item_capacity -
					snapshot->local_items_count,
				&pcpu->local);
			snapshot->local_items_count += copied;
		}
		if (pcpu->remote.seq == seq) {
			snapshot->remote_total += pcpu->remote.total_weight;
			copied = numa_fault_latency_kll_copy_items(
				snapshot->remote_items +
					snapshot->remote_items_count,
				snapshot->item_capacity -
					snapshot->remote_items_count,
				&pcpu->remote);
			snapshot->remote_items_count += copied;
		}
		spin_unlock_irqrestore(&pcpu->lock, flags);
	}

	sort(snapshot->local_items, snapshot->local_items_count,
	     sizeof(snapshot->local_items[0]),
	     numa_fault_latency_kll_item_cmp, NULL);
	sort(snapshot->remote_items, snapshot->remote_items_count,
	     sizeof(snapshot->remote_items[0]),
	     numa_fault_latency_kll_item_cmp, NULL);
}

static u64 numa_fault_latency_sketch_quantile_ppm_ns(
	const struct numa_fault_latency_kll_item *items, unsigned int count,
	u64 total, u32 rank_ppm)
{
	u64 quotient, remainder, threshold, cumulative = 0;
	unsigned int i;

	if (!total || !count || !rank_ppm ||
	    rank_ppm > NUMA_FAULT_LATENCY_PPM)
		return 0;

	/* Calculate ceil(total * rank_ppm / PPM) without overflowing u64. */
	quotient = div64_u64(total, NUMA_FAULT_LATENCY_PPM);
	remainder = total % NUMA_FAULT_LATENCY_PPM;
	threshold = quotient * rank_ppm;
	threshold += div64_u64(remainder * rank_ppm +
			       NUMA_FAULT_LATENCY_PPM - 1,
			       NUMA_FAULT_LATENCY_PPM);

	for (i = 0; i < count; i++) {
		cumulative += items[i].weight;
		if (cumulative >= threshold)
			return numa_fault_latency_ms_to_ns(items[i].value_ms);
	}

	return numa_fault_latency_ms_to_ns(items[count - 1].value_ms);
}

static u64 numa_fault_latency_sketch_cdf_ppm(
	const struct numa_fault_latency_kll_item *items, unsigned int count,
	u64 total, u64 query_ns, bool inclusive)
{
	u64 cumulative = 0;
	unsigned int i;

	if (!total || !count)
		return 0;

	for (i = 0; i < count; i++) {
		u64 value_ns = numa_fault_latency_ms_to_ns(items[i].value_ms);

		if (inclusive ? value_ns > query_ns : value_ns >= query_ns)
			break;
		cumulative += items[i].weight;
	}

	return div64_u64(cumulative * NUMA_FAULT_LATENCY_PPM, total);
}

static void numa_fault_latency_sketch_init(void)
{
	struct numa_fault_latency_sketch_cpu *pcpu;
	unsigned int cpu;

	for_each_possible_cpu(cpu) {
		pcpu = per_cpu_ptr(&numa_fault_latency_sketch_pcpu, cpu);
		spin_lock_init(&pcpu->lock);
		numa_fault_latency_kll_reset(&pcpu->local, 0);
		numa_fault_latency_kll_reset(&pcpu->remote, 0);
	}
}

static int __init numa_fault_latency_sketch_initcall(void)
{
	numa_fault_latency_sketch_init();
	return 0;
}
subsys_initcall(numa_fault_latency_sketch_initcall);

static u32 numa_local_fault_window_advance(void)
{
	int seq = atomic_inc_return(&numa_local_fault_window_seq);

	if (seq > 0)
		return (u32)seq;

	atomic_set(&numa_local_fault_window_seq, 1);
	return 1;
}

static u64 numa_local_fault_read_state(struct folio *folio)
{
	struct numa_local_fault_page_ext *lf_ext;
	struct page_ext *page_ext;
	u64 state;

	if (!folio || folio_nr_pages(folio) != 1)
		return 0;

	page_ext = page_ext_get(&folio->page);
	if (!page_ext)
		return 0;

	lf_ext = page_ext_data(page_ext, &numa_local_fault_page_ext_ops);
	state = atomic64_read(&lf_ext->local_state);
	page_ext_put(page_ext);

	return state;
}

static bool numa_local_fault_seen(struct folio *folio)
{
	return numa_local_fault_read_state(folio) ==
	       numa_local_fault_window_seq_read();
}

static void numa_local_fault_mark_seen(struct folio *folio)
{
	struct numa_local_fault_page_ext *lf_ext;
	struct page_ext *page_ext;

	if (!folio || folio_nr_pages(folio) != 1)
		return;

	page_ext = page_ext_get(&folio->page);
	if (!page_ext)
		return;

	lf_ext = page_ext_data(page_ext, &numa_local_fault_page_ext_ops);
	atomic64_set(&lf_ext->local_state, numa_local_fault_window_seq_read());
	page_ext_put(page_ext);
}

static bool numa_should_sample_local_fault_bias(struct folio *folio,
						unsigned int bias)
{
	u32 rate;

	if (!folio)
		return false;

	if (folio_nr_pages(folio) != 1)
		return false;

	rate = READ_ONCE(numa_local_fault_rate);
	if (!rate)
		return false;
	if (rate > NUMA_LOCAL_FAULT_RATE_MAX)
		rate = NUMA_LOCAL_FAULT_RATE_MAX;

	if (numa_local_fault_seen(folio))
		return false;
	if (!numa_local_fault_select_pfn(folio, rate, bias))
		return false;

	return true;
}

void numa_account_local_fault_pte(struct folio *folio)
{
	numa_local_fault_mark_seen(folio);
}

void numa_account_local_fault_refault(struct folio *folio,
				      unsigned long nr_pages,
				      unsigned int latency_ms)
{
	u32 fault_seq;

	fault_seq = numa_local_fault_window_seq_read();
	numa_local_fault_mark_seen(folio);
	numa_fault_latency_sketch_add(true, fault_seq, latency_ms, nr_pages);
}

void numa_account_remote_fault_latency(struct folio *folio,
				       unsigned long nr_pages,
				       unsigned int latency_ms)
{
	u32 fault_seq;

	if (!numa_local_fault_sampling_enabled() || !folio || !nr_pages ||
	    !folio_use_access_time(folio))
		return;

	fault_seq = numa_local_fault_window_seq_read();
	numa_fault_latency_sketch_add(false, fault_seq, latency_ms, nr_pages);
}

void numa_account_remote_scan_pte(struct mm_struct *mm)
{
	if (!numa_local_fault_sampling_enabled() || !mm)
		return;

	WRITE_ONCE(mm->numa_remote_scan_seen, true);
}

void numa_account_remote_scan_cycle(struct mm_struct *mm)
{
	bool seen;

	if (!mm)
		return;
	if (!numa_local_fault_sampling_enabled()) {
		WRITE_ONCE(mm->numa_remote_scan_seen, false);
		return;
	}

	seen = READ_ONCE(mm->numa_remote_scan_seen);
	if (seen)
		atomic64_inc(&numa_remote_scan_cycles);
	WRITE_ONCE(mm->numa_remote_scan_seen, false);
}

static unsigned long local_fault_max_pfn_scan(unsigned long max_pte_updates,
					      u32 rate,
					      unsigned long node_pages)
{
	u64 max_scan;
	u32 sample_stride;

	if (!max_pte_updates || !rate)
		return 0;

	if (rate > NUMA_LOCAL_FAULT_RATE_MAX)
		rate = NUMA_LOCAL_FAULT_RATE_MAX;

	sample_stride = DIV_ROUND_UP(NUMA_LOCAL_FAULT_RATE_MAX, rate);
	max_scan = (u64)max_pte_updates * sample_stride * 4;
	if (max_scan < max_pte_updates)
		max_scan = max_pte_updates;
	if (max_scan > node_pages)
		max_scan = node_pages;

	return (unsigned long)max_scan;
}

unsigned long task_numa_scan_local_faults(struct task_struct *p, int nid,
					  unsigned long max_pte_updates,
					  struct numa_local_fault_node_state *scan_state)
{
	unsigned long start_pfn, end_pfn, pfn;
	unsigned long installed = 0, scanned = 0, max_scan;
	unsigned int bias;
	u32 rate;

	if (!p || !p->mm || nid < 0 || nid >= nr_node_ids ||
	    !node_state(nid, N_MEMORY) || !max_pte_updates || !scan_state)
		return 0;

	rate = READ_ONCE(numa_local_fault_rate);
	if (!rate)
		return 0;

	start_pfn = node_start_pfn(nid);
	end_pfn = pgdat_end_pfn(NODE_DATA(nid));
	if (start_pfn >= end_pfn)
		return 0;

	pfn = READ_ONCE(scan_state->scan_pfn);
	if (pfn < start_pfn || pfn >= end_pfn)
		pfn = start_pfn;
	bias = READ_ONCE(scan_state->scan_bias);

	max_scan = local_fault_max_pfn_scan(max_pte_updates, rate,
					    end_pfn - start_pfn);
	while (installed < max_pte_updates && scanned < max_scan) {
		struct folio *folio;
		struct page *page;

		if (pfn >= end_pfn) {
			pfn = start_pfn;
			bias++;
		}

		page = pfn_to_online_page(pfn++);
		scanned++;
		if ((scanned & 0x3ff) == 0)
			cond_resched();
		if (!page || page_to_nid(page) != nid || !PageLRU(page))
			continue;

		folio = page_folio(page);
		if (!folio_test_lru(folio) || !folio_try_get(folio))
			continue;
		if (unlikely(page_folio(page) != folio ||
				     !folio_test_lru(folio)) ||
		    folio_nr_pages(folio) != 1 || folio_nid(folio) != nid ||
		    !folio_mapped(folio) ||
		    folio_test_local_tiering_sampled(folio))
			goto put_folio;

		if (numa_should_sample_local_fault_bias(folio, bias) &&
		    folio_try_install_local_tiering_probe(folio, p->mm))
			installed++;

put_folio:
		folio_put(folio);
	}

	if (pfn >= end_pfn) {
		pfn = start_pfn;
		bias++;
	}
	WRITE_ONCE(scan_state->scan_pfn, pfn);
	WRITE_ONCE(scan_state->scan_bias, bias);
	return installed;
}

#ifdef CONFIG_SYSFS
struct numa_balancing_scan_attr {
	struct kobj_attribute kattr;
	unsigned int *value;
	bool allow_zero;
};

static ssize_t numa_balancing_scan_show(struct kobject *kobj,
					struct kobj_attribute *attr, char *buf)
{
	struct numa_balancing_scan_attr *scan_attr =
		container_of(attr, struct numa_balancing_scan_attr, kattr);

	return sysfs_emit(buf, "%u\n", READ_ONCE(*scan_attr->value));
}

static ssize_t numa_balancing_scan_store(struct kobject *kobj,
					 struct kobj_attribute *attr,
					 const char *buf, size_t count)
{
	struct numa_balancing_scan_attr *scan_attr =
		container_of(attr, struct numa_balancing_scan_attr, kattr);
	unsigned int value;
	int ret;

	if (!capable(CAP_SYS_ADMIN))
		return -EPERM;

	ret = kstrtouint(buf, 0, &value);
	if (ret)
		return ret;
	if (!scan_attr->allow_zero && !value)
		return -EINVAL;

	WRITE_ONCE(*scan_attr->value, value);
	return count;
}

#define NUMA_BALANCING_SCAN_ATTR(_name, _value, _allow_zero) \
	static struct numa_balancing_scan_attr _name##_attr = { \
		.kattr = __ATTR(_name, 0644, numa_balancing_scan_show, \
			       numa_balancing_scan_store), \
		.value = &_value, \
		.allow_zero = _allow_zero, \
	}

NUMA_BALANCING_SCAN_ATTR(numa_scan_size_mb,
			 sysctl_numa_balancing_scan_size, false);
NUMA_BALANCING_SCAN_ATTR(numa_scan_period_min_ms,
			 sysctl_numa_balancing_scan_period_min, false);
NUMA_BALANCING_SCAN_ATTR(numa_scan_period_max_ms,
			 sysctl_numa_balancing_scan_period_max, false);
NUMA_BALANCING_SCAN_ATTR(numa_scan_delay_ms,
			 sysctl_numa_balancing_scan_delay, true);

static ssize_t local_fault_rate_show(struct kobject *kobj,
				     struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%u\n", READ_ONCE(numa_local_fault_rate));
}

static ssize_t local_fault_rate_store(struct kobject *kobj,
				      struct kobj_attribute *attr,
				      const char *buf, size_t count)
{
	unsigned int rate;
	int ret;

	if (!capable(CAP_SYS_ADMIN))
		return -EPERM;

	ret = kstrtouint(buf, 0, &rate);
	if (ret)
		return ret;
	if (rate > NUMA_LOCAL_FAULT_RATE_MAX)
		return -EINVAL;

	if (READ_ONCE(numa_local_fault_rate) != rate) {
		WRITE_ONCE(numa_local_fault_rate, rate);
		numa_local_fault_bump_policy_seq();
	}
	return count;
}

static struct kobj_attribute local_fault_rate_attr =
	__ATTR_RW(local_fault_rate);

static ssize_t local_fault_scan_period_ms_show(struct kobject *kobj,
					       struct kobj_attribute *attr,
					       char *buf)
{
	return sysfs_emit(buf, "%u\n",
			  READ_ONCE(numa_local_fault_scan_period_ms));
}

static ssize_t local_fault_scan_period_ms_store(struct kobject *kobj,
						struct kobj_attribute *attr,
						const char *buf, size_t count)
{
	unsigned int period_ms;
	int ret;

	if (!capable(CAP_SYS_ADMIN))
		return -EPERM;

	ret = kstrtouint(buf, 0, &period_ms);
	if (ret)
		return ret;
	if (!period_ms)
		return -EINVAL;

	if (READ_ONCE(numa_local_fault_scan_period_ms) != period_ms) {
		WRITE_ONCE(numa_local_fault_scan_period_ms, period_ms);
		numa_local_fault_bump_policy_seq();
	}
	return count;
}

static struct kobj_attribute local_fault_scan_period_ms_attr =
	__ATTR_RW(local_fault_scan_period_ms);

static ssize_t local_fault_scan_size_mb_show(struct kobject *kobj,
					     struct kobj_attribute *attr,
					     char *buf)
{
	return sysfs_emit(buf, "%u\n",
			  READ_ONCE(numa_local_fault_scan_size_mb));
}

static ssize_t local_fault_scan_size_mb_store(struct kobject *kobj,
					      struct kobj_attribute *attr,
					      const char *buf, size_t count)
{
	unsigned int size_mb;
	int ret;

	if (!capable(CAP_SYS_ADMIN))
		return -EPERM;

	ret = kstrtouint(buf, 0, &size_mb);
	if (ret)
		return ret;
	if (!size_mb)
		return -EINVAL;

	if (READ_ONCE(numa_local_fault_scan_size_mb) != size_mb) {
		WRITE_ONCE(numa_local_fault_scan_size_mb, size_mb);
		numa_local_fault_bump_policy_seq();
	}
	return count;
}

static struct kobj_attribute local_fault_scan_size_mb_attr =
	__ATTR_RW(local_fault_scan_size_mb);

static ssize_t local_fault_window_show(struct kobject *kobj,
				       struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%u\n", numa_local_fault_window_seq_read());
}

static ssize_t local_fault_window_store(struct kobject *kobj,
					struct kobj_attribute *attr,
					const char *buf, size_t count)
{
	unsigned int advance;
	int ret;

	if (!capable(CAP_SYS_ADMIN))
		return -EPERM;

	ret = kstrtouint(buf, 0, &advance);
	if (ret)
		return ret;
	if (!advance)
		return -EINVAL;

	numa_local_fault_window_advance();
	return count;
}

static struct kobj_attribute local_fault_window_attr =
	__ATTR_RW(local_fault_window);

static ssize_t remote_scan_cycles_show(struct kobject *kobj,
				       struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%lld\n",
			  atomic64_read(&numa_remote_scan_cycles));
}

static struct kobj_attribute remote_scan_cycles_attr =
	__ATTR_RO(remote_scan_cycles);

static ssize_t remote_quantile_rank_ppm_show(struct kobject *kobj,
					     struct kobj_attribute *attr,
					     char *buf)
{
	return sysfs_emit(buf, "%u\n",
			  READ_ONCE(numa_remote_quantile_rank_ppm));
}

static ssize_t remote_quantile_rank_ppm_store(struct kobject *kobj,
					      struct kobj_attribute *attr,
					      const char *buf, size_t count)
{
	unsigned int rank_ppm;
	int ret;

	if (!capable(CAP_SYS_ADMIN))
		return -EPERM;

	ret = kstrtouint(buf, 0, &rank_ppm);
	if (ret)
		return ret;
	if (rank_ppm > NUMA_FAULT_LATENCY_PPM)
		return -EINVAL;

	WRITE_ONCE(numa_remote_quantile_rank_ppm, rank_ppm);
	return count;
}

static struct kobj_attribute remote_quantile_rank_ppm_attr =
	__ATTR_RW(remote_quantile_rank_ppm);

static ssize_t fault_latency_quantiles_show(struct kobject *kobj,
					    struct kobj_attribute *attr,
					    char *buf)
{
	u32 remote_query_rank_ppm =
		READ_ONCE(numa_remote_quantile_rank_ppm);
	u32 seq = numa_local_fault_window_seq_read();
	struct numa_fault_latency_sketch_snapshot snapshot;
	u64 local_p75_ns, remote_query_q_ns = 0;
	bool remote_query_valid;
	ssize_t len = 0;
	int ret;

	ret = numa_fault_latency_snapshot_alloc(&snapshot);
	if (ret)
		return ret;
	numa_fault_latency_snapshot_collect(&snapshot, seq);
	local_p75_ns = numa_fault_latency_sketch_quantile_ppm_ns(
		snapshot.local_items, snapshot.local_items_count,
		snapshot.local_total, 750000);
	remote_query_valid = remote_query_rank_ppm &&
		remote_query_rank_ppm <= NUMA_FAULT_LATENCY_PPM &&
		snapshot.remote_total && snapshot.remote_items_count;
	if (remote_query_valid)
		remote_query_q_ns = numa_fault_latency_sketch_quantile_ppm_ns(
			snapshot.remote_items, snapshot.remote_items_count,
			snapshot.remote_total, remote_query_rank_ppm);

	len += sysfs_emit_at(buf, len, "schema quantile_snapshot_v4\n");
	len += sysfs_emit_at(buf, len, "window_seq %u\n", seq);
	len += sysfs_emit_at(buf, len, "algorithm kll_weighted_ms_v1\n");
	len += sysfs_emit_at(buf, len, "value_source sketch_latency_ms_to_ns\n");
	len += sysfs_emit_at(buf, len, "local_total %llu\n",
			     snapshot.local_total);
	len += sysfs_emit_at(buf, len, "remote_total %llu\n",
			     snapshot.remote_total);
	len += sysfs_emit_at(buf, len, "local_q75_ns %llu\n", local_p75_ns);
	len += sysfs_emit_at(buf, len, "remote_query_rank_ppm %u\n",
			     remote_query_rank_ppm);
	len += sysfs_emit_at(buf, len, "remote_query_q_ns %llu\n",
			     remote_query_q_ns);
	len += sysfs_emit_at(buf, len, "remote_query_valid %u\n",
			     remote_query_valid);
	len += sysfs_emit_at(buf, len,
			     "remote_cdf_lt_local_q75_ppm %llu\n",
			     numa_fault_latency_sketch_cdf_ppm(
				     snapshot.remote_items,
				     snapshot.remote_items_count,
				     snapshot.remote_total, local_p75_ns, false));
	len += sysfs_emit_at(buf, len,
			     "remote_cdf_le_local_q75_ppm %llu\n",
			     numa_fault_latency_sketch_cdf_ppm(
				     snapshot.remote_items,
				     snapshot.remote_items_count,
				     snapshot.remote_total, local_p75_ns, true));

	numa_fault_latency_snapshot_free(&snapshot);
	return len;
}

static struct kobj_attribute fault_latency_quantiles_attr =
	__ATTR_RO(fault_latency_quantiles);

static ssize_t migration_enabled_show(struct kobject *kobj,
				      struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%u\n",
			  READ_ONCE(numa_balancing_migration_enabled_state));
}

static ssize_t migration_enabled_store(struct kobject *kobj,
				       struct kobj_attribute *attr,
				       const char *buf, size_t count)
{
	unsigned int enabled;
	int ret;

	if (!capable(CAP_SYS_ADMIN))
		return -EPERM;

	ret = kstrtouint(buf, 0, &enabled);
	if (ret)
		return ret;
	if (enabled > 1)
		return -EINVAL;

	WRITE_ONCE(numa_balancing_migration_enabled_state, enabled);
	return count;
}

static struct kobj_attribute migration_enabled_attr =
	__ATTR_RW(migration_enabled);

static struct attribute *numa_balancing_attrs[] = {
	&numa_scan_size_mb_attr.kattr.attr,
	&numa_scan_period_min_ms_attr.kattr.attr,
	&numa_scan_period_max_ms_attr.kattr.attr,
	&numa_scan_delay_ms_attr.kattr.attr,
	&local_fault_rate_attr.attr,
	&local_fault_scan_period_ms_attr.attr,
	&local_fault_scan_size_mb_attr.attr,
	&local_fault_window_attr.attr,
	&remote_scan_cycles_attr.attr,
	&remote_quantile_rank_ppm_attr.attr,
	&fault_latency_quantiles_attr.attr,
	&migration_enabled_attr.attr,
	NULL,
};

static const struct attribute_group numa_balancing_attr_group = {
	.attrs = numa_balancing_attrs,
};

static int __init numa_balancing_sysfs_init(void)
{
	struct kobject *numa_balancing_kobj;
	int ret;

	numa_balancing_kobj = kobject_create_and_add("numa_balancing", mm_kobj);
	if (!numa_balancing_kobj)
		return -ENOMEM;

	ret = sysfs_create_group(numa_balancing_kobj,
				 &numa_balancing_attr_group);
	if (ret) {
		kobject_put(numa_balancing_kobj);
		return ret;
	}

	return 0;
}
subsys_initcall(numa_balancing_sysfs_init);
#endif /* CONFIG_SYSFS */
