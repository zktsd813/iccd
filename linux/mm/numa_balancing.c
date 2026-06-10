// SPDX-License-Identifier: GPL-2.0
#include <linux/atomic.h>
#include <linux/capability.h>
#include <linux/jiffies.h>
#include <linux/kobject.h>
#include <linux/memory-tiers.h>
#include <linux/memory_hotplug.h>
#include <linux/mm.h>
#include <linux/mmzone.h>
#include <linux/page_ext.h>
#include <linux/rmap.h>
#include <linux/sched.h>
#include <linux/sched/numa_balancing.h>
#include <linux/sched/sysctl.h>
#include <linux/sysfs.h>

#include "internal.h"

#define NUMA_LOCAL_FAULT_RATE_MAX		100U
#define NUMA_LOCAL_FAULT_SCAN_PERIOD_MS_DEF	1000U
#define NUMA_LOCAL_FAULT_SCAN_SIZE_MB_DEF	256U
#define NUMA_LOCAL_FAULT_WINDOW_BUCKETS		64
#define NUMA_FAULT_LATENCY_HIST_BUCKETS		11
#define NUMA_FAULT_LATENCY_LE_BUCKETS		\
	(NUMA_FAULT_LATENCY_HIST_BUCKETS - 1)

struct numa_local_fault_page_ext {
	atomic64_t local_state;
	atomic64_t remote_state;
	atomic64_t remote_sample_state;
};

struct numa_local_fault_window_bucket {
	atomic_t seq;
	atomic64_t pte_updates;
	atomic64_t refault;
	atomic64_t lost;
	atomic64_t local_latency[NUMA_FAULT_LATENCY_HIST_BUCKETS];
	atomic64_t remote_latency[NUMA_FAULT_LATENCY_HIST_BUCKETS];
};

static const unsigned int
numa_fault_latency_bounds_ms[NUMA_FAULT_LATENCY_LE_BUCKETS] = {
	1, 16, 64, 128, 256, 512, 1024, 2048, 4096, 8192,
};

static u32 numa_local_fault_rate;
static u32 numa_remote_fault_rate;
static u32 numa_local_fault_scan_period_ms =
	NUMA_LOCAL_FAULT_SCAN_PERIOD_MS_DEF;
static u32 numa_local_fault_scan_size_mb =
	NUMA_LOCAL_FAULT_SCAN_SIZE_MB_DEF;
static u32 numa_remote_fault_scan_period_ms =
	NUMA_LOCAL_FAULT_SCAN_PERIOD_MS_DEF;
static u32 numa_remote_fault_scan_size_mb =
	NUMA_LOCAL_FAULT_SCAN_SIZE_MB_DEF;
static atomic_long_t numa_local_fault_policy_seq = ATOMIC_LONG_INIT(1);
static atomic_t numa_local_fault_window_seq = ATOMIC_INIT(1);
static struct numa_local_fault_window_bucket
	numa_local_fault_buckets[NUMA_LOCAL_FAULT_WINDOW_BUCKETS];

static atomic64_t numa_local_fault_pfn_candidates;
static atomic64_t numa_local_fault_pfn_selected;
static atomic64_t numa_local_fault_sampled;
static atomic64_t numa_local_fault_pte_updates;
static atomic64_t numa_local_fault_refault;
static atomic64_t numa_local_fault_lost;
static atomic64_t numa_local_fault_refault_total_ms;
static atomic64_t numa_local_fault_node_scan_attempts[MAX_NUMNODES];
static atomic64_t numa_local_fault_node_pte_updates[MAX_NUMNODES];
static atomic64_t numa_local_fault_node_target_misses[MAX_NUMNODES];
static atomic64_t numa_local_fault_retargets;
static atomic_t numa_local_fault_last_target_nid = ATOMIC_INIT(NUMA_NO_NODE);

static atomic64_t numa_remote_fault_pfn_candidates;
static atomic64_t numa_remote_fault_pfn_selected;
static atomic64_t numa_remote_fault_sampled_pages;
static atomic64_t numa_remote_fault_pte_updates;
static atomic64_t numa_remote_fault_refault;
static atomic64_t numa_remote_fault_refault_total_ms;
static atomic64_t numa_remote_fault_node_scan_attempts[MAX_NUMNODES];
static atomic64_t numa_remote_fault_node_pte_updates[MAX_NUMNODES];
static atomic_t numa_remote_fault_last_target_nid = ATOMIC_INIT(NUMA_NO_NODE);

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

bool numa_remote_fault_sampling_enabled(void)
{
	return READ_ONCE(numa_remote_fault_rate) > 0;
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

unsigned int task_numa_remote_fault_scan_period_ms(struct task_struct *p)
{
	if (!p || !p->mm || READ_ONCE(sysctl_numa_balancing_mode) > 0 ||
	    !numa_remote_fault_sampling_enabled())
		return 0;

	return READ_ONCE(numa_remote_fault_scan_period_ms);
}

unsigned int task_numa_remote_fault_scan_size_mb(struct task_struct *p)
{
	if (!p || !p->mm || READ_ONCE(sysctl_numa_balancing_mode) > 0 ||
	    !numa_remote_fault_sampling_enabled())
		return 0;

	return READ_ONCE(numa_remote_fault_scan_size_mb);
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

static struct numa_local_fault_window_bucket *
numa_local_fault_bucket(u32 seq)
{
	return &numa_local_fault_buckets[seq % NUMA_LOCAL_FAULT_WINDOW_BUCKETS];
}

static unsigned int numa_fault_latency_bucket(unsigned int latency_ms)
{
	unsigned int i;

	for (i = 0; i < NUMA_FAULT_LATENCY_LE_BUCKETS; i++) {
		if (latency_ms <= numa_fault_latency_bounds_ms[i])
			return i;
	}
	return NUMA_FAULT_LATENCY_HIST_BUCKETS - 1;
}

static void numa_fault_latency_hist_reset(atomic64_t *hist)
{
	unsigned int i;

	for (i = 0; i < NUMA_FAULT_LATENCY_HIST_BUCKETS; i++)
		atomic64_set(&hist[i], 0);
}

static void numa_fault_latency_hist_add(atomic64_t *hist,
					unsigned int latency_ms,
					unsigned long nr_pages)
{
	atomic64_add(nr_pages,
		     &hist[numa_fault_latency_bucket(latency_ms)]);
}

static void numa_local_fault_bucket_reset(u32 seq)
{
	struct numa_local_fault_window_bucket *bucket;

	if (!seq)
		return;

	bucket = numa_local_fault_bucket(seq);
	atomic_set(&bucket->seq, 0);
	atomic64_set(&bucket->pte_updates, 0);
	atomic64_set(&bucket->refault, 0);
	atomic64_set(&bucket->lost, 0);
	numa_fault_latency_hist_reset(bucket->local_latency);
	numa_fault_latency_hist_reset(bucket->remote_latency);
	smp_wmb();
	atomic_set(&bucket->seq, seq);
}

static bool numa_local_fault_bucket_valid(u32 seq)
{
	struct numa_local_fault_window_bucket *bucket;

	if (!seq)
		return false;

	bucket = numa_local_fault_bucket(seq);
	return atomic_read(&bucket->seq) == seq;
}

static void numa_local_fault_bucket_add_pte(u32 seq, unsigned long nr_pages)
{
	if (numa_local_fault_bucket_valid(seq))
		atomic64_add(nr_pages,
			     &numa_local_fault_bucket(seq)->pte_updates);
}

static void numa_local_fault_bucket_add_refault(u32 seq,
						unsigned long nr_pages)
{
	struct numa_local_fault_window_bucket *bucket;

	if (!numa_local_fault_bucket_valid(seq))
		return;

	bucket = numa_local_fault_bucket(seq);
	atomic64_add(nr_pages, &bucket->refault);
}

static void numa_local_fault_bucket_add_lost(u32 seq, unsigned long nr_pages)
{
	if (numa_local_fault_bucket_valid(seq))
		atomic64_add(nr_pages,
			     &numa_local_fault_bucket(seq)->lost);
}

static u32 numa_local_fault_window_advance(void)
{
	int seq = atomic_inc_return(&numa_local_fault_window_seq);

	if (seq > 0) {
		numa_local_fault_bucket_reset((u32)seq);
		return (u32)seq;
	}

	atomic_set(&numa_local_fault_window_seq, 1);
	numa_local_fault_bucket_reset(1);
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

static u64 numa_remote_fault_sample_read_state(struct folio *folio)
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
	state = atomic64_read(&lf_ext->remote_sample_state);
	page_ext_put(page_ext);

	return state;
}

static bool numa_local_fault_seen(struct folio *folio)
{
	return numa_local_fault_read_state(folio) ==
	       numa_local_fault_window_seq_read();
}

static bool numa_remote_fault_sample_eligible(struct folio *folio)
{
	return folio && node_is_promotion_source(folio_nid(folio));
}

static bool numa_remote_fault_sample_seen(struct folio *folio)
{
	return numa_remote_fault_sample_read_state(folio) ==
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

static void numa_remote_fault_sample_mark_seen(struct folio *folio)
{
	struct numa_local_fault_page_ext *lf_ext;
	struct page_ext *page_ext;

	if (!folio || folio_nr_pages(folio) != 1)
		return;

	page_ext = page_ext_get(&folio->page);
	if (!page_ext)
		return;

	lf_ext = page_ext_data(page_ext, &numa_local_fault_page_ext_ops);
	atomic64_set(&lf_ext->remote_sample_state,
		     numa_local_fault_window_seq_read());
	page_ext_put(page_ext);
}

static void numa_remote_fault_mark_seen(struct folio *folio)
{
	struct numa_local_fault_page_ext *lf_ext;
	struct page_ext *page_ext;

	if (!folio)
		return;

	page_ext = page_ext_get(&folio->page);
	if (!page_ext)
		return;

	lf_ext = page_ext_data(page_ext, &numa_local_fault_page_ext_ops);
	atomic64_set(&lf_ext->remote_state,
		     numa_local_fault_window_seq_read());
	page_ext_put(page_ext);
}

static bool numa_should_sample_local_fault_bias(struct folio *folio,
						unsigned int bias)
{
	unsigned long nr_pages;
	u32 rate;

	if (!folio)
		return false;

	nr_pages = folio_nr_pages(folio);
	if (nr_pages != 1)
		return false;

	rate = READ_ONCE(numa_local_fault_rate);
	if (!rate)
		return false;
	if (rate > NUMA_LOCAL_FAULT_RATE_MAX)
		rate = NUMA_LOCAL_FAULT_RATE_MAX;

	atomic64_add(nr_pages, &numa_local_fault_pfn_candidates);
	if (numa_local_fault_seen(folio))
		return false;
	if (!numa_local_fault_select_pfn(folio, rate, bias))
		return false;

	atomic64_add(nr_pages, &numa_local_fault_pfn_selected);
	return true;
}

bool numa_should_sample_local_fault(struct folio *folio)
{
	return numa_should_sample_local_fault_bias(folio, 0);
}

bool numa_remote_fault_sampled(struct folio *folio)
{
	u32 seq;

	if (!numa_remote_fault_sample_eligible(folio))
		return false;

	seq = (u32)numa_remote_fault_sample_read_state(folio);
	return seq && numa_local_fault_bucket_valid(seq);
}

bool numa_should_sample_remote_fault(struct folio *folio, unsigned int bias)
{
	unsigned long nr_pages;
	u32 rate;

	if (!numa_remote_fault_sample_eligible(folio))
		return false;

	nr_pages = folio_nr_pages(folio);
	if (nr_pages != 1)
		return false;

	rate = READ_ONCE(numa_remote_fault_rate);
	if (!rate)
		return false;
	if (rate > NUMA_LOCAL_FAULT_RATE_MAX)
		rate = NUMA_LOCAL_FAULT_RATE_MAX;

	atomic64_add(nr_pages, &numa_remote_fault_pfn_candidates);
	if (numa_remote_fault_sample_seen(folio))
		return false;
	if (!numa_local_fault_select_pfn(folio, rate, bias))
		return false;

	atomic64_add(nr_pages, &numa_remote_fault_pfn_selected);
	return true;
}

void numa_account_local_fault_pte(struct folio *folio, unsigned long nr_pages)
{
	u32 seq;

	atomic64_add(nr_pages, &numa_local_fault_sampled);
	atomic64_add(nr_pages, &numa_local_fault_pte_updates);
	seq = numa_local_fault_window_seq_read();
	numa_local_fault_bucket_add_pte(seq, nr_pages);
	numa_local_fault_mark_seen(folio);
}

void numa_account_local_fault_refault(struct folio *folio,
				      unsigned long nr_pages,
				      unsigned int latency_ms)
{
	u32 fault_seq;

	fault_seq = numa_local_fault_window_seq_read();
	atomic64_add(nr_pages, &numa_local_fault_refault);
	numa_local_fault_mark_seen(folio);
	atomic64_add((u64)nr_pages * latency_ms,
		     &numa_local_fault_refault_total_ms);
	numa_local_fault_bucket_add_refault(fault_seq, nr_pages);
	if (numa_local_fault_bucket_valid(fault_seq))
		numa_fault_latency_hist_add(
			numa_local_fault_bucket(fault_seq)->local_latency,
			latency_ms, nr_pages);
}

void numa_account_local_fault_lost(struct folio *folio, unsigned long nr_pages)
{
	u32 seq = (u32)numa_local_fault_read_state(folio);

	atomic64_add(nr_pages, &numa_local_fault_lost);
	numa_local_fault_bucket_add_lost(seq, nr_pages);
}

void numa_account_remote_fault_pte(struct folio *folio, unsigned long nr_pages)
{
	if (!folio || !nr_pages || !folio_use_access_time(folio))
		return;

	numa_remote_fault_mark_seen(folio);
}

void numa_account_remote_fault_latency(struct folio *folio,
				       unsigned long nr_pages,
				       unsigned int latency_ms)
{
	u32 fault_seq;

	if (!folio || !nr_pages || !folio_use_access_time(folio))
		return;

	fault_seq = numa_local_fault_window_seq_read();
	if (numa_local_fault_bucket_valid(fault_seq))
		numa_fault_latency_hist_add(
			numa_local_fault_bucket(fault_seq)->remote_latency,
			latency_ms, nr_pages);
}

void numa_account_remote_fault_sample_pte(struct folio *folio,
					  unsigned long nr_pages)
{
	if (!numa_remote_fault_sample_eligible(folio) || !nr_pages)
		return;

	atomic64_add(nr_pages, &numa_remote_fault_sampled_pages);
	atomic64_add(nr_pages, &numa_remote_fault_pte_updates);
	numa_remote_fault_sample_mark_seen(folio);
}

void numa_account_remote_fault_sample_refault(struct folio *folio,
					      unsigned long nr_pages,
					      unsigned int latency_ms)
{
	u32 fault_seq;

	if (!numa_remote_fault_sample_eligible(folio) || !nr_pages)
		return;

	fault_seq = numa_local_fault_window_seq_read();
	atomic64_add(nr_pages, &numa_remote_fault_refault);
	atomic64_add((u64)nr_pages * latency_ms,
		     &numa_remote_fault_refault_total_ms);
	if (numa_local_fault_bucket_valid(fault_seq))
		numa_fault_latency_hist_add(
			numa_local_fault_bucket(fault_seq)->remote_latency,
			latency_ms, nr_pages);
	numa_remote_fault_sample_mark_seen(folio);
}

void numa_account_local_fault_scan(int nid, unsigned long nr_pages)
{
	if (nid < 0 || nid >= MAX_NUMNODES)
		return;

	atomic_set(&numa_local_fault_last_target_nid, nid);
	atomic64_inc(&numa_local_fault_node_scan_attempts[nid]);
	if (nr_pages)
		atomic64_add(nr_pages,
			     &numa_local_fault_node_pte_updates[nid]);
}

void numa_account_remote_fault_scan(int nid, unsigned long nr_pages)
{
	if (nid < 0 || nid >= MAX_NUMNODES)
		return;

	atomic_set(&numa_remote_fault_last_target_nid, nid);
	atomic64_inc(&numa_remote_fault_node_scan_attempts[nid]);
	if (nr_pages)
		atomic64_add(nr_pages,
			     &numa_remote_fault_node_pte_updates[nid]);
}

void numa_account_local_fault_target_miss(int nid)
{
	if (nid < 0 || nid >= MAX_NUMNODES)
		return;

	atomic_set(&numa_local_fault_last_target_nid, nid);
	atomic64_inc(&numa_local_fault_node_target_misses[nid]);
}

void numa_account_local_fault_retarget(int from_nid, int to_nid)
{
	if (to_nid >= 0 && to_nid < MAX_NUMNODES)
		atomic_set(&numa_local_fault_last_target_nid, to_nid);

	atomic64_inc(&numa_local_fault_retargets);
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
			     !folio_test_lru(folio)))
			goto put_folio;
		if (folio_nr_pages(folio) != 1 || folio_nid(folio) != nid ||
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

unsigned long task_numa_scan_remote_faults(struct task_struct *p, int nid,
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

	rate = READ_ONCE(numa_remote_fault_rate);
	if (!rate)
		return 0;

	start_pfn = node_start_pfn(nid);
	end_pfn = pgdat_end_pfn(NODE_DATA(nid));
	if (start_pfn >= end_pfn)
		return 0;

	pfn = READ_ONCE(scan_state->remote_scan_pfn);
	if (pfn < start_pfn || pfn >= end_pfn)
		pfn = start_pfn;
	bias = READ_ONCE(scan_state->remote_scan_bias);

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
			     !folio_test_lru(folio)))
			goto put_folio;
		if (folio_nr_pages(folio) != 1 || folio_nid(folio) != nid ||
		    !folio_mapped(folio) ||
		    !numa_remote_fault_sample_eligible(folio))
			goto put_folio;

		if (numa_should_sample_remote_fault(folio, bias) &&
		    folio_try_install_remote_tiering_probe(folio, p->mm))
			installed++;

put_folio:
		folio_put(folio);
	}

	if (pfn >= end_pfn) {
		pfn = start_pfn;
		bias++;
	}
	WRITE_ONCE(scan_state->remote_scan_pfn, pfn);
	WRITE_ONCE(scan_state->remote_scan_bias, bias);
	return installed;
}

#ifdef CONFIG_SYSFS
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

static ssize_t remote_fault_rate_show(struct kobject *kobj,
				      struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%u\n", READ_ONCE(numa_remote_fault_rate));
}

static ssize_t remote_fault_rate_store(struct kobject *kobj,
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

	if (READ_ONCE(numa_remote_fault_rate) != rate) {
		WRITE_ONCE(numa_remote_fault_rate, rate);
		numa_local_fault_bump_policy_seq();
	}
	return count;
}

static struct kobj_attribute remote_fault_rate_attr =
	__ATTR_RW(remote_fault_rate);

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

static ssize_t remote_fault_scan_period_ms_show(struct kobject *kobj,
						struct kobj_attribute *attr,
						char *buf)
{
	return sysfs_emit(buf, "%u\n",
			  READ_ONCE(numa_remote_fault_scan_period_ms));
}

static ssize_t remote_fault_scan_period_ms_store(struct kobject *kobj,
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

	if (READ_ONCE(numa_remote_fault_scan_period_ms) != period_ms) {
		WRITE_ONCE(numa_remote_fault_scan_period_ms, period_ms);
		numa_local_fault_bump_policy_seq();
	}
	return count;
}

static struct kobj_attribute remote_fault_scan_period_ms_attr =
	__ATTR_RW(remote_fault_scan_period_ms);

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

static ssize_t remote_fault_scan_size_mb_show(struct kobject *kobj,
					      struct kobj_attribute *attr,
					      char *buf)
{
	return sysfs_emit(buf, "%u\n",
			  READ_ONCE(numa_remote_fault_scan_size_mb));
}

static ssize_t remote_fault_scan_size_mb_store(struct kobject *kobj,
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

	if (READ_ONCE(numa_remote_fault_scan_size_mb) != size_mb) {
		WRITE_ONCE(numa_remote_fault_scan_size_mb, size_mb);
		numa_local_fault_bump_policy_seq();
	}
	return count;
}

static struct kobj_attribute remote_fault_scan_size_mb_attr =
	__ATTR_RW(remote_fault_scan_size_mb);

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

static ssize_t local_fault_stats_show(struct kobject *kobj,
				      struct kobj_attribute *attr, char *buf)
{
	u64 sampled = atomic64_read(&numa_local_fault_sampled);
	u64 candidates = atomic64_read(&numa_local_fault_pfn_candidates);
	u64 selected = atomic64_read(&numa_local_fault_pfn_selected);
	u64 refault = atomic64_read(&numa_local_fault_refault);
	u64 refault_total_ms =
		atomic64_read(&numa_local_fault_refault_total_ms);
	u64 selected_bp = candidates ?
		div64_u64(selected * 10000, candidates) : 0;
	u64 refault_rate_pct = sampled ?
		div64_u64(refault * 100, sampled) : 0;
	u64 refault_avg_us = refault ?
		div64_u64(refault_total_ms * 1000, refault) : 0;
	u32 seq = numa_local_fault_window_seq_read();
	struct numa_local_fault_window_bucket *bucket =
		numa_local_fault_bucket(seq);
	u64 window_pte_updates = 0;
	u64 window_refault = 0;
	u64 window_lost = 0;
	ssize_t len = 0;
	int nid;

	if (numa_local_fault_bucket_valid(seq)) {
		window_pte_updates = atomic64_read(&bucket->pte_updates);
		window_refault = atomic64_read(&bucket->refault);
		window_lost = atomic64_read(&bucket->lost);
	}

	len += sysfs_emit_at(buf, len, "local_fault_rate %u\n",
			     READ_ONCE(numa_local_fault_rate));
	len += sysfs_emit_at(buf, len, "local_fault_scan_period_ms %u\n",
			     READ_ONCE(numa_local_fault_scan_period_ms));
	len += sysfs_emit_at(buf, len, "local_fault_scan_size_mb %u\n",
			     READ_ONCE(numa_local_fault_scan_size_mb));
	len += sysfs_emit_at(buf, len, "local_fault_window_seq %u\n", seq);
	len += sysfs_emit_at(buf, len, "local_fault_pfn_candidates %llu\n",
			     candidates);
	len += sysfs_emit_at(buf, len, "local_fault_pfn_selected %llu\n",
			     selected);
	len += sysfs_emit_at(buf, len, "local_fault_pfn_selected_bp %llu\n",
			     selected_bp);
	len += sysfs_emit_at(buf, len, "local_fault_sampled %llu\n",
			     sampled);
	len += sysfs_emit_at(buf, len, "local_fault_pte_updates %lld\n",
			     atomic64_read(&numa_local_fault_pte_updates));
	len += sysfs_emit_at(buf, len, "local_fault_refault %llu\n",
			     refault);
	len += sysfs_emit_at(buf, len, "local_fault_refault_total_ms %llu\n",
			     refault_total_ms);
	len += sysfs_emit_at(buf, len, "local_fault_lost %lld\n",
			     atomic64_read(&numa_local_fault_lost));
	len += sysfs_emit_at(buf, len, "local_fault_refault_rate_pct %llu\n",
			     refault_rate_pct);
	len += sysfs_emit_at(buf, len, "local_fault_refault_avg_us %llu\n",
			     refault_avg_us);
	len += sysfs_emit_at(buf, len, "local_fault_window_pte_updates %llu\n",
			     window_pte_updates);
	len += sysfs_emit_at(buf, len, "local_fault_window_refault %llu\n",
			     window_refault);
	len += sysfs_emit_at(buf, len, "local_fault_window_lost %llu\n",
			     window_lost);
	len += sysfs_emit_at(buf, len, "local_fault_rr_last_target_nid %d\n",
			     atomic_read(&numa_local_fault_last_target_nid));
	len += sysfs_emit_at(buf, len, "local_fault_rr_retargets %lld\n",
			     atomic64_read(&numa_local_fault_retargets));
	for_each_online_node(nid) {
		len += sysfs_emit_at(buf, len,
				     "local_fault_node%d_scan_attempts %lld\n",
				     nid,
				     atomic64_read(&numa_local_fault_node_scan_attempts[nid]));
		len += sysfs_emit_at(buf, len,
				     "local_fault_node%d_pte_updates %lld\n",
				     nid,
				     atomic64_read(&numa_local_fault_node_pte_updates[nid]));
		len += sysfs_emit_at(buf, len,
				     "local_fault_node%d_target_misses %lld\n",
				     nid,
				     atomic64_read(&numa_local_fault_node_target_misses[nid]));
	}

	return len;
}

static struct kobj_attribute local_fault_stats_attr =
	__ATTR_RO(local_fault_stats);

static ssize_t remote_fault_stats_show(struct kobject *kobj,
				       struct kobj_attribute *attr, char *buf)
{
	u64 sampled = atomic64_read(&numa_remote_fault_sampled_pages);
	u64 candidates = atomic64_read(&numa_remote_fault_pfn_candidates);
	u64 selected = atomic64_read(&numa_remote_fault_pfn_selected);
	u64 refault = atomic64_read(&numa_remote_fault_refault);
	u64 refault_total_ms =
		atomic64_read(&numa_remote_fault_refault_total_ms);
	u64 selected_bp = candidates ?
		div64_u64(selected * 10000, candidates) : 0;
	u64 refault_rate_pct = sampled ?
		div64_u64(refault * 100, sampled) : 0;
	u64 refault_avg_us = refault ?
		div64_u64(refault_total_ms * 1000, refault) : 0;
	ssize_t len = 0;
	int nid;

	len += sysfs_emit_at(buf, len, "remote_fault_rate %u\n",
			     READ_ONCE(numa_remote_fault_rate));
	len += sysfs_emit_at(buf, len, "remote_fault_scan_period_ms %u\n",
			     READ_ONCE(numa_remote_fault_scan_period_ms));
	len += sysfs_emit_at(buf, len, "remote_fault_scan_size_mb %u\n",
			     READ_ONCE(numa_remote_fault_scan_size_mb));
	len += sysfs_emit_at(buf, len, "remote_fault_window_seq %u\n",
			     numa_local_fault_window_seq_read());
	len += sysfs_emit_at(buf, len, "remote_fault_pfn_candidates %llu\n",
			     candidates);
	len += sysfs_emit_at(buf, len, "remote_fault_pfn_selected %llu\n",
			     selected);
	len += sysfs_emit_at(buf, len, "remote_fault_pfn_selected_bp %llu\n",
			     selected_bp);
	len += sysfs_emit_at(buf, len, "remote_fault_sampled %llu\n",
			     sampled);
	len += sysfs_emit_at(buf, len, "remote_fault_pte_updates %lld\n",
			     atomic64_read(&numa_remote_fault_pte_updates));
	len += sysfs_emit_at(buf, len, "remote_fault_refault %llu\n",
			     refault);
	len += sysfs_emit_at(buf, len, "remote_fault_refault_total_ms %llu\n",
			     refault_total_ms);
	len += sysfs_emit_at(buf, len, "remote_fault_refault_rate_pct %llu\n",
			     refault_rate_pct);
	len += sysfs_emit_at(buf, len, "remote_fault_refault_avg_us %llu\n",
			     refault_avg_us);
	len += sysfs_emit_at(buf, len, "remote_fault_rr_last_target_nid %d\n",
			     atomic_read(&numa_remote_fault_last_target_nid));
	for_each_online_node(nid) {
		len += sysfs_emit_at(buf, len,
				     "remote_fault_node%d_scan_attempts %lld\n",
				     nid,
				     atomic64_read(&numa_remote_fault_node_scan_attempts[nid]));
		len += sysfs_emit_at(buf, len,
				     "remote_fault_node%d_pte_updates %lld\n",
				     nid,
				     atomic64_read(&numa_remote_fault_node_pte_updates[nid]));
	}

	return len;
}

static struct kobj_attribute remote_fault_stats_attr =
	__ATTR_RO(remote_fault_stats);

static ssize_t fault_latency_histograms_show(struct kobject *kobj,
					     struct kobj_attribute *attr,
					     char *buf)
{
	u32 seq = numa_local_fault_window_seq_read();
	struct numa_local_fault_window_bucket *bucket =
		numa_local_fault_bucket(seq);
	u64 local[NUMA_FAULT_LATENCY_HIST_BUCKETS] = { 0 };
	u64 remote[NUMA_FAULT_LATENCY_HIST_BUCKETS] = { 0 };
	ssize_t len = 0;
	unsigned int i;

	if (numa_local_fault_bucket_valid(seq)) {
		for (i = 0; i < NUMA_FAULT_LATENCY_HIST_BUCKETS; i++) {
			local[i] = atomic64_read(&bucket->local_latency[i]);
			remote[i] = atomic64_read(&bucket->remote_latency[i]);
		}
	}

	len += sysfs_emit_at(buf, len, "window_seq %u\n", seq);
	len += sysfs_emit_at(buf, len,
			     "bucket_ms le_1 le_16 le_64 le_128 le_256 le_512 le_1024 le_2048 le_4096 le_8192 gt_8192\n");
	len += sysfs_emit_at(buf, len, "local_pages");
	for (i = 0; i < NUMA_FAULT_LATENCY_HIST_BUCKETS; i++)
		len += sysfs_emit_at(buf, len, " %llu", local[i]);
	len += sysfs_emit_at(buf, len, "\nremote_pages");
	for (i = 0; i < NUMA_FAULT_LATENCY_HIST_BUCKETS; i++)
		len += sysfs_emit_at(buf, len, " %llu", remote[i]);
	len += sysfs_emit_at(buf, len, "\n");

	return len;
}

static struct kobj_attribute fault_latency_histograms_attr =
	__ATTR_RO(fault_latency_histograms);

static struct attribute *numa_balancing_attrs[] = {
	&local_fault_rate_attr.attr,
	&remote_fault_rate_attr.attr,
	&local_fault_scan_period_ms_attr.attr,
	&remote_fault_scan_period_ms_attr.attr,
	&local_fault_scan_size_mb_attr.attr,
	&remote_fault_scan_size_mb_attr.attr,
	&local_fault_window_attr.attr,
	&local_fault_stats_attr.attr,
	&remote_fault_stats_attr.attr,
	&fault_latency_histograms_attr.attr,
	NULL,
};

static const struct attribute_group numa_balancing_attr_group = {
	.attrs = numa_balancing_attrs,
};

static int __init numa_balancing_sysfs_init(void)
{
	struct kobject *numa_balancing_kobj;
	int ret;

	numa_local_fault_bucket_reset(1);

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
