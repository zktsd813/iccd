// SPDX-License-Identifier: GPL-2.0
/*
 * Debugfs reuse-time histogram for NUMA promotion candidates.
 *
 * The recorder is intentionally target-cgroup scoped.  It does not record
 * anything until a target memory cgroup and source NUMA node mask are set.
 */
#include <linux/bitops.h>
#include <linux/cgroup.h>
#include <linux/debugfs.h>
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/jiffies.h>
#include <linux/jump_label.h>
#include <linux/kernel.h>
#include <linux/memcontrol.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/nodemask.h>
#include <linux/percpu.h>
#include <linux/rcupdate.h>
#include <linux/sched.h>
#include <linux/seq_file.h>
#include <linux/slab.h>
#include <linux/uaccess.h>

#include "sched.h"

#define RT_LINEAR_TICK_BUCKETS 1024
#define RT_OVERFLOW_BUCKETS 1
#define RT_NR_BUCKETS (RT_LINEAR_TICK_BUCKETS + RT_OVERFLOW_BUCKETS + 1)
#define RT_SOURCE_NIDS_MAX 64
#define RT_DIR_NAME "reuse_time"

struct reuse_time_config {
	struct rcu_head rcu;
	struct mem_cgroup *target_memcg;
	nodemask_t source_nids;
	char source_nids_param[RT_SOURCE_NIDS_MAX];
	bool enabled;
	bool match_descendants;
};

struct reuse_time_cpu_stats {
	u64 buckets[RT_NR_BUCKETS];
	u64 total_calls;
	u64 recorded;
	u64 ignored_disabled;
	u64 ignored_null;
	u64 ignored_no_target;
	u64 ignored_cgroup;
	u64 ignored_no_balancing;
	u64 ignored_untracked_node;
};

static DEFINE_PER_CPU(struct reuse_time_cpu_stats, reuse_time_stats);
static DEFINE_MUTEX(reuse_time_config_lock);
static struct reuse_time_config __rcu *reuse_time_current_config;
static struct dentry *reuse_time_dir;
DEFINE_STATIC_KEY_FALSE(sched_reuse_time_key);
static bool reuse_time_key_enabled;

static bool reuse_time_config_active(const struct reuse_time_config *config)
{
	return config && config->enabled && config->target_memcg &&
		!nodes_empty(config->source_nids);
}

static void reuse_time_update_static_key_locked(const struct reuse_time_config *config)
{
	bool active = reuse_time_config_active(config);

	if (active == reuse_time_key_enabled)
		return;

	if (active)
		static_branch_enable(&sched_reuse_time_key);
	else
		static_branch_disable(&sched_reuse_time_key);

	reuse_time_key_enabled = active;
}

static void reuse_time_put_config(struct reuse_time_config *config)
{
	if (!config)
		return;

	if (config->target_memcg)
		mem_cgroup_put(config->target_memcg);
	kfree(config);
}

static void reuse_time_free_config_rcu(struct rcu_head *rcu)
{
	struct reuse_time_config *config =
		container_of(rcu, struct reuse_time_config, rcu);

	reuse_time_put_config(config);
}

static struct reuse_time_config *
reuse_time_publish_config_locked(struct reuse_time_config *new_config)
{
	struct reuse_time_config *old_config;

	old_config = rcu_dereference_protected(reuse_time_current_config,
					       lockdep_is_held(&reuse_time_config_lock));
	rcu_assign_pointer(reuse_time_current_config, new_config);
	return old_config;
}

static void reuse_time_put_old_config(struct reuse_time_config *old_config)
{
	if (old_config)
		call_rcu(&old_config->rcu, reuse_time_free_config_rcu);
}

static struct reuse_time_config *reuse_time_clone_config_locked(bool preserve_target)
{
	struct reuse_time_config *old_config;
	struct reuse_time_config *new_config;

	new_config = kzalloc(sizeof(*new_config), GFP_KERNEL);
	if (!new_config)
		return NULL;

	old_config = rcu_dereference_protected(reuse_time_current_config,
					       lockdep_is_held(&reuse_time_config_lock));
	if (old_config) {
		*new_config = *old_config;
		memset(&new_config->rcu, 0, sizeof(new_config->rcu));
		if (!preserve_target) {
			new_config->target_memcg = NULL;
		} else if (new_config->target_memcg &&
		    !mem_cgroup_tryget(new_config->target_memcg)) {
			kfree(new_config);
			return NULL;
		}
	} else {
		new_config->enabled = true;
		nodes_clear(new_config->source_nids);
	}

	return new_config;
}

static void reuse_time_snapshot_config(struct reuse_time_config *snapshot)
{
	const struct reuse_time_config *config;

	memset(snapshot, 0, sizeof(*snapshot));

	rcu_read_lock();
	config = rcu_dereference(reuse_time_current_config);
	if (config) {
		*snapshot = *config;
		memset(&snapshot->rcu, 0, sizeof(snapshot->rcu));
		if (snapshot->target_memcg &&
		    !mem_cgroup_tryget(snapshot->target_memcg))
			snapshot->target_memcg = NULL;
	}
	rcu_read_unlock();
}

static void reuse_time_put_snapshot(struct reuse_time_config *snapshot)
{
	if (snapshot->target_memcg)
		mem_cgroup_put(snapshot->target_memcg);
}

static void reuse_time_reset_stats(void)
{
	int cpu;

	for_each_possible_cpu(cpu)
		memset(&per_cpu(reuse_time_stats, cpu), 0,
		       sizeof(struct reuse_time_cpu_stats));
}

static bool reuse_time_node_tracked(const struct reuse_time_config *config,
				    int nid)
{
	if (nodes_empty(config->source_nids))
		return false;

	if (nid < 0 || nid >= MAX_NUMNODES)
		return false;

	return node_isset(nid, config->source_nids);
}

static bool reuse_time_memcg_matches_target(const struct reuse_time_config *config,
					    struct mem_cgroup *memcg)
{
	if (!memcg)
		return false;

	if (config->match_descendants)
		return mem_cgroup_is_descendant(memcg, config->target_memcg);

	return memcg == config->target_memcg;
}

static bool reuse_time_task_matches_target(const struct reuse_time_config *config,
					   struct task_struct *task)
{
	if (!config->target_memcg)
		return false;

	return reuse_time_memcg_matches_target(config, mem_cgroup_from_task(task));
}

static u32 reuse_time_quantum_ms(void)
{
	return max_t(u32, 1U, (u32)jiffies_to_msecs(1));
}

static u64 reuse_time_latency_ticks(u32 latency_ms)
{
	u32 quantum_ms;

	if (!latency_ms)
		return 0;

	quantum_ms = reuse_time_quantum_ms();
	return DIV_ROUND_UP_ULL(latency_ms, quantum_ms);
}

static unsigned int reuse_time_bucket_idx(u32 latency_ms)
{
	u64 latency_ticks;

	latency_ticks = reuse_time_latency_ticks(latency_ms);
	if (!latency_ticks)
		return 0;

	if (latency_ticks <= RT_LINEAR_TICK_BUCKETS)
		return latency_ticks;

	return RT_NR_BUCKETS - 1;
}

void sched_reuse_time_record(struct task_struct *p, struct folio *folio,
			     int src_nid, unsigned int latency_ms)
{
	const struct reuse_time_config *config;
	struct reuse_time_cpu_stats *stats;
	unsigned int bucket;

	stats = get_cpu_ptr(&reuse_time_stats);
	stats->total_calls++;

	rcu_read_lock();
	config = rcu_dereference(reuse_time_current_config);
	if (!config || !config->enabled) {
		stats->ignored_disabled++;
		goto out;
	}

	if (!p || !folio) {
		stats->ignored_null++;
		goto out;
	}

	if (!config->target_memcg) {
		stats->ignored_no_target++;
		goto out;
	}

	if (!reuse_time_task_matches_target(config, p)) {
		stats->ignored_cgroup++;
		goto out;
	}

	if (task_numa_balancing_mode(p) <= 0) {
		stats->ignored_no_balancing++;
		goto out;
	}

	if (!reuse_time_node_tracked(config, src_nid)) {
		stats->ignored_untracked_node++;
		goto out;
	}

	bucket = reuse_time_bucket_idx(latency_ms);
	stats->buckets[bucket]++;
	stats->recorded++;

out:
	rcu_read_unlock();
	put_cpu_ptr(stats);
}

static void reuse_time_bucket_tick_bounds(unsigned int bucket, u64 *low_ticks,
					  u64 *high_ticks)
{
	if (!bucket) {
		*low_ticks = 0;
		*high_ticks = 0;
		return;
	}

	if (bucket <= RT_LINEAR_TICK_BUCKETS) {
		*low_ticks = bucket;
		*high_ticks = bucket;
		return;
	}

	*low_ticks = RT_LINEAR_TICK_BUCKETS + 1;
	*high_ticks = U64_MAX;
}

static u64 reuse_time_sum_field(size_t offset)
{
	u64 sum = 0;
	int cpu;

	for_each_possible_cpu(cpu) {
		struct reuse_time_cpu_stats *stats = &per_cpu(reuse_time_stats, cpu);
		u64 *value = (u64 *)((char *)stats + offset);

		sum += *value;
	}

	return sum;
}

static int reuse_time_hist_show(struct seq_file *m, void *v)
{
	u64 total = 0;
	u64 *buckets;
	u32 quantum_ms = reuse_time_quantum_ms();
	int cpu;
	int i;

	buckets = kcalloc(RT_NR_BUCKETS, sizeof(*buckets), GFP_KERNEL);
	if (!buckets)
		return -ENOMEM;

	for_each_possible_cpu(cpu) {
		struct reuse_time_cpu_stats *stats = &per_cpu(reuse_time_stats, cpu);

		total += stats->recorded;
		for (i = 0; i < RT_NR_BUCKETS; i++)
			buckets[i] += stats->buckets[i];
	}

	seq_printf(m, "recorded %llu\n", total);
	seq_printf(m, "time_quantum_ms %u\n", quantum_ms);
	for (i = 0; i < RT_NR_BUCKETS; i++) {
		u64 low_ticks, high_ticks;

		reuse_time_bucket_tick_bounds(i, &low_ticks, &high_ticks);
		if (!i) {
			seq_printf(m,
				   "bucket_%02d same_jiffy_lt_ms %u count %llu\n",
				   i, quantum_ms, buckets[i]);
		} else if (high_ticks == U64_MAX) {
			seq_printf(m,
				   "bucket_%02d_ticks %llu+ approx_ms %llu+ count %llu\n",
				   i, low_ticks, low_ticks * quantum_ms,
				   buckets[i]);
		} else {
			seq_printf(m,
				   "bucket_%02d_ticks %llu-%llu approx_ms %llu-%llu count %llu\n",
				   i, low_ticks, high_ticks,
				   low_ticks * quantum_ms,
				   high_ticks * quantum_ms, buckets[i]);
		}
	}

	kfree(buckets);
	return 0;
}

static int reuse_time_hist_open(struct inode *inode, struct file *file)
{
	return single_open(file, reuse_time_hist_show, inode->i_private);
}

static const struct file_operations reuse_time_hist_fops = {
	.owner = THIS_MODULE,
	.open = reuse_time_hist_open,
	.read = seq_read,
	.llseek = seq_lseek,
	.release = single_release,
};

static void reuse_time_print_target(struct seq_file *m,
				    const struct reuse_time_config *config)
{
	char *path;

	if (!config->target_memcg) {
		seq_puts(m, "target_cgroup_id 0\n");
		seq_puts(m, "target_cgroup_path <unset>\n");
		return;
	}

	seq_printf(m, "target_cgroup_id %llu\n",
		   cgroup_id(config->target_memcg->css.cgroup));

	path = kmalloc(PATH_MAX, GFP_KERNEL);
	if (!path) {
		seq_puts(m, "target_cgroup_path <nomem>\n");
		return;
	}

	if (cgroup_path(config->target_memcg->css.cgroup, path, PATH_MAX) >= 0)
		seq_printf(m, "target_cgroup_path %s\n", path);
	else
		seq_puts(m, "target_cgroup_path <error>\n");

	kfree(path);
}

static int reuse_time_stats_show(struct seq_file *m, void *v)
{
	struct reuse_time_config snapshot;

	reuse_time_snapshot_config(&snapshot);

	seq_printf(m, "enabled %u\n", snapshot.enabled ? 1 : 0);
	seq_printf(m, "active %u\n", reuse_time_config_active(&snapshot) ? 1 : 0);
	seq_puts(m, "hook should_numa_migrate_memory\n");
	seq_printf(m, "source_nids_param %s\n",
		   snapshot.source_nids_param[0] ?
		   snapshot.source_nids_param : "<unset>");
	seq_printf(m, "source_nids_mask %*pbl\n",
		   nodemask_pr_args(&snapshot.source_nids));
	seq_printf(m, "match_descendants %u\n",
		   snapshot.match_descendants ? 1 : 0);
	reuse_time_print_target(m, &snapshot);
	seq_printf(m, "time_quantum_ms %u\n", reuse_time_quantum_ms());
	seq_printf(m, "total_calls %llu\n",
		   reuse_time_sum_field(offsetof(struct reuse_time_cpu_stats,
						 total_calls)));
	seq_printf(m, "recorded %llu\n",
		   reuse_time_sum_field(offsetof(struct reuse_time_cpu_stats,
						 recorded)));
	seq_printf(m, "ignored_disabled %llu\n",
		   reuse_time_sum_field(offsetof(struct reuse_time_cpu_stats,
						 ignored_disabled)));
	seq_printf(m, "ignored_null %llu\n",
		   reuse_time_sum_field(offsetof(struct reuse_time_cpu_stats,
						 ignored_null)));
	seq_printf(m, "ignored_no_target %llu\n",
		   reuse_time_sum_field(offsetof(struct reuse_time_cpu_stats,
						 ignored_no_target)));
	seq_printf(m, "ignored_cgroup %llu\n",
		   reuse_time_sum_field(offsetof(struct reuse_time_cpu_stats,
						 ignored_cgroup)));
	seq_printf(m, "ignored_no_balancing %llu\n",
		   reuse_time_sum_field(offsetof(struct reuse_time_cpu_stats,
						 ignored_no_balancing)));
	seq_printf(m, "ignored_untracked_node %llu\n",
		   reuse_time_sum_field(offsetof(struct reuse_time_cpu_stats,
						 ignored_untracked_node)));

	reuse_time_put_snapshot(&snapshot);
	return 0;
}

static int reuse_time_stats_open(struct inode *inode, struct file *file)
{
	return single_open(file, reuse_time_stats_show, inode->i_private);
}

static const struct file_operations reuse_time_stats_fops = {
	.owner = THIS_MODULE,
	.open = reuse_time_stats_open,
	.read = seq_read,
	.llseek = seq_lseek,
	.release = single_release,
};

static ssize_t reuse_time_reset_write(struct file *file, const char __user *buf,
				      size_t count, loff_t *ppos)
{
	reuse_time_reset_stats();
	return count;
}

static const struct file_operations reuse_time_reset_fops = {
	.owner = THIS_MODULE,
	.write = reuse_time_reset_write,
	.llseek = noop_llseek,
};

static ssize_t reuse_time_bool_read(bool value, char __user *buf,
				    size_t count, loff_t *ppos)
{
	char tmp[4];
	int len;

	len = scnprintf(tmp, sizeof(tmp), "%u\n", value ? 1 : 0);
	return simple_read_from_buffer(buf, count, ppos, tmp, len);
}

static ssize_t reuse_time_enable_read(struct file *file, char __user *buf,
				      size_t count, loff_t *ppos)
{
	const struct reuse_time_config *config;
	bool enabled = false;

	rcu_read_lock();
	config = rcu_dereference(reuse_time_current_config);
	if (config)
		enabled = config->enabled;
	rcu_read_unlock();

	return reuse_time_bool_read(enabled, buf, count, ppos);
}

static ssize_t reuse_time_enable_write(struct file *file,
				       const char __user *ubuf,
				       size_t count, loff_t *ppos)
{
	struct reuse_time_config *new_config;
	struct reuse_time_config *old_config;
	bool enabled;
	int ret;

	ret = kstrtobool_from_user(ubuf, count, &enabled);
	if (ret)
		return ret;

	mutex_lock(&reuse_time_config_lock);
	new_config = reuse_time_clone_config_locked(true);
	if (!new_config)
		goto nomem_unlock;

	new_config->enabled = enabled;
	old_config = reuse_time_publish_config_locked(new_config);
	reuse_time_update_static_key_locked(new_config);
	mutex_unlock(&reuse_time_config_lock);
	reuse_time_put_old_config(old_config);
	return count;

nomem_unlock:
	mutex_unlock(&reuse_time_config_lock);
	return -ENOMEM;
}

static const struct file_operations reuse_time_enable_fops = {
	.owner = THIS_MODULE,
	.read = reuse_time_enable_read,
	.write = reuse_time_enable_write,
	.llseek = default_llseek,
};

static ssize_t reuse_time_match_descendants_read(struct file *file,
						 char __user *buf,
						 size_t count, loff_t *ppos)
{
	const struct reuse_time_config *config;
	bool match = false;

	rcu_read_lock();
	config = rcu_dereference(reuse_time_current_config);
	if (config)
		match = config->match_descendants;
	rcu_read_unlock();

	return reuse_time_bool_read(match, buf, count, ppos);
}

static ssize_t reuse_time_match_descendants_write(struct file *file,
						  const char __user *ubuf,
						  size_t count, loff_t *ppos)
{
	struct reuse_time_config *new_config;
	struct reuse_time_config *old_config;
	bool match;
	int ret;

	ret = kstrtobool_from_user(ubuf, count, &match);
	if (ret)
		return ret;

	mutex_lock(&reuse_time_config_lock);
	new_config = reuse_time_clone_config_locked(true);
	if (!new_config)
		goto nomem_unlock;

	new_config->match_descendants = match;
	old_config = reuse_time_publish_config_locked(new_config);
	reuse_time_update_static_key_locked(new_config);
	mutex_unlock(&reuse_time_config_lock);
	reuse_time_put_old_config(old_config);
	return count;

nomem_unlock:
	mutex_unlock(&reuse_time_config_lock);
	return -ENOMEM;
}

static const struct file_operations reuse_time_match_descendants_fops = {
	.owner = THIS_MODULE,
	.read = reuse_time_match_descendants_read,
	.write = reuse_time_match_descendants_write,
	.llseek = default_llseek,
};

static ssize_t reuse_time_source_nids_read(struct file *file, char __user *buf,
					   size_t count, loff_t *ppos)
{
	const struct reuse_time_config *config;
	char tmp[RT_SOURCE_NIDS_MAX + 2];
	int len;

	rcu_read_lock();
	config = rcu_dereference(reuse_time_current_config);
	len = scnprintf(tmp, sizeof(tmp), "%s\n",
			config && config->source_nids_param[0] ?
			config->source_nids_param : "<unset>");
	rcu_read_unlock();

	return simple_read_from_buffer(buf, count, ppos, tmp, len);
}

static ssize_t reuse_time_source_nids_write(struct file *file,
					    const char __user *ubuf,
					    size_t count, loff_t *ppos)
{
	struct reuse_time_config *new_config;
	struct reuse_time_config *old_config;
	nodemask_t new_mask;
	char *buf;
	char *name;
	int ret;

	if (!count || count >= RT_SOURCE_NIDS_MAX)
		return -EINVAL;

	buf = memdup_user_nul(ubuf, count);
	if (IS_ERR(buf))
		return PTR_ERR(buf);

	name = strstrip(buf);
	nodes_clear(new_mask);
	if (!*name || !strcmp(name, "none") || !strcmp(name, "<unset>")) {
		name = "";
	} else {
		ret = nodelist_parse(name, new_mask);
		if (ret) {
			kfree(buf);
			return ret;
		}
	}

	mutex_lock(&reuse_time_config_lock);
	new_config = reuse_time_clone_config_locked(true);
	if (!new_config) {
		mutex_unlock(&reuse_time_config_lock);
		kfree(buf);
		return -ENOMEM;
	}

	strscpy(new_config->source_nids_param, name,
		sizeof(new_config->source_nids_param));
	new_config->source_nids = new_mask;
	old_config = reuse_time_publish_config_locked(new_config);
	reuse_time_update_static_key_locked(new_config);
	mutex_unlock(&reuse_time_config_lock);
	reuse_time_put_old_config(old_config);
	kfree(buf);
	return count;
}

static const struct file_operations reuse_time_source_nids_fops = {
	.owner = THIS_MODULE,
	.read = reuse_time_source_nids_read,
	.write = reuse_time_source_nids_write,
	.llseek = default_llseek,
};

static int reuse_time_config_set_target_cgroup(struct reuse_time_config *config,
					       struct cgroup *cgrp)
{
	struct cgroup_subsys_state *css;

	if (!cgrp) {
		if (config->target_memcg)
			mem_cgroup_put(config->target_memcg);
		config->target_memcg = NULL;
		return 0;
	}

	css = cgroup_get_e_css(cgrp, &memory_cgrp_subsys);
	if (!css)
		return -ENOENT;

	if (config->target_memcg)
		mem_cgroup_put(config->target_memcg);
	config->target_memcg = mem_cgroup_from_css(css);
	return 0;
}

static ssize_t reuse_time_target_cgroup_id_read(struct file *file,
						char __user *buf,
						size_t count, loff_t *ppos)
{
	struct reuse_time_config snapshot;
	char tmp[32];
	u64 id = 0;
	int len;

	reuse_time_snapshot_config(&snapshot);
	if (snapshot.target_memcg)
		id = cgroup_id(snapshot.target_memcg->css.cgroup);
	reuse_time_put_snapshot(&snapshot);

	len = scnprintf(tmp, sizeof(tmp), "%llu\n", id);
	return simple_read_from_buffer(buf, count, ppos, tmp, len);
}

static ssize_t reuse_time_target_cgroup_id_write(struct file *file,
						 const char __user *ubuf,
						 size_t count, loff_t *ppos)
{
	struct reuse_time_config *new_config;
	struct reuse_time_config *old_config;
	struct cgroup *cgrp = NULL;
	u64 id;
	int ret;

	ret = kstrtou64_from_user(ubuf, count, 0, &id);
	if (ret)
		return ret;

	if (id) {
		cgrp = cgroup_get_from_id(id);
		if (IS_ERR(cgrp))
			return PTR_ERR(cgrp);
	}

	mutex_lock(&reuse_time_config_lock);
	new_config = reuse_time_clone_config_locked(false);
	if (!new_config) {
		mutex_unlock(&reuse_time_config_lock);
		if (cgrp)
			cgroup_put(cgrp);
		return -ENOMEM;
	}

	ret = reuse_time_config_set_target_cgroup(new_config, cgrp);
	if (cgrp)
		cgroup_put(cgrp);
	if (ret) {
		mutex_unlock(&reuse_time_config_lock);
		reuse_time_put_config(new_config);
		return ret;
	}

	old_config = reuse_time_publish_config_locked(new_config);
	reuse_time_update_static_key_locked(new_config);
	mutex_unlock(&reuse_time_config_lock);
	reuse_time_put_old_config(old_config);
	return count;
}

static const struct file_operations reuse_time_target_cgroup_id_fops = {
	.owner = THIS_MODULE,
	.read = reuse_time_target_cgroup_id_read,
	.write = reuse_time_target_cgroup_id_write,
	.llseek = default_llseek,
};

static ssize_t reuse_time_target_cgroup_path_read(struct file *file,
						  char __user *buf,
						  size_t count, loff_t *ppos)
{
	struct reuse_time_config snapshot;
	char *path;
	ssize_t ret;
	int len;

	path = kmalloc(PATH_MAX, GFP_KERNEL);
	if (!path)
		return -ENOMEM;

	reuse_time_snapshot_config(&snapshot);
	if (!snapshot.target_memcg) {
		len = scnprintf(path, PATH_MAX, "<unset>\n");
	} else if (cgroup_path(snapshot.target_memcg->css.cgroup, path,
			       PATH_MAX) < 0) {
		len = scnprintf(path, PATH_MAX, "<error>\n");
	} else {
		len = strnlen(path, PATH_MAX);
		if (len < PATH_MAX - 1) {
			path[len++] = '\n';
			path[len] = '\0';
		}
	}
	reuse_time_put_snapshot(&snapshot);

	ret = simple_read_from_buffer(buf, count, ppos, path, len);
	kfree(path);
	return ret;
}

static ssize_t reuse_time_target_cgroup_path_write(struct file *file,
						   const char __user *ubuf,
						   size_t count, loff_t *ppos)
{
	struct reuse_time_config *new_config;
	struct reuse_time_config *old_config;
	struct cgroup *cgrp = NULL;
	char *buf;
	char *name;
	int ret;

	if (!count || count > PATH_MAX)
		return -EINVAL;

	buf = memdup_user_nul(ubuf, count);
	if (IS_ERR(buf))
		return PTR_ERR(buf);

	name = strstrip(buf);
	if (*name && strcmp(name, "0") && strcmp(name, "none") &&
	    strcmp(name, "<unset>")) {
		cgrp = cgroup_get_from_path(name);
		if (IS_ERR(cgrp)) {
			ret = PTR_ERR(cgrp);
			kfree(buf);
			return ret;
		}
	}

	mutex_lock(&reuse_time_config_lock);
	new_config = reuse_time_clone_config_locked(false);
	if (!new_config) {
		mutex_unlock(&reuse_time_config_lock);
		if (cgrp)
			cgroup_put(cgrp);
		kfree(buf);
		return -ENOMEM;
	}

	ret = reuse_time_config_set_target_cgroup(new_config, cgrp);
	if (cgrp)
		cgroup_put(cgrp);
	kfree(buf);
	if (ret) {
		mutex_unlock(&reuse_time_config_lock);
		reuse_time_put_config(new_config);
		return ret;
	}

	old_config = reuse_time_publish_config_locked(new_config);
	reuse_time_update_static_key_locked(new_config);
	mutex_unlock(&reuse_time_config_lock);
	reuse_time_put_old_config(old_config);
	return count;
}

static const struct file_operations reuse_time_target_cgroup_path_fops = {
	.owner = THIS_MODULE,
	.read = reuse_time_target_cgroup_path_read,
	.write = reuse_time_target_cgroup_path_write,
	.llseek = default_llseek,
};

static int __init sched_reuse_time_init(void)
{
	struct reuse_time_config *config;

	config = kzalloc(sizeof(*config), GFP_KERNEL);
	if (!config)
		return -ENOMEM;

	config->enabled = true;
	nodes_clear(config->source_nids);
	rcu_assign_pointer(reuse_time_current_config, config);

	reuse_time_dir = debugfs_create_dir(RT_DIR_NAME, NULL);
	if (IS_ERR_OR_NULL(reuse_time_dir))
		return 0;

	debugfs_create_file("enable", 0644, reuse_time_dir, NULL,
			    &reuse_time_enable_fops);
	debugfs_create_file("match_descendants", 0644, reuse_time_dir, NULL,
			    &reuse_time_match_descendants_fops);
	debugfs_create_file("source_nids", 0644, reuse_time_dir, NULL,
			    &reuse_time_source_nids_fops);
	debugfs_create_file("target_cgroup_id", 0644, reuse_time_dir, NULL,
			    &reuse_time_target_cgroup_id_fops);
	debugfs_create_file("target_cgroup_path", 0644, reuse_time_dir, NULL,
			    &reuse_time_target_cgroup_path_fops);
	debugfs_create_file("reset", 0200, reuse_time_dir, NULL,
			    &reuse_time_reset_fops);
	debugfs_create_file("hist", 0444, reuse_time_dir, NULL,
			    &reuse_time_hist_fops);
	debugfs_create_file("stats", 0444, reuse_time_dir, NULL,
			    &reuse_time_stats_fops);

	return 0;
}
late_initcall(sched_reuse_time_init);
