  ps -eo pid,ppid,stat,psr,wchan:40,comm,args | awk '$3 ~ /D/ || $6 ~ /steam|pressure|proton|wine|game|btop|kwin|gamescope/ {print}'
  sudo sh -c 'echo w > /proc/sysrq-trigger'; sudo dmesg -T | tail -300
  grep -R . /proc/*/wchan 2>/dev/null | grep -Ei 'migration|stop|affine|sched|futex|drm|amdgpu|i915|nvidia'
