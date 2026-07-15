#!/bin/bash
# Configure the media pipeline and capture 3 raw frames.
#   ./test-capture.sh front   (ov5693, 2592x1944, CSI-2 port 2)
#   ./test-capture.sh rear    (ov8865, 3264x2448, CSI-2 port 0)
set -e

CAM="${1:-front}"
if [ "$CAM" = front ]; then
    SENSOR='ov5693 1-0036';  PORT=2; RES=2592x1944
else
    SENSOR='ov8865 2-0010';  PORT=0; RES=3264x2448
fi
FMT=SBGGR10_1X10

media-ctl -d /dev/media0 -r
media-ctl -d /dev/media0 -V "\"$SENSOR\":0 [fmt:$FMT/$RES]"
media-ctl -d /dev/media0 -V "\"Intel IPU4 CSI-2 $PORT\":0 [fmt:$FMT/$RES]"
media-ctl -d /dev/media0 -V "\"Intel IPU4 CSI-2 $PORT\":1 [fmt:$FMT/$RES]"
media-ctl -d /dev/media0 -V "\"Intel IPU4 CSI2 BE\":0 [fmt:$FMT/$RES]"
media-ctl -d /dev/media0 -V "\"Intel IPU4 CSI2 BE\":1 [fmt:$FMT/$RES]"
media-ctl -d /dev/media0 -l "\"$SENSOR\":0 -> \"Intel IPU4 CSI-2 $PORT\":0 [1]"
media-ctl -d /dev/media0 -l "\"Intel IPU4 CSI-2 $PORT\":1 -> \"Intel IPU4 CSI2 BE\":0 [1]"
media-ctl -d /dev/media0 -l "\"Intel IPU4 CSI2 BE\":1 -> \"Intel IPU4 CSI2 BE capture\":0 [1]"

DEV=$(media-ctl -d /dev/media0 -e "Intel IPU4 CSI2 BE capture")
W=${RES%x*}; H=${RES#*x}
echo "capturing from $DEV ($CAM camera, $RES)..."
timeout 30 v4l2-ctl -d "$DEV" \
    --set-fmt-video=width=$W,height=$H,pixelformat=BG10 \
    --stream-mmap=4 --stream-count=3 \
    --stream-to=/home/user/camera/$CAM.raw
ls -la /home/user/camera/$CAM.raw
