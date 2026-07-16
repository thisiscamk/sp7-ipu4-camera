#!/usr/bin/env python3
"""Enable a media-controller link, preserving its DYNAMIC flag.

Usage: enable-link.py '<source entity>':<pad> '<sink entity>':<pad> [<flags>]

media-ctl (through at least v4l-utils 1.32) passes only MEDIA_LNK_FL_ENABLED
to MEDIA_IOC_SETUP_LINK, which the kernel rejects with EINVAL for links
carrying MEDIA_LNK_FL_DYNAMIC (the flag must be preserved). The IPU4 CSI2 BE
SOC links are dynamic, so media-ctl cannot enable them; this helper can.
"""
import fcntl
import os
import re
import struct
import sys

MEDIA_IOC_ENUM_ENTITIES = (3 << 30) | (ord('|') << 8) | 1 | (0x100 << 16)
MEDIA_IOC_SETUP_LINK = (3 << 30) | (ord('|') << 8) | 3 | (52 << 16)
MEDIA_ENT_ID_FLAG_NEXT = 1 << 31

PAD_FMT = 'IHxxI2I'  # struct media_pad_desc


def find_entity(fd, name):
    entity_id = 0
    while True:
        buf = bytearray(0x100)
        struct.pack_into('I', buf, 0, entity_id | MEDIA_ENT_ID_FLAG_NEXT)
        try:
            fcntl.ioctl(fd, MEDIA_IOC_ENUM_ENTITIES, buf)
        except OSError:
            return None
        entity_id, = struct.unpack_from('I', buf, 0)
        ename = buf[4:36].split(b'\0')[0].decode()
        if ename == name:
            return entity_id


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    flags = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0x5  # ENABLED|DYNAMIC
    refs = []
    for arg in sys.argv[1:3]:
        m = re.fullmatch(r'(.+):(\d+)', arg)
        if not m:
            sys.exit(f'bad pad reference: {arg}')
        refs.append((m.group(1), int(m.group(2))))

    fd = os.open('/dev/media0', os.O_RDWR)
    ids = []
    for name, pad in refs:
        eid = find_entity(fd, name)
        if eid is None:
            sys.exit(f'entity not found: {name}')
        ids.append((eid, pad))

    def pad_desc(entity, index):
        return struct.pack(PAD_FMT, entity, index, 0, 0, 0)

    buf = pad_desc(*ids[0]) + pad_desc(*ids[1]) + struct.pack('I2I', flags, 0, 0)
    fcntl.ioctl(fd, MEDIA_IOC_SETUP_LINK, buf)
    os.close(fd)
    print(f'link {refs[0][0]}:{refs[0][1]} -> {refs[1][0]}:{refs[1][1]} flags {flags:#x}')


if __name__ == '__main__':
    main()
