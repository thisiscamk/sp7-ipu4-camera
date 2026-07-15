# Surface Pro 7 camera driver port (Intel IPU4, Linux 6.19)

Working **raw capture on both built-in cameras** of a Microsoft Surface
Pro 7 running Fedora 43 with the linux-surface kernel
(6.19.8-3.surface). The SP7's Ice Lake ISP (Intel IPU4/IPU4P, PCI
`8086:8a19`) has no upstream Linux driver; this repo carries an
out-of-tree port based on
[ruslanbay/ipu4-next](https://github.com/ruslanbay/ipu4-next)
(56 patches on vanilla 6.19.8) plus a series of local fixes that take it
from "loads but streams nothing" to reliable captures on both sensors.

**Status (2026-07-15):** front ov5693 (2592x1944) and rear ov8865
(3264x2448) both deliver real RAW10 frames, validated 6/6 across
repeated stream starts. libcamera/PipeWire integration not done yet —
capture is via `v4l2-ctl`/`media-ctl`. The IR camera (ov7251) fails its
i2c probe and is ignored.

## Layout

| Path | What |
|------|------|
| `linux-6.19.8/drivers/media/pci/intel/` | the driver (patched subtree of a vanilla 6.19.8 tree; only this subtree is tracked) |
| `load-ipu4.sh` | load the module stack after boot (modules are blacklisted; one load per boot) |
| `test-capture.sh front\|rear` | media-ctl pipeline setup + 3-frame capture |
| `validate-retry.sh` | full validation suite: TPG + rear sanity, then front x6 |
| `autotest/RESULT.md` | final validation results + root-cause write-up |
| `autotest.sh` | boot-time autonomous test harness (systemd service, optional) |
| `front-diag.sh`, `phy-sweep.sh`, `settle-sweep.sh`, `run-all-tests.sh` | diagnostics used during bring-up |

## Building

Unpack a vanilla `linux-6.19.8` tree here (only
`drivers/media/pci/intel/` from this repo overlays it), have the
distro kernel's headers/build tree installed, then:

```sh
cd linux-6.19.8
make M=drivers/media/pci/intel \
     srcpath=$PWD/drivers/media/pci/intel \
     KBUILD_MODPOST_WARN=1 modules -j8
sudo cp drivers/media/pci/intel/ipu4/*.ko \
     /lib/modules/$(uname -r)/updates/
sudo depmod -a
```

Firmware: `ipu4p_cpd.bin` (ipu4-20191030, Microsoft-signed) goes in
`/usr/lib/firmware/`. It ships in the ipu4-next repo's assets and is
not redistributed here.

`/etc/modprobe.d/ipu4.conf` should blacklist the modules and set
`intel_ipu4p fw_version_check=0`; load manually with `load-ipu4.sh`.
Module reload does not work — one load per boot, reboot to iterate.

## Capturing

```sh
sudo ./load-ipu4.sh
sudo ./test-capture.sh front   # -> front.raw, 3x 2592x1944 RAW10
sudo ./test-capture.sh rear    # -> rear.raw,  3x 3264x2448 RAW10
```

Frames at default exposure are near-black; raise
`exposure`/`analogue_gain` on the sensor subdev for visible content.
Beware: a logged-in desktop session's wireplumber grabs every
`/dev/video*` node the moment the modules load and wrecks captures
(`validate-retry.sh` masks it for the run).

## Fixes carried on top of ipu4-next (upstream candidates)

1. Store `av->pix_fmt` in `vidioc_s_fmt_vid_cap` — single-planar S_FMT
   never recorded the format the link validator reads → EPIPE on
   STREAMON.
2. Bound the media-graph walks in `is_support_vc`/
   `ipu_isys_query_sensor_info` — TPG pipelines ping-pong two entities
   forever → unkillable 100% CPU spin in the kernel.
3. Restore `is_external()`/`ip->external` assignment in the video-node
   `link_validate` (dropped in the 6.19 rewrite) — without it TPG
   pipelines oops in `__media_pipeline_stop` and sensors never stream.
4. Use `media_pipeline_stop_for_vc()` in the `prepare_streaming` error
   path — upstream `media_pipeline_stop()` walks uninitialized pads on
   pipes started by `media_pipeline_start_by_vc()` → NULL-deref oops.
5. Add the missing `pm_runtime_put` in `ipu_buttress_authenticate()`'s
   error/exit path — the leak (one per video-node open, ~50 at load via
   udev) pinned the psys IOMMU forever, so the isys power island could
   never cycle and one wedged stream latched EIO until reboot.
6. Configure D-PHY building block 10 in the buttress PHY setup
   (`{10, 13, 32, 0x15}` in `ipu4p_isys_bb_cfg`) — the front sensor's
   analog front end was simply never programmed; the front camera is
   totally silent without this.
7. Stream-start verification with sensor bounce + buffer parking (see
   below) — makes the front camera's marginal D-PHY link reliable.
8. Diagnostics: runtime-writable module params `csi2_fw_src`,
   `csi2_csettle`/`csi2_dsettle`, `phy_bb_extra`/`phy_afe_extra`/
   `phy_jsl_bits`.

## The front-camera reliability fix, in short

On this link (419.2 MHz x2 lanes) the ov5693's D-PHY clock-lane
settle/DLL lock at the LP->HS transition succeeds only ~25-40% of the
time per stream start, and a missed initial SOT sync is non-recoverable
for the whole stream. On a failed lock the firmware delivers one
STR2MMIO-errored frame per queued buffer, then starves (user space
can't requeue — it's still blocked in STREAMON).

The driver now counts only **error-free** `PIN_DATA_READY` responses
(`frames_done`), and after handing all buffers to the firmware it polls
for a clean frame; if none arrives in 600 ms it bounces the sensor's
`s_stream` to re-roll the lock (up to 15 times). While this runs,
corrupt-frame buffers are **parked back on the incoming queue and
re-fed to the firmware after each bounce**, so the firmware never
starves and the first successful lock is observable within ~150 ms.
Healthy streams are never disturbed; ~half of front starts need no
bounce at all, the rest typically 1-6.

## Known limitations

- One module load per boot (reload wedges the CSE/firmware handshake).
- The start-guard doesn't cover the rare case of a stream dying
  mid-capture after a good start.
- ov7251 (IR) i2c probe fails (`-110`) and is ignored.
- No libcamera/PipeWire integration yet: ipu4-next has patches for
  libcamera 0.7.0, Fedora 43 ships 0.5.2.

## License

The driver code in `linux-6.19.8/drivers/media/pci/intel/` is
GPL-2.0 (Linux kernel / Intel, with changes from ruslanbay/ipu4-next
and this repo). Scripts in the repo root are GPL-2.0 as well.

## References

- https://github.com/ruslanbay/ipu4-next — the port this builds on
- https://github.com/linux-surface/linux-surface — SP7 kernel;
  camera discussion in issue #1353
