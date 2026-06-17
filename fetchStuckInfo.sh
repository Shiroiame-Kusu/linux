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
section "all runnable (R-state) threads — stack + schedstat"
for tstat in /proc/[0-9]*/task/[0-9]*/stat; do
	read -r _ rest < "$tstat" 2>/dev/null || continue
	# field 3 of stat is state; comm (field 2) may contain spaces inside (),
	# so strip up to the last ') ' before reading state.
	state=${rest##*) }
	state=${state%% *}
	[[ $state == R ]] || continue

	tdir=${tstat%/stat}
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
