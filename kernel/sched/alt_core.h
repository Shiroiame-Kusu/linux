#ifndef _KERNEL_SCHED_ALT_CORE_H
#define _KERNEL_SCHED_ALT_CORE_H

/*
 * Compile time debug macro
 * #define ALT_SCHED_DEBUG
 */
#define ALT_SCHED_DEBUG

#ifdef ALT_SCHED_DEBUG
extern void alt_sched_debug(void);
#else
static inline void alt_sched_debug(void) {}
#endif

/*
 * Task related inlined functions
 */
static inline bool is_migration_disabled(const struct task_struct *p)
{
	return p->migration_disabled;
}

/* rt_prio(prio) defined in include/linux/sched/rt.h */
#define rt_task(p)		rt_prio((p)->prio)
#define rt_policy(policy)	((policy) == SCHED_FIFO || (policy) == SCHED_RR)
#define task_has_rt_policy(p)	(rt_policy((p)->policy))

#define fair_policy(policy)	((policy) == SCHED_NORMAL || (policy) == SCHED_BATCH)

#define valid_policy(policy)	((policy) <= SCHED_IDLE)

#define task_has_dl_policy(p)	(false)
#define dl_prio(prio)		(false)

struct affinity_context {
	const struct cpumask	*new_mask;
	struct cpumask		*user_mask;
	unsigned int		flags;
};

/* CONFIG_SCHED_CLASS_EXT is not supported */
#define scx_switched_all()	false

#define SCA_CHECK		0x01
/* SCA_MIGRATE_DISABLE is not supported */
#define SCA_MIGRATE_ENABLE	0x04
#define SCA_USER		0x08

extern int __set_cpus_allowed_ptr(struct task_struct *p, struct affinity_context *ctx);

static inline cpumask_t *alloc_user_cpus_ptr(int node)
{
	/*
	 * See set_cpus_allowed_force() above for the rcu_head usage.
	 */
	int size = max_t(int, cpumask_size(), sizeof(struct rcu_head));

	return kmalloc_node(size, GFP_KERNEL, node);
}

#ifdef CONFIG_RT_MUTEXES

static inline int __rt_effective_prio(struct task_struct *pi_task, int prio)
{
	if (pi_task)
		prio = min(prio, pi_task->prio);

	return prio;
}

static inline int rt_effective_prio(struct task_struct *p, int prio)
{
	struct task_struct *pi_task = rt_mutex_get_top_task(p);

	return __rt_effective_prio(pi_task, prio);
}

#else /* !CONFIG_RT_MUTEXES: */

static inline int rt_effective_prio(struct task_struct *p, int prio)
{
	return prio;
}

#endif /* !CONFIG_RT_MUTEXES */

extern int __sched_setscheduler(struct task_struct *p, const struct sched_attr *attr, bool user, bool pi);
extern int __sched_setaffinity(struct task_struct *p, struct affinity_context *ctx);

extern void wakeup_modified_task(struct task_struct *p);

/*
 * run queue related inlined functions
 */
/*
 * Unlink @target from the bucket list @head in place. The caller must hold
 * the bucket's _lock[idx]: all removers (pick_next_task()'s PQ_PICK_TASK,
 * SRQ_DEQUEUE_TASK()) serialize on it, so interior ->next pointers are
 * stable under the lock. The only lock-free writer is SRQ_ENQUEUE_TASK()'s
 * llist_add(), which just prepends -- it can only race the head cmpxchg,
 * never an interior unlink, and a failed cmpxchg means @target gained a
 * predecessor that the walk below then finds.
 *
 * Unlike the historical llist_del_all() + walk + re-merge scheme, this
 * touches no node but @target's predecessor: no O(n) reversals, no merge
 * loop retrying against concurrent adds while the lock is held.
 *
 * A false return is a legitimate, self-healing race, not a bug.
 * SRQ_ENQUEUE_TASK() publishes p->__sched_prio (and on_rq=QUEUED) before
 * its lock-free llist_add(), so a concurrent __task_modify_lock() dequeuer
 * holding _lock[idx] can observe the membership token while pq_node is not
 * yet linked. SRQ_DEQUEUE_TASK() then returns false and every caller
 * (__task_modify_lock / task_access_lock) retries until the enqueue is
 * visible. The reverse store order would instead leave pq_node linked with
 * __sched_prio==-1, routing dequeuers to the rq path -- worse.
 */
static __always_inline
bool sched_llist_unlink(struct llist_head *head, struct llist_node *target)
{
	struct llist_node *first = READ_ONCE(head->first);
	struct llist_node *node;

	if (!first)
		return false;

	if (first == target) {
		if (try_cmpxchg(&head->first, &first, target->next)) {
			target->next = NULL;
			return true;
		}
		/* llist_add() prepended new nodes; @target is interior now. */
	}

	for (node = first; node->next; node = node->next) {
		if (node->next == target) {
			node->next = target->next;
			target->next = NULL;
			return true;
		}
	}

	return false;
}

/*
 * p->__sched_prio is SRQ/GRQ membership metadata for pq_node reuse.
 * -1 means the task is not linked in SRQ/GRQ; non-negative values identify
 * the SRQ/GRQ bucket that owns pq_node.
 */
#define SRQ_DEQUEUE_TASK(srq, p, __modify_body__)					\
({											\
	int idx = READ_ONCE(p->__sched_prio);						\
	struct llist_head *head = &srq->_head[idx];					\
	bool __found = sched_llist_unlink(head, &p->pq_node);				\
											\
	if (__found) {									\
		__modify_body__								\
		WRITE_ONCE(p->__sched_prio, -1);					\
		atomic_dec(&srq->nr_queued);						\
		if (llist_empty(head)) {						\
			WARN_ONCE(task_sched_prio(p) != idx, "sched: srq en/dequeue bug.\n");	\
			clear_bit(idx, srq->bitmap);					\
			smp_mb__after_atomic();						\
			if (!llist_empty(head))						\
				set_bit(idx, srq->bitmap);				\
		}									\
	}										\
	__found;									\
})

#define SRQ_ENQUEUE_TASK(srq, p, __modify_body__)		\
{								\
	int sched_prio = task_sched_prio(p);			\
								\
	WRITE_ONCE(p->__sched_prio, sched_prio);		\
	__modify_body__						\
	if (llist_add(&p->pq_node, &(srq)->_head[sched_prio]))	\
		set_bit(sched_prio, (srq)->bitmap);		\
	atomic_inc(&(srq)->nr_queued);				\
}

/*
 * Context API
 */
static inline struct rq *__task_modify_lock(struct task_struct *p, struct rq_flags *rf)
{
	rf->lock = NULL;
	rf->queued = false;

	for (;;) {
		if (TASK_ON_RQ_WAKING == p->on_rq) {
			struct rq *rq = cpu_rq(p->wake_cpu);

			raw_spin_lock(&rq->lock);
			if (likely(TASK_ON_RQ_WAKING == p->on_rq && rq == task_rq(p))) {
				rf->lock = &rq->lock;
				return rq;
			}
			raw_spin_unlock(&rq->lock);
		} else if (task_on_rq_preempt(p)) {
			int wake_cpu = READ_ONCE(p->wake_cpu);
			struct rq *rq = cpu_rq(wake_cpu);

			raw_spin_lock(&rq->lock);
			if (likely(task_on_rq_preempt(p) &&
				   wake_cpu == READ_ONCE(p->wake_cpu) &&
				   rq == task_rq(p))) {
				rf->lock = &rq->lock;
				return rq;
			}
			raw_spin_unlock(&rq->lock);
		} else if (task_on_rq_queued(p)) {
			int idx;
			if (p->on_cpu) {
				struct rq *rq = task_rq(p);

				raw_spin_lock(&rq->lock);
				if (likely(task_on_rq_queued(p) && p->on_cpu && rq == task_rq(p))) {
					rf->lock = &rq->lock;
					return rq;
				}
				raw_spin_unlock(&rq->lock);
			} else if ((idx = READ_ONCE(p->__sched_prio)) != -1) {
				struct sched_run_queue *srq = cpu_srq(0);
				raw_spinlock_t *lock = &srq->_lock[idx];

				raw_spin_lock(lock);
				if (task_on_rq_queued(p) && !p->on_cpu &&
				    idx == READ_ONCE(p->__sched_prio)) {

					if (!SRQ_DEQUEUE_TASK(srq, p, {
							WRITE_ONCE(p->on_rq, TASK_ON_RQ_MIGRATING);
						})) {
						raw_spin_unlock(lock);
						continue;
					}

					raw_spin_unlock(lock);

					struct rq *rq = task_rq(p);
					raw_spin_lock(&rq->lock);

					rf->lock = &rq->lock;
					rf->queued = true;
					return rq;
				}
				raw_spin_unlock(lock);
			} else {
				struct rq *rq = task_rq(p);

				raw_spin_lock(&rq->lock);
				if (task_on_rq_queued(p) && !p->on_cpu &&
				    READ_ONCE(p->__sched_prio) == -1 &&
				    rq == task_rq(p)) {
					rf->lock = &rq->lock;
					return rq;
				}
				raw_spin_unlock(&rq->lock);
			}
		} else if (task_on_rq_migrating(p)) {
			do {
				cpu_relax();
			} while (unlikely(task_on_rq_migrating(p)));
		} else {
			struct rq *rq = task_rq(p);

			raw_spin_lock(&rq->lock);
			if (likely(rq == task_rq(p))) {
				rf->lock = &rq->lock;
				return rq;
			}
			raw_spin_unlock(&rq->lock);
		}
	}
}

static inline void __task_modify_unlock(struct task_struct *p, struct rq_flags *rf)
{
	if (NULL != rf->lock)
		raw_spin_unlock(rf->lock);
	if (rf->queued)
		wakeup_modified_task(p);
}

static inline struct rq *task_access_lock(struct task_struct *p, struct rq_flags *rf)
{
	raw_spin_lock_irqsave(&p->pi_lock, rf->flags);
	return __task_modify_lock(p, rf);
}

static inline void task_access_unlock(struct task_struct *p, struct rq_flags *rf)
{
	__task_modify_unlock(p, rf);
	raw_spin_unlock_irqrestore(&p->pi_lock, rf->flags);
}

DEFINE_LOCK_GUARD_1(task_access_lock, struct task_struct,
		    _T->rq = task_access_lock(_T->lock, &_T->rf),
		    task_access_unlock(_T->lock, &_T->rf),
		    struct rq *rq; struct rq_flags rf)

#define task_rq_lock(...) _task_rq_lock(__VA_ARGS__)
extern struct rq *_task_rq_lock(struct task_struct *p, struct rq_flags *rf);

static inline void
task_rq_unlock(struct rq *rq, struct task_struct *p, struct rq_flags *rf)
{
	if (rf->lock)
		raw_spin_unlock(rf->lock);
	if (rf->queued)
		wakeup_modified_task(p);
	raw_spin_unlock_irqrestore(&p->pi_lock, rf->flags);
}

DEFINE_LOCK_GUARD_1(task_rq_lock, struct task_struct,
		    _T->rq = task_rq_lock(_T->lock, &_T->rf),
		    task_rq_unlock(_T->rq, _T->lock, &_T->rf),
		    struct rq *rq; struct rq_flags rf)

extern void yield_task(struct rq *rq);

DECLARE_STATIC_KEY_FALSE(sched_smt_present);

/* balance callback */
extern struct balance_callback *splice_balance_callbacks(struct rq *rq);
extern void balance_callbacks(struct rq *rq, struct balance_callback *head);

#endif /* _KERNEL_SCHED_ALT_CORE_H */
