#!/usr/bin/env bash
set -u

tag="${1:-game-hang}"
ts="$(date +%Y%m%d-%H%M%S)"
out="$HOME/${tag}-${ts}"

mkdir -p "$out/proc" "$out/sys"

echo "[+] collecting into $out"

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
} > "$out/system.txt" 2>&1

ps -eo pid,ppid,pgid,sid,stat,psr,ni,pri,rtprio,pcpu,pmem,wchan:40,comm,args --sort=-pcpu \
	> "$out/ps-processes.txt" 2>&1 || true

ps -eLo pid,tid,ppid,pgid,sid,stat,psr,ni,pri,rtprio,pcpu,pmem,wchan:40,comm,args --sort=-pcpu \
	> "$out/ps-threads.txt" 2>&1 || true

pstree -apT > "$out/pstree.txt" 2>&1 || true
pstree -aps $$ > "$out/pstree-self.txt" 2>&1 || true

pgrep -a -f 'steam|steamwebhelper|reaper|wine|wineserver|winedevice|services\.exe|explorer\.exe|proton|pressure-vessel|gamescope|umu|GameOverlay' \
	> "$out/matching-processes.txt" 2>&1 || true

mapfile -t pids < <(
	{
		pgrep -f 'steam|steamwebhelper|reaper|wine|wineserver|winedevice|services\.exe|explorer\.exe|proton|pressure-vessel|gamescope|umu|GameOverlay' 2>/dev/null || true
		ps -eo pid=,comm= | awk '$2 ~ /(steam|wine|wineserver|reaper|gamescope)/ {print $1}' 2>/dev/null || true
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
