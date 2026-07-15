#!/bin/bash
# Front camera (ov5693) diagnostic battery. Run as root after a clean boot:
#   sudo /home/user/camera/front-diag.sh
# Relies on the buttress auth PM-leak fix: the isys island can now be
# power-cycled between attempts, so multiple tries per boot are possible.
LOGDIR=/home/user/camera/logs
mkdir -p "$LOGDIR"
PARAM=/sys/module/intel_ipu4p_isys/parameters/csi2_fw_src

pmstate() {
    for d in intel-ipu4-mmu0 intel-ipu4-mmu1 intel-ipu60; do
        echo -n "$d=$(cat /sys/bus/intel-ipu4-bus/devices/$d/power/runtime_status) "
    done
    echo
}

cycle_island() {
    # mmu1 must go down before mmu0 can (mmu1 is mmu0's child);
    # forcing both on then auto lets RPM cascade the suspends.
    # mmu1 is normally pinned 'on' (psys handshake-timeout guard in
    # load-ipu4.sh) — unpin for the cycle, re-pin afterwards.
    echo auto > /sys/bus/intel-ipu4-bus/devices/intel-ipu4-mmu1/power/control 2>/dev/null
    echo on   > /sys/bus/intel-ipu4-bus/devices/intel-ipu4-mmu0/power/control
    sleep 1
    echo auto > /sys/bus/intel-ipu4-bus/devices/intel-ipu4-mmu0/power/control
    sleep 5
    echo on   > /sys/bus/intel-ipu4-bus/devices/intel-ipu4-mmu1/power/control 2>/dev/null
    sleep 1
    echo "after cycle: $(pmstate)"
}

front_try() {   # $1 = label
    echo; echo "########## $1 ##########"
    dmesg -C
    (
        sleep 6
        {
        echo "--- mid-stream power state ($1)"
        grep -E 'INT3472:0[012]-clk' /sys/kernel/debug/clk/clk_summary
        grep -E 'INT33BE|INT3472' /sys/kernel/debug/regulator/regulator_summary
        grep -iE 'privacy|reset' /sys/kernel/debug/gpio
        } > "$LOGDIR/$1-power.txt" 2>&1
    ) &
    /home/user/camera/test-capture.sh front > "$LOGDIR/$1.out" 2>&1
    rc=$?
    wait
    dmesg > "$LOGDIR/$1.dmesg"
    size=$(stat -c%s /home/user/camera/front.raw 2>/dev/null || echo 0)
    echo "$1: exit=$rc front.raw=$size bytes"
    cycle_island
    [ "$size" -gt 0 ] && return 0
    return 1
}

echo "########## LOAD ##########"
/home/user/camera/load-ipu4.sh || exit 1
echo 'module intel_ipu4p_isys +p' > /sys/kernel/debug/dynamic_debug/control
echo 'module intel_ipu4p +p'      > /sys/kernel/debug/dynamic_debug/control
echo 'module ov5693 +p'           > /sys/kernel/debug/dynamic_debug/control
dmesg -c > "$LOGDIR/00-load.dmesg"

echo "pm before tests: $(pmstate)"

# Sanity: rear camera should still work (also proves fw/ISP path OK)
echo; echo "########## REAR SANITY ##########"
/home/user/camera/test-capture.sh rear > "$LOGDIR/rear-sanity.out" 2>&1
echo "rear: exit=$? size=$(stat -c%s /home/user/camera/rear.raw 2>/dev/null || echo 0)"
dmesg -c > "$LOGDIR/rear-sanity.dmesg"
cycle_island

# Baseline front attempt (builtin fw source 7 for CSI-2 2)
if front_try front-src7-baseline; then
    echo "FRONT WORKS with default mapping"; exit 0
fi

# Sweep alternative fw stream source ids for CSI-2 index 2
for src in 6 8 9 4 5; do
    echo "-1,-1,$src" > "$PARAM"
    if front_try "front-src$src"; then
        echo "FRONT WORKS with fw source $src"
        exit 0
    fi
done
echo "-1,-1,-1" > "$PARAM"

echo; echo "no fw source variant delivered frames; see $LOGDIR/front-*-power.txt for rail/clock state"
