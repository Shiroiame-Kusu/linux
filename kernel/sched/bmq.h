#ifndef _KERNEL_SCHED_BMQ_H
#define _KERNEL_SCHED_BMQ_H

#include <linux/sched/clock.h>

#define ALT_SCHED_NAME "BMQ"

/*
 * BMQ only routines
 */
static inline void boost_task(struct task_struct *p, int n)
{
	int limit;

	switch (p->policy) {
	case SCHED_NORMAL:
		limit = -MAX_PRIORITY_ADJ;
		break;
	case SCHED_BATCH:
		limit = 0;
		break;
	default:
		return;
	}

	p->boost_prio = max(limit, p->boost_prio - n);
}

static inline void deboost_task(struct task_struct *p)
{
	if ((SCHED_NORMAL == p->policy || SCHED_BATCH == p->policy) &&
	    p->boost_prio < MAX_PRIORITY_ADJ)
		p->boost_prio++;
}

/*
 * Common interfaces
 */

/* This API is used in task_prio(), return value readed by human users */
static inline int
task_sched_prio_normal(const struct task_struct *p, const struct rq *rq)
{
	return p->prio + p->boost_prio - MIN_NORMAL_PRIO;
}

static inline int task_sched_prio(const struct task_struct *p)
{
	return (p->prio < MIN_NORMAL_PRIO)? (p->prio >> 2) :
		MIN_SCHED_NORMAL_PRIO + (p->prio + p->boost_prio - MIN_NORMAL_PRIO) / 2;
}

static inline int task_running_nice(struct task_struct *p)
{
	return (p->prio + p->boost_prio > DEFAULT_PRIO);
}

static inline void sched_update_rq_clock(struct rq *rq) {}

static inline void sched_task_renew(struct task_struct *p, const struct rq *rq)
{
	deboost_task(p);
}

static inline void sched_task_sanity_check(struct task_struct *p, struct rq *rq) {}
static inline void sched_task_fork(struct task_struct *p, struct rq *rq) {}

static inline void do_sched_yield_type_1(struct task_struct *p, struct rq *rq)
{
	p->boost_prio = MAX_PRIORITY_ADJ;
}

/*
 * While @p runs, ->last_ran is a clock_task stamp of its own rq, which is what
 * update_curr() needs. clock_task is useless across CPUs though: it excludes
 * each CPU's cumulative IRQ and steal time, so two CPUs' clock_task drift apart
 * for as long as the system is up (seconds, and minutes against a CPU that
 * services a busy device interrupt), which would make the wakeup boost a
 * function of the CPU pair instead of the sleep.
 *
 * So when @p blocks, re-stamp ->last_ran with the sleep start in rq->clock,
 * which is sched_clock_cpu() and coherent across CPUs, and measure the sleep
 * against local_clock() on the waking CPU. Nothing reads ->last_ran as a
 * clock_task value between the block and the next switch-in, which resets it
 * in __schedule(); update_curr() in check_curr() is the last writer before
 * that, so __schedule() stamps after check_curr().
 */
static inline void sched_task_sleep(struct task_struct *p, const struct rq *rq)
{
	p->last_ran = rq->clock;
}

static inline void sched_task_ttwu(struct task_struct *p)
{
	s64 delta = local_clock() - p->last_ran;

	/* One boost level per 4.19 ms slept, never more than the full range. */
	if (likely(delta > 0))
		boost_task(p, min_t(s64, delta >> 22, 2 * MAX_PRIORITY_ADJ));
}

static inline void sched_task_deactivate(struct task_struct *p, struct rq *rq)
{
	boost_task(p, 1);
}

#endif /* _KERNEL_SCHED_BMQ_H */
