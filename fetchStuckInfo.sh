#!/usr/bin/env bash
# Collect diagnostics while the desktop is still alive but a process is stuck.
# Useful for kernel package hangs around strip/install/cp as well as scheduler
# migration/affinity stalls.  Run as root for full stacks, or with sudo cached.

set -u
export LC_ALL=C

if (( EUID == 0 )); then
	SUDO=()
else
	SUDO=(sudo)
fi

section()
{
	printf '\n===== %s =====\n' "$1"
}

run()
{
	section "$*"
	"$@" 2>&1 || true
}

run_timeout()
{
	local timeout_s=$1
	shift
	section "$*"
	timeout "${timeout_s}s" "$@" 2>&1 || true
}

run_sudo_timeout()
{
	local timeout_s=$1
	shift
	section "$*"
	timeout "${timeout_s}s" "${SUDO[@]}" "$@" 2>&1 || true
}

print_file()
{
	local path=$1

	section "$path"
	if [[ -r $path ]]; then
		cat "$path" 2>&1 || true
	else
		printf 'unreadable or missing\n'
	fi
}

collect_pid()
{
	local pid=$1
	local task tid

	[[ -d /proc/$pid ]] || return 0

	section "process $pid summary"
	printf 'comm: '
	cat "/proc/$pid/comm" 2>/dev/null || true
	printf 'cmdline: '
	tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true
	printf '\n'

	print_file "/proc/$pid/status"
	print_file "/proc/$pid/wchan"
	run_sudo_timeout 5 cat "/proc/$pid/stack"
	print_file "/proc/$pid/sched"

	section "process $pid thread table"
	ps -T -p "$pid" -o pid,tid,stat,psr,policy,rtprio,wchan:40,comm,args 2>&1 || true

	for task in /proc/"$pid"/task/[0-9]*; do
		[[ -d $task ]] || continue
		tid=${task##*/}
		section "process $pid thread $tid"
		print_file "$task/status"
		print_file "$task/wchan"
		run_sudo_timeout 5 cat "$task/stack"
		print_file "$task/sched"
	done
}

collect_sysrq()
{
	local key=$1

	section "sysrq $key"
	printf '%s' "$key" | "${SUDO[@]}" tee /proc/sysrq-trigger >/dev/null 2>&1 || true
	sleep 1
}

section "basic system state"
date -Ins 2>&1 || true
uname -a 2>&1 || true
cat /proc/loadavg 2>&1 || true
cat /proc/uptime 2>&1 || true

print_file /proc/pressure/cpu
print_file /proc/pressure/io
print_file /proc/pressure/memory

run ps -eLo pid,tid,ppid,stat,psr,policy,rtprio,wchan:40,comm,args

section "D-state tasks"
ps -eLo pid,tid,ppid,stat,psr,policy,rtprio,wchan:40,comm,args 2>&1 |
	awk 'NR == 1 || $4 ~ /D/ { print }'

section "interesting stuck-process candidates"
ps -eLo pid,tid,ppid,stat,psr,policy,rtprio,wchan:40,comm,args 2>&1 |
	awk '
		NR == 1 { print; next }
		$4 ~ /D/ ||
		$8 ~ /(migration|stop|affine|sched|futex|drm|amdgpu|i915|nvidia|io_schedule|blk|writeback|sync|completion|rwsem|mutex)/ ||
		$9 ~ /^(cp|strip|install|make|makepkg|fakeroot|tar|bsdtar|zstd|xz|pacman|btop|kwin|kwin_wayland|steam|pressure-vessel|proton|wine|gamescope)$/ ||
		$0 ~ /(cp |strip|install|makepkg|fakeroot|bsdtar|zstd|pacman|steam|pressure-vessel|proton|wine|gamescope)/ {
			print
		}'

mapfile -t PIDS < <(
	ps -eLo pid,tid,ppid,stat,psr,policy,rtprio,wchan:40,comm,args --no-headers 2>/dev/null |
	awk '
		$4 ~ /D/ ||
		$8 ~ /(migration|stop|affine|sched|io_schedule|blk|writeback|completion|rwsem|mutex)/ ||
		$9 ~ /^(cp|strip|install|make|makepkg|fakeroot|tar|bsdtar|zstd|xz|pacman|btop|kwin|kwin_wayland|steam|pressure-vessel|proton|wine|gamescope)$/ ||
		$0 ~ /(cp |strip|install|makepkg|fakeroot|bsdtar|zstd|pacman|steam|pressure-vessel|proton|wine|gamescope)/ {
			print $1
		}' |
	sort -n -u
)

section "selected pids"
printf '%s\n' "${PIDS[@]:-none}"

for pid in "${PIDS[@]}"; do
	collect_pid "$pid"
done

# Capture EVERY runnable (R) thread system-wide with stack + schedstat.
# A scheduler strand shows up here as a thread that is R (runnable) but sitting
# on no CPU: its stack is parked in schedule()/__schedule and its schedstat
# field 2 (time spent runnable-but-not-running, ns) keeps climbing. This is the
# data the pid-filtered collection above misses (e.g. containerized workloads
# whose comm is not in the keyword list).
# Collect R-state threads first (as full task dir paths) so we can read their
# authoritative on_rq via drgn and re-use the exact path for stack/schedstat.
RTDIRS=()
RTIDS=()
for tstat in /proc/[0-9]*/task/[0-9]*/stat; do
	read -r _ rest < "$tstat" 2>/dev/null || continue
	# field 3 is state; comm (field 2) may contain ') ' so strip to last ') '.
	state=${rest##*) }; state=${state%% *}
	[[ $state == R ]] || continue
	tdir=${tstat%/stat}
	RTDIRS+=("$tdir")
	RTIDS+=("${tdir##*/}")
done

# The DECIDER: on_rq from live kernel memory (ps "R" is NOT authoritative).
#   on_rq != 0 (1=QUEUED 2=MIGRATING 11=WAKING 12=PREEMPT) => REAL scheduler strand.
#   on_rq == 0 with state TASK_RUNNING(0x0) => off-rq, asleep (e.g. futex) => userspace.
# Requires vmlinux (repo root, DWARF) + drgn. Best-effort; skipped if unavailable.
section "R-thread on_rq via drgn (authoritative strand decider)"
VMLINUX="$(dirname "$(readlink -f "$0")")/vmlinux"
[[ -r $VMLINUX ]] || VMLINUX=./vmlinux
if command -v drgn >/dev/null && [[ -r $VMLINUX && ${#RTIDS[@]} -gt 0 ]]; then
	printf 'tids: %s\n' "${RTIDS[*]}"
	timeout 30s "${SUDO[@]}" drgn -s "$VMLINUX" -e '
import sys
tids = [int(x) for x in "'"${RTIDS[*]}"'".split()]
for tid in tids:
    t = find_task(tid)
    if not t:
        print(tid, "-> gone"); continue
    on_rq = t.on_rq.value_()
    verdict = "STRAND(on_rq!=0)" if on_rq != 0 else "userspace(off-rq)"
    print("tid=%d comm=%s on_rq=%d state=0x%x on_cpu=%d wake_cpu=%d __sched_prio=%d pq_node.next=0x%x  -> %s" % (
        tid, t.comm.string_().decode(), on_rq, t.__state.value_(), t.on_cpu.value_(),
        t.wake_cpu.value_(), t.__sched_prio.value_(), t.pq_node.next.value_(), verdict))
' 2>&1 | grep -vE "missing debugging symbols|missing some debugging|^warning: " || true
else
	printf 'skipped: drgn=%s vmlinux=%s rtids=%d\n' \
		"$(command -v drgn || echo no)" "$([[ -r $VMLINUX ]] && echo yes || echo no)" "${#RTIDS[@]}"
fi

# THE no-load decider (catches what the R-state scan above misses). A task in
# TASK_RUNNING(0) MUST be either on a cpu (on_cpu==1) or queued (on_rq!=0). If it
# is RUNNING yet on_cpu==0 AND on_rq==0, the scheduler LOST it -- a dropped
# wakeup/enqueue. That is the "idle machine, app stuck on futex" signature, which
# the R-state scan cannot see because the victim is parked in schedule() (state
# shows as sleeping in /proc but the kernel's authoritative __state is RUNNING).
# on_rq!=0 while cpus idle = a dispatch strand. Two passes ~1.5s apart: a tid in
# BOTH passes is a confirmed persistent loss (a single hit can be a switch transient).
section "system-wide LOST-task scan via drgn (off-rq + RUNNING = dropped wakeup)"
if command -v drgn >/dev/null && [[ -r $VMLINUX ]]; then
	for pass in 1 2; do
		printf -- '--- pass %d ---\n' "$pass"
		timeout 40s "${SUDO[@]}" drgn -s "$VMLINUX" -e '
try:
    tasks = for_each_task()
except TypeError:
    tasks = for_each_task(prog)
for t in tasks:
    try:
        on_rq = t.on_rq.value_(); st = t.__state.value_(); on_cpu = t.on_cpu.value_()
    except Exception:
        continue
    if st == 0 and on_cpu == 0 and on_rq == 0:
        print("LOST tid=%d comm=%s wake_cpu=%d prio=%d" % (
            t.pid.value_(), t.comm.string_().decode(), t.wake_cpu.value_(), t.__sched_prio.value_()))
    elif on_rq != 0:
        print("ONRQ tid=%d comm=%s on_rq=%d state=0x%x on_cpu=%d wake_cpu=%d prio=%d" % (
            t.pid.value_(), t.comm.string_().decode(), on_rq, st, on_cpu,
            t.wake_cpu.value_(), t.__sched_prio.value_()))
' 2>&1 | grep -vE "missing debugging symbols|missing some debugging|^warning: " || true
		[[ $pass == 1 ]] && sleep 1.5
	done
	printf 'VERDICT: a LOST tid in BOTH passes = confirmed dropped wakeup (kernel bug).\n'
	printf '         an ONRQ tid in BOTH passes while cpus idle = dispatch strand.\n'
else
	printf 'skipped: drgn or vmlinux unavailable\n'
fi

section "all runnable (R-state) threads — stack + schedstat"
for tdir in "${RTDIRS[@]}"; do
	[[ -d $tdir ]] || continue
	tid=${tdir##*/}
	pid=${tdir%/task/*}; pid=${pid##*/}
	comm=$(cat "$tdir/comm" 2>/dev/null || true)

	section "R-thread pid $pid tid $tid ($comm)"
	printf 'schedstat (run_ns wait_ns timeslices): '
	cat "$tdir/schedstat" 2>/dev/null || true
	printf 'wchan: '; cat "$tdir/wchan" 2>/dev/null; printf '\n'
	run_sudo_timeout 5 cat "$tdir/stack"
done

section "wchan sweep"
for proc in /proc/[0-9]*; do
	pid=${proc##*/}
	[[ -r $proc/wchan ]] || continue
	wchan=$(cat "$proc/wchan" 2>/dev/null || true)
	comm=$(cat "$proc/comm" 2>/dev/null || true)
	case "$wchan $comm" in
		*migration*|*stop*|*affine*|*sched*|*futex*|*drm*|*amdgpu*|*i915*|*nvidia*|*io_schedule*|*blk*|*writeback*|*sync*|*completion*|*rwsem*|*mutex*|*cp*|*strip*|*install*|*make*|*makepkg*|*fakeroot*|*tar*|*bsdtar*|*zstd*|*xz*|*pacman*)
			printf '/proc/%s/wchan:%s comm:%s\n' "$pid" "$wchan" "$comm"
			;;
	esac
done

collect_sysrq w
collect_sysrq t
collect_sysrq l

section "dmesg tail after sysrq"
timeout 15s "${SUDO[@]}" dmesg -T 2>&1 | tail -1000 || true
