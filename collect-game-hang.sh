#!/usr/bin/env bash
set -u

arg1="${1:-game-hang}"
extra_pattern="${2:-}"
if [[ "$arg1" =~ ^[0-9]+$ ]]; then
	tag="pid-${arg1}"
	target_pid="$arg1"
else
	tag="$arg1"
	target_pid=""
fi
ts="$(date +%Y%m%d-%H%M%S)"
out="$HOME/${tag}-${ts}"
default_pattern='steam|steamwebhelper|reaper|wine|wineserver|winedevice|services\.exe|explorer\.exe|proton|pressure-vessel|gamescope|umu|GameOverlay|idea|jetbrains|fsnotifier|dbus-monitor|kwin_wayland|Xwayland'

mkdir -p "$out/proc" "$out/sys"

echo "[+] collecting into $out"
echo "[+] default process match pattern: $default_pattern"
if [ -n "$target_pid" ]; then
	echo "[+] target pid: $target_pid"
fi
if [ -n "$extra_pattern" ]; then
	echo "[+] extra process match pattern: $extra_pattern"
fi

{
	echo "date: $(date -Is)"
	echo "uname: $(uname -a)"
	echo "uptime:"
	cat /proc/uptime 2>/dev/null || true
	echo
	echo "cmdline:"
	tr '\0' ' ' < /proc/cmdline 2>/dev/null || true
	echo
	echo "kernel release:"
	uname -r
	echo
	echo "collector tag: $tag"
	echo "target pid: $target_pid"
	echo "default process match pattern: $default_pattern"
	echo "extra process match pattern: $extra_pattern"
} > "$out/system.txt" 2>&1

ps -eo pid,ppid,pgid,sid,stat,psr,ni,pri,rtprio,pcpu,pmem,wchan:40,comm,args --sort=-pcpu \
	> "$out/ps-processes.txt" 2>&1 || true

ps -eLo pid,tid,ppid,pgid,sid,stat,psr,ni,pri,rtprio,pcpu,pmem,wchan:40,comm,args --sort=-pcpu \
	> "$out/ps-threads.txt" 2>&1 || true

pstree -apT > "$out/pstree.txt" 2>&1 || true
pstree -aps $$ > "$out/pstree-self.txt" 2>&1 || true

{
	pgrep -a -f -- "$default_pattern" 2>/dev/null || true
	if [ -n "$extra_pattern" ]; then
		pgrep -a -f -- "$extra_pattern" 2>/dev/null || true
	fi
	if [ -n "$target_pid" ] && [ -d "/proc/$target_pid" ]; then
		ps -p "$target_pid" -o pid=,args= 2>/dev/null || true
		pgrep -a -P "$target_pid" 2>/dev/null || true
	fi
} > "$out/matching-processes.txt" 2>&1 || true

mapfile -t pids < <(
	{
		pgrep -f -- "$default_pattern" 2>/dev/null || true
		if [ -n "$extra_pattern" ]; then
			pgrep -f -- "$extra_pattern" 2>/dev/null || true
		fi
		if [ -n "$target_pid" ] && [ -d "/proc/$target_pid" ]; then
			echo "$target_pid"
			pgrep -P "$target_pid" 2>/dev/null || true
			awk -v root="$target_pid" '
				NR == 1 { next }
				{ ppid[$1] = $2 }
				END {
					for (pid in ppid) {
						delete seen
						cur = pid
						while ((cur in ppid) && !seen[cur]++) {
							if (ppid[cur] == root) {
								print pid
								break
							}
							cur = ppid[cur]
						}
					}
				}
			' "$out/ps-processes.txt" 2>/dev/null || true
		fi
		awk 'NR > 1 && ($6 ~ /^D/ || $6 ~ /^Z/) {print $1}' "$out/ps-threads.txt" 2>/dev/null || true
	} | sort -n | uniq
)

for pid in "${pids[@]}"; do
	[ -d "/proc/$pid" ] || continue
	pdir="$out/proc/$pid"
	mkdir -p "$pdir/task"

	for f in status stat sched schedstat wchan stack comm limits maps smaps_rollup; do
		if [ -r "/proc/$pid/$f" ]; then
			cp "/proc/$pid/$f" "$pdir/$f" 2>/dev/null || true
		fi
	done

	if [ -r "/proc/$pid/cmdline" ]; then
		tr '\0' ' ' < "/proc/$pid/cmdline" > "$pdir/cmdline.txt" 2>/dev/null || true
	fi

	for t in /proc/"$pid"/task/*; do
		[ -d "$t" ] || continue
		tid="${t##*/}"
		tdir="$pdir/task/$tid"
		mkdir -p "$tdir"

		for f in status stat sched schedstat wchan stack comm; do
			if [ -r "$t/$f" ]; then
				cp "$t/$f" "$tdir/$f" 2>/dev/null || true
			fi
		done
	done
done

for f in \
	/proc/sched_debug \
	/proc/interrupts \
	/proc/softirqs \
	/proc/stat \
	/proc/loadavg \
	/proc/pressure/cpu \
	/proc/pressure/io \
	/proc/pressure/memory
do
	if [ -r "$f" ]; then
		name="$(echo "$f" | sed 's#^/proc/##; s#/#-#g')"
		cp "$f" "$out/sys/$name.txt" 2>/dev/null || true
	fi
done

echo "[+] triggering non-destructive SysRq dumps: w and l"

if [ -w /proc/sysrq-trigger ]; then
	echo w > /proc/sysrq-trigger 2>/dev/null || true
	sleep 1
	echo l > /proc/sysrq-trigger 2>/dev/null || true
	sleep 1
else
	echo "no write access to /proc/sysrq-trigger" > "$out/sysrq-note.txt"
fi

dmesg -T > "$out/dmesg.txt" 2>&1 || true
journalctl -k -b -o short-monotonic --no-pager > "$out/journal-kernel.txt" 2>&1 || true

if command -v perf >/dev/null 2>&1; then
	echo "[+] collecting short perf sample"
	perf record -F 99 -g -a -o "$out/perf.data" -- sleep 10 > "$out/perf-record.log" 2>&1 || true
	perf report -i "$out/perf.data" --stdio > "$out/perf-report.txt" 2>&1 || true
fi

tar -C "$HOME" -caf "$out.tar.zst" "$(basename "$out")" 2>/dev/null || \
tar -C "$HOME" -caf "$out.tar.xz" "$(basename "$out")" 2>/dev/null || \
tar -C "$HOME" -czf "$out.tar.gz" "$(basename "$out")"

echo "[+] done:"
ls -lh "$out".tar.* 2>/dev/null || true
