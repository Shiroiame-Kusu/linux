#ifdef ALT_SCHED_DEBUG
#define SCHED_DEBUG_INFO(...)	printk(KERN_INFO __VA_ARGS__)
#else
#define SCHED_DEBUG_INFO(...)	do { } while(0)
#endif

static cpumask_t cpu_topo_masks[6] ____cacheline_aligned_in_smp;

#define sched_ucore_mask	(cpu_topo_masks)
#define sched_pcore_mask	(cpu_topo_masks + 1)
#define sched_ecore_mask	(cpu_topo_masks + 2)

/*
 * pcore_cpus kernel parameter
 */
static int __init pcore_cpus_setup(char *str)
{
	if (cpulist_parse(str, sched_pcore_mask))
		pr_warn("sched/alt: pcore_cpus= incorrect CPU range\n");

	return 1;
}
__setup("pcore_cpus=", pcore_cpus_setup);

/*
 * ultra_core_cpus kernel parameter
 */
static int __init ucore_cpus_setup(char *str)
{
	if (cpulist_parse(str, sched_ucore_mask))
		pr_warn("sched/alt: ucore_cpus= incorrect CPU range\n");

	return 1;
}
__setup("ucore_cpus=", ucore_cpus_setup);

/*
 * CPU topology type
 */
enum cpu_topo_type {
	CPU_TOPOLOGY_DEFAULT	= 0,
	CPU_TOPOLOGY_UCORE,
	CPU_TOPOLOGY_PCORE,
	CPU_TOPOLOGY_ECORE,
	CPU_TOPOLOGY_NONE,
#ifdef CONFIG_SCHED_SMT
	CPU_TOPOLOGY_UCORE_SMT,
	CPU_TOPOLOGY_PCORE_SMT,
	CPU_TOPOLOGY_SMT	= CPU_TOPOLOGY_PCORE_SMT,
	CPU_TOPOLOGY_ECORE_SMT,
#endif
};

#define CPU_TOPOLOGY_MASK	(0x03)

/*
 * cpu_sched_prio_mask[] index of the fully idle P-cores (with SMT: both
 * siblings idle), see sched_set_idle_mask(). Level 0 holds the U-cores.
 */
#define SCHED_PCORE_IDLE_LEVEL	(CPU_TOPOLOGY_PCORE - 1)

static DEFINE_PER_CPU_READ_MOSTLY(enum cpu_topo_type, sched_cpu_topo);

static __always_inline void sched_set_idle_mask(const unsigned int cpu)
{
	int topo = per_cpu(sched_cpu_topo, cpu);

	switch (topo) {
	case CPU_TOPOLOGY_DEFAULT:
		break;
	case CPU_TOPOLOGY_UCORE:
	case CPU_TOPOLOGY_PCORE:
	case CPU_TOPOLOGY_ECORE:
		topo--;
		sched_prio_level_join(cpu, topo);
		break;
#ifdef CONFIG_SCHED_SMT
	case CPU_TOPOLOGY_UCORE_SMT:
	case CPU_TOPOLOGY_PCORE_SMT:
	case CPU_TOPOLOGY_ECORE_SMT: {
		/*
		 * cpu_sched_prio_mask[] is updated concurrently by other CPUs'
		 * idle transitions under only their own rq->lock. Whole-mask
		 * cpumask_or()/cpumask_andnot() are plain read-modify-writes
		 * and lose remote cores' bits; only per-bit atomics are safe
		 * here, with the level bits kept by the publish/retire
		 * protocol (see sched_prio_level_publish()). The group-idle
		 * classification itself may still go momentarily stale (it is
		 * advisory and self-heals on the next transition), but bits
		 * of unrelated cores must not.
		 */
		const struct cpumask *smt_mask = cpu_smt_mask(cpu);
		int i;

		topo -= CPU_TOPOLOGY_UCORE_SMT;
		if (cpumask_intersects(smt_mask, sched_idle_mask)) {
			for_each_cpu(i, smt_mask)
				cpumask_set_cpu(i, cpu_sched_prio_mask + topo);
			sched_prio_level_publish(topo);

			topo += 3;
			for_each_cpu(i, smt_mask)
				cpumask_clear_cpu(i, cpu_sched_prio_mask + topo);
			sched_prio_level_retire(topo);
		} else {
			topo += 3;
			sched_prio_level_join(cpu, topo);
		}
		break;
	}
#endif
	}

	sched_prio_level_join(cpu, SCHED_LEVELS - 1 - IDLE_TASK_SCHED_PRIO);
}

static __always_inline void sched_clear_idle_mask(const unsigned int cpu)
{
	int topo = per_cpu(sched_cpu_topo, cpu);

	switch (topo) {
	case CPU_TOPOLOGY_DEFAULT:
		break;
	case CPU_TOPOLOGY_UCORE:
	case CPU_TOPOLOGY_PCORE:
	case CPU_TOPOLOGY_ECORE:
		topo--;
		sched_prio_level_leave(cpu, topo);
		break;
#ifdef CONFIG_SCHED_SMT
	case CPU_TOPOLOGY_UCORE_SMT:
	case CPU_TOPOLOGY_PCORE_SMT:
	case CPU_TOPOLOGY_ECORE_SMT: {
		/* Per-bit atomics: see the comment in sched_set_idle_mask(). */
		const struct cpumask *smt_mask = cpu_smt_mask(cpu);
		int i;

		topo -= CPU_TOPOLOGY_UCORE_SMT;
		if (cpumask_test_cpu(cpu, cpu_sched_prio_mask + topo)) {
			for_each_cpu(i, smt_mask)
				cpumask_clear_cpu(i, cpu_sched_prio_mask + topo);
			sched_prio_level_retire(topo);

			topo += 3;
			for_each_cpu(i, smt_mask) {
				if (i == cpu)
					cpumask_clear_cpu(i, cpu_sched_prio_mask + topo);
				else
					cpumask_set_cpu(i, cpu_sched_prio_mask + topo);
			}
			sched_prio_level_publish(topo);
		} else {
			topo += 3;
			sched_prio_level_leave(cpu, topo);
		}
	}
#endif
	}

	sched_prio_level_leave(cpu, SCHED_LEVELS - 1 - IDLE_TASK_SCHED_PRIO);
}


/*
 * Slice-expiry promotion: the idle level @cpu would sit at once @p left it,
 * if a CPU @p may run on is idle at a better one -- a faster core class, or
 * with SMT a core with no busy sibling -- else -1. pick_next_task() then
 * switches to the idle task instead of renewing @p here and finish_task()
 * hands @p over, see finish_task_promote().
 *
 * This is what moves a CPU-bound task off a slower core. It used to be done
 * from the other end: every U/P-core entering idle trylocked the rq of each
 * busy E-core in turn and, finding one whose task could move, preempted that
 * task with the stopper. That cost 2.6% of all cycles under a wakeup
 * ping-pong, which enters idle constantly and found nothing to move; and it
 * pulled short-running tasks too, which a P-core that is idle for a few
 * microseconds has no use for. A task that has run a whole slice is the one
 * worth a cold cache, and its own CPU can tell that for free; one that sleeps
 * first is placed on the fastest idle core at its next wakeup anyway.
 */
static __always_inline int sched_cpu_promote_level(const int cpu, struct task_struct *p)
{
	const int topo = per_cpu(sched_cpu_topo, cpu);
	int level = (topo & CPU_TOPOLOGY_MASK) - 1;
	unsigned long better;

	/* Untyped CPUs have no idle levels to compare; pinned tasks stay. */
	if (level < 0 || 1 == p->nr_cpus_allowed || is_migration_disabled(p))
		return -1;

#ifdef CONFIG_SCHED_SMT
	/* As sched_set_idle_mask() would file @cpu: with no sibling idle, half. */
	if (topo > CPU_TOPOLOGY_NONE &&
	    !cpumask_intersects(cpu_smt_mask(cpu), sched_idle_mask))
		level += 3;
#endif

	better = sched_bits_below(cpu_sched_prio_bitmap, level);
	for (; better; better &= better - 1)
		if (cpumask_intersects(cpu_sched_prio_mask + __ffs(better), p->cpus_ptr))
			return level;

	return -1;
}

/*
 * Keep a unique ID per domain (we use the first CPUs number in the cpumask of
 * the domain), this allows us to quickly tell if two cpus are in the same cache
 * domain, see cpus_share_cache().
 */
static DEFINE_PER_CPU_READ_MOSTLY(int, sd_llc_id);

bool cpus_share_cache(int this_cpu, int that_cpu)
{
	if (this_cpu == that_cpu)
		return true;

	return per_cpu(sd_llc_id, this_cpu) == per_cpu(sd_llc_id, that_cpu);
}


/*
 * CPU topology mask
 */
DEFINE_PER_CPU_ALIGNED(cpumask_t [NR_CPU_AFFINITY_LEVELS], cpu_affinity_masks);
DEFINE_PER_CPU_ALIGNED(cpumask_t *, cpu_affinity_end_mask);

static inline void sched_init_topology_early(void)
{
	int cpu;

	for_each_possible_cpu(cpu) {
		/* init topo masks */
		cpumask_t *tmp = per_cpu(cpu_affinity_masks, cpu);

		cpumask_copy(tmp, cpu_possible_mask);
		per_cpu(cpu_affinity_end_mask, cpu) = ++tmp;
	}
}

/* init schedule cpu topology masks: ucore/pcore/ecore and smt mask */
static inline void sched_init_cpu_topology(void)
{
	bool cpu_topo_smt_present = false;

#ifdef CONFIG_SCHED_SMT
	if (!cpumask_empty(&sched_smt_mask)) {
		printk(KERN_INFO "sched: (smt) mask : 0x%08lx\n", sched_smt_mask.bits[0]);
		if (cpumask_empty(sched_pcore_mask))
			cpumask_copy(sched_pcore_mask, &sched_smt_mask);
	}
#endif

	if (cpumask_empty(sched_pcore_mask) && cpumask_empty(sched_ucore_mask))
		return;

	cpumask_andnot(sched_pcore_mask, sched_pcore_mask, sched_ucore_mask);

	cpumask_andnot(sched_ecore_mask, cpu_online_mask, sched_pcore_mask);
	cpumask_andnot(sched_ecore_mask, sched_ecore_mask, sched_ucore_mask);

	printk(KERN_INFO "sched: topo  ucore: 0x%08lx, pcore: 0x%08lx, ecore: 0x%08lx\n",
	       sched_ucore_mask->bits[0],
	       sched_pcore_mask->bits[0],
	       sched_ecore_mask->bits[0]);

#ifdef CONFIG_SCHED_SMT
	if (cpumask_empty(&sched_smt_mask))
		return;

	for (int i = 0; i < 3; i++)
		if (cpumask_and(cpu_topo_masks + i + 3,
				cpu_topo_masks + i, &sched_smt_mask))
			cpu_topo_smt_present = true;

	if (!cpu_topo_smt_present)
		return;

	printk(KERN_INFO "sched: (smt) ucore: 0x%08lx, pcore: 0x%08lx, ecore: 0x%08lx\n",
	       (sched_ucore_mask + 3)->bits[0],
	       (sched_pcore_mask + 3)->bits[0],
	       (sched_ecore_mask + 3)->bits[0]);
#endif
}

#define TOPOLOGY_CPUMASK(name, mask, last)					\
	if (cpumask_and(topo, topo, mask)) {					\
		printk(KERN_INFO "sched: cpu#%02d affinity: 0x%08lx - "#name,	\
		       cpu, (topo++)->bits[0]);					\
	}									\
	if (!last)								\
		bitmap_complement(cpumask_bits(topo), cpumask_bits(mask),	\
				  nr_cpumask_bits);

static inline void sched_init_topology(void)
{
	int cpu;

	sched_init_cpu_topology();

	/* CPU topology setup */
	for_each_online_cpu(cpu) {
		cpumask_t *topo;
		int cpu_topo = 0;
#ifdef CONFIG_SCHED_SMT
		if (cpumask_weight(cpu_smt_mask(cpu)) > 1)
			cpu_topo += CPU_TOPOLOGY_NONE;
#endif
		if (cpumask_test_cpu(cpu, sched_ucore_mask))
			cpu_topo += CPU_TOPOLOGY_UCORE;
		else if (cpumask_test_cpu(cpu, sched_pcore_mask))
			cpu_topo += CPU_TOPOLOGY_PCORE;
		else if (cpumask_test_cpu(cpu, sched_ecore_mask))
			cpu_topo += CPU_TOPOLOGY_ECORE;

		if (cpu_topo)
			per_cpu(sched_cpu_topo, cpu) = cpu_topo;

		topo = per_cpu(cpu_affinity_masks, cpu);

		bitmap_complement(cpumask_bits(topo), cpumask_bits(cpumask_of(cpu)),
				  nr_cpumask_bits);
#ifdef CONFIG_SCHED_SMT
		TOPOLOGY_CPUMASK(smt, topology_sibling_cpumask(cpu), false);
#endif /* CONFIG_SCHED_SMT */
		TOPOLOGY_CPUMASK(cluster, topology_cluster_cpumask(cpu), false);

		per_cpu(sd_llc_id, cpu) = cpumask_first(cpu_coregroup_mask(cpu));
		TOPOLOGY_CPUMASK(coregroup, cpu_coregroup_mask(cpu), false);

		TOPOLOGY_CPUMASK(core, topology_core_cpumask(cpu), false);

		TOPOLOGY_CPUMASK(others, cpu_online_mask, true);

		per_cpu(cpu_affinity_end_mask, cpu) = topo;

		SCHED_DEBUG_INFO("sched: cpu#%02d topology: %d%5s, llc_id = %d",
				 cpu, cpu_topo & CPU_TOPOLOGY_MASK,
				 (cpu_topo > CPU_TOPOLOGY_MASK) ? "(smt)" : "",
				 per_cpu(sd_llc_id, cpu));
	}
}
