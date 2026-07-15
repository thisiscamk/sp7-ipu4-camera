#!/bin/bash
# Autonomous IPU4 camera test cycle — run at boot by camera-autotest.service.
#
# Each boot: run the validation suite, then resume the Claude Code session
# headlessly so it can analyze results, fix, rebuild, and reboot for the
# next cycle. This script NEVER reboots on its own — only the resumed
# Claude session decides to reboot, so a failure here leaves the machine up.
#
# Kill switches:
#   sudo touch /home/user/camera/autotest/DONE          (skip all future cycles)
#   sudo systemctl disable camera-autotest.service      (remove from boot)
# Hard cap: MAX_BOOTS cycles, then the service disables itself.

CAM=/home/user/camera
AT=$CAM/autotest
MAX_BOOTS=8

mkdir -p "$AT"
[ -f "$AT/DONE" ] && exit 0

n=$(cat "$AT/count" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$AT/count"

if [ "$n" -gt "$MAX_BOOTS" ]; then
    echo "max boots ($MAX_BOOTS) reached" > "$AT/DONE"
    systemctl disable camera-autotest.service
    exit 0
fi

BOOTDIR=$AT/boot-$n
mkdir -p "$BOOTDIR"
exec > "$BOOTDIR/autotest.log" 2>&1
set -x
date

# Let CSE/ISP firmware settle after boot (manual-load flow assumed a
# leisurely human login before touching the ISP).
sleep 60

# Fresh logs dir for this cycle; keep the previous one with the boot record.
[ -d "$CAM/logs" ] && mv "$CAM/logs" "$BOOTDIR/prev-logs"
mkdir -p "$CAM/logs"

timeout 900 "$CAM/validate-retry.sh" > "$CAM/logs/validate.out" 2>&1
echo "validate-retry exit: $?"
cp -r "$CAM/logs" "$BOOTDIR/logs"

# Need network for the Claude API before handing over control.
nm-online -q -t 180
sleep 5

runuser -l user -c "cd /home/user/camera && /home/user/.local/bin/claude --continue --dangerously-skip-permissions -p 'AUTONOMOUS REBOOT CYCLE boot $n of $MAX_BOOTS (no human present; camera-autotest.service ran validate-retry.sh at boot). Results: /home/user/camera/logs/validate.out, per-try dmesg in /home/user/camera/logs/, boot record in /home/user/camera/autotest/boot-$n/. Analyze the results. If FRONT SUCCESS RATE >= 5/6: do real-image validation (exposure=1900 analogue_gain=127 on the ov5693 subdev, capture front, verify non-flat pixel content), write a full summary to /home/user/camera/autotest/RESULT.md, touch /home/user/camera/autotest/DONE, sudo systemctl disable camera-autotest.service, and update your memory file — do NOT reboot again. Otherwise: diagnose from the logs (dyndbg on the live module works within this boot), fix the driver, rebuild and install the module, update your memory file, then sudo systemctl reboot for the next cycle. If you conclude the approach cannot work or you are out of ideas, write findings to RESULT.md, touch DONE, disable the service, and stop instead of burning cycles.'" > "$BOOTDIR/claude.out" 2>&1
echo "claude exit: $?"
date
