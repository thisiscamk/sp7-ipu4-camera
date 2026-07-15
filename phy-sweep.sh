#!/bin/bash
# Sweep IPU4P PHY building-block configs for the SP7 front camera (ov5693).
# Run as root after a clean boot: sudo /home/user/camera/phy-sweep.sh
# Requires the isys module with phy_bb_extra/phy_afe_extra/phy_jsl_bits params.
# NOTE: buttress PHY regs are in the always-on domain, so writes accumulate
# across tries within a boot (sweep is ordered least->most invasive).
LOGDIR=/home/user/camera/logs
mkdir -p "$LOGDIR"
P=/sys/module/intel_ipu4p_isys/parameters

cycle_island() {
    echo auto > /sys/bus/intel-ipu4-bus/devices/intel-ipu4-mmu1/power/control 2>/dev/null
    echo on   > /sys/bus/intel-ipu4-bus/devices/intel-ipu4-mmu0/power/control
    sleep 1
    echo auto > /sys/bus/intel-ipu4-bus/devices/intel-ipu4-mmu0/power/control
    sleep 5
    echo on   > /sys/bus/intel-ipu4-bus/devices/intel-ipu4-mmu1/power/control 2>/dev/null
    sleep 1
}

front_try() {   # $1 = label
    echo; echo "########## $1 ##########"
    echo "params: bb_extra=$(cat $P/phy_bb_extra) afe=$(cat $P/phy_afe_extra) jsl=$(cat $P/phy_jsl_bits)"
    dmesg -C
    /home/user/camera/test-capture.sh front > "$LOGDIR/$1.out" 2>&1
    rc=$?
    dmesg > "$LOGDIR/$1.dmesg"
    size=$(stat -c%s /home/user/camera/front.raw 2>/dev/null || echo 0)
    echo "$1: exit=$rc front.raw=$size bytes"
    grep -E 'phy: |phy bb ' "$LOGDIR/$1.dmesg" | head -20
    cycle_island
    [ "$size" -gt 0 ] && return 0
    return 1
}

rear_check() {
    /home/user/camera/test-capture.sh rear > "$LOGDIR/rear-check-$1.out" 2>&1
    s=$(stat -c%s /home/user/camera/rear.raw 2>/dev/null || echo 0)
    echo "rear check ($1): $s bytes"
    cycle_island
}

echo "########## LOAD ##########"
/home/user/camera/load-ipu4.sh || exit 1
sleep 1
echo 'module intel_ipu4p_isys +p' > /sys/kernel/debug/dynamic_debug/control \
    || echo "WARN: dyndbg enable failed"
echo 'module intel_ipu4p +p' > /sys/kernel/debug/dynamic_debug/control || true
dmesg -c > "$LOGDIR/00-load.dmesg"

rear_check initial

if front_try phy-baseline; then echo "FRONT WORKS at baseline?!"; exit 0; fi

echo "8,10" > $P/phy_bb_extra
if front_try phy-bb8-10; then echo "FRONT WORKS with bb 8,10"; exit 0; fi
rear_check bb8-10

echo "0,2,8,10" > $P/phy_bb_extra
if front_try phy-bb0-2-8-10; then echo "FRONT WORKS with bb 0,2,8,10"; exit 0; fi

echo 1 > $P/phy_jsl_bits
if front_try phy-jsl-bits; then echo "FRONT WORKS with JSL bits"; exit 0; fi
rear_check jsl

echo "8,10" > $P/phy_bb_extra
echo "0x22,0x22" > $P/phy_afe_extra
if front_try phy-afe22; then echo "FRONT WORKS with afe 0x22"; exit 0; fi

echo "no PHY variant delivered frames; dmesg per try in $LOGDIR/phy-*.dmesg"
rear_check final
