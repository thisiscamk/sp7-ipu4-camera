#!/bin/bash
# Rebuild Fedora's libcamera package with the SP7 IPU4 patch.
#
# Keeping the distro version (0.5.2) means pipewire-plugin-libcamera
# stays ABI-compatible and needs no rebuild. Fedora's package already
# carries the software-ISP backports the IPU4 needs; the one patch here
# adds the intel-ipu4-isys simple-pipeline entry and tolerates the fw's
# fourcc adjustment (backport of ruslanbay/ipu4-next libcamera hacks).
#
# NB: a distro libcamera update will overwrite this build — re-run this
# script afterwards (or `dnf versionlock add libcamera*`).
set -e
cd "$(dirname "$0")"

sudo dnf -y install rpm-build rpmdevtools
dnf download --source libcamera
sudo dnf -y builddep libcamera-*.src.rpm
rpm -i libcamera-*.src.rpm

cp 2001-pipeline-simple-Intel-IPU4-support.patch ~/rpmbuild/SOURCES/
sed -i -e 's/^\(Release: *[0-9]*\)%{?dist}/\1.ipu4.1%{?dist}/' \
    -e '/^Patch16:/a Patch17: 2001-pipeline-simple-Intel-IPU4-support.patch' \
    ~/rpmbuild/SPECS/libcamera.spec

rpmbuild -ba ~/rpmbuild/SPECS/libcamera.spec

sudo dnf -y upgrade \
    ~/rpmbuild/RPMS/x86_64/libcamera-0*.rpm \
    ~/rpmbuild/RPMS/x86_64/libcamera-ipa-0*.rpm \
    ~/rpmbuild/RPMS/x86_64/libcamera-tools-0*.rpm
