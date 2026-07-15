#!/bin/bash
# Sweep CSI-2 data-lane settle counts for the SP7 front camera (ov5693).
# Run as root after a clean boot: sudo /home/user/camera/settle-sweep.sh
# Requires the isys module with csi2_csettle/csi2_dsettle params.
# Baseline (calculated minimum) is dsettle=661 csettle=684 @419.2MHz and
# is ~40% reliable; allowed window is roughly 661..1103 (dsettle) and
# 684..2247 (csettle). Overrides are global but 880 is inside the rear
# ov8865 window too (658..1093 @360MHz), so a mid value is safe for both.
LOGDIR=/home/user/camera/logs
mkdir -p "$LOGDIR"
P=/sys/module/intel_ipu4p_isys/parameters
TRIES=4

cycle_island() {
    echo auto > /sys/bus/intel-ipu4-bus/devices/intel-ipu4-mmu1/power/control
    echo on   > /sys/bus/intel-ipu4-bus/devices/intel-ipu4-mmu0/power/control
    sleep 1
    echo auto > /sys/bus/intel-ipu4-bus/devices/intel-ipu4-mmu0/power/control
    sleep 5
    echo on   > /sys/bus/intel-ipu4-bus/devices/intel-ipu4-mmu1/power/control
    sleep 1
}

front_batch() {   # $1 = label
    local ok=0 i rc size storms
    for i in $(seq 1 $TRIES); do
        dmesg -C
        rm -f /home/user/camera/front.raw
        /home/user/camera/test-capture.sh front > "$LOGDIR/$1-try$i.out" 2>&1
        rc=$?
        size=$(stat -c%s /home/user/camera/front.raw 2>/dev/null || echo 0)
        storms=$(dmesg | grep -c 'status 0x400')
        echo "  $1 try $i: exit=$rc size=$size storms=$storms"
        [ "$size" -gt 0 ] && ok=$((ok+1))
        cycle_island
    done
    echo "$1: $ok/$TRIES"
    [ "$ok" -eq "$TRIES" ] && return 0
    return 1
}

echo "########## LOAD ##########"
/home/user/camera/load-ipu4.sh || exit 1
sleep 1

echo "########## dsettle sweep (csettle default) ##########"
for d in 750 880 1000 1090; do
    echo $d > $P/csi2_dsettle
    if front_batch "dsettle-$d"; then
        echo "STABLE at dsettle=$d"
        echo "########## rear regression check at dsettle=$d ##########"
        /home/user/camera/test-capture.sh rear > "$LOGDIR/rear-dsettle-$d.out" 2>&1
        s=$(stat -c%s /home/user/camera/rear.raw 2>/dev/null || echo 0)
        echo "rear at dsettle=$d: $s bytes"
        exit 0
    fi
done

echo "########## dsettle=880 + csettle=1400 ##########"
echo 880  > $P/csi2_dsettle
echo 1400 > $P/csi2_csettle
front_batch "d880-c1400" && { echo "STABLE at d880/c1400"; exit 0; }

echo "no settle combo reached $TRIES/$TRIES; see $LOGDIR"
