#!/bin/bash
# build-deb.sh - Build Debian packages of this kernel for a Proxmox VE host
# Usage: ./build-deb.sh
#
# Builds the tree the way the PKGBUILD does (its BUILD_FLAGS, KBUILD_BUILD_*,
# pkgrel and _pkgsuffix, and `config`), then packages it with the kernel's own
# scripts/package/mkdebian and builddeb. `make bindeb-pkg` is not used: its
# debian/rules needs debhelper, which Arch only has in the AUR. The dh_* steps
# are replaced by dpkg-gencontrol and dpkg-deb (pacman -S dpkg).
#
# Output, in the top directory:
#   linux-image-<release>_<pkgver>-<pkgrel>_amd64.deb
#   linux-headers-<release>_<pkgver>-<pkgrel>_amd64.deb
# linux-libc-dev and the -dbg package are not built.
#
# The image package runs /etc/kernel/{preinst,postinst,prerm,postrm}.d hooks
# on install/removal, so initramfs-tools, DKMS and proxmox-boot-tool see it
# like any other kernel.
#
# The headers package carries host programs (fixdep, modpost, objtool,
# sign-file, ...) built here, which DKMS runs on the PVE host. They are
# checked against the target's glibc and libraries before packaging; objtool
# is rebuilt without its optional disassembler (Arch links a static libopcodes
# that pulls in libsframe.so.3, which Debian does not ship) and without klp.
#
# Environment:
#   JOBS               parallel jobs (default: nproc - 2, as in the PKGBUILD)
#   DEB_TARGET_GLIBC   newest glibc symbol version allowed in the headers
#                      package's host programs (default: 2.41, Debian 13 / PVE 9)
#   DEBFULLNAME, DEBEMAIL
#                      Maintainer field (default: git user.name / user.email)

set -euo pipefail

cd "$(dirname "$(realpath "$0")")"

: "${JOBS:=$(( $(nproc) - 2 ))}"
: "${DEB_TARGET_GLIBC:=2.41}"

# Sonames the headers package's host programs may need; all are in a
# standard Debian 13 / PVE 9 install.
allowed_sonames=(
    ld-linux-x86-64.so.2
    libc.so.6
    libm.so.6
    libcrypto.so.3
    libelf.so.1
    libz.so.1
    libzstd.so.1
)

die() {
    echo "build-deb.sh: $*" >&2
    exit 1
}

for tool in dpkg-gencontrol dpkg-deb readelf md5sum; do
    command -v "$tool" >/dev/null || die "$tool not found (dpkg-gencontrol/dpkg-deb: pacman -S dpkg)"
done

# pkgver, pkgrel, pkgbase, BUILD_FLAGS and the KBUILD_BUILD_* exports.
# shellcheck source=PKGBUILD
source ./PKGBUILD

if [[ -z ${DEBFULLNAME:-} ]] && name=$(git config user.name); then
    export DEBFULLNAME=$name
fi
if [[ -z ${DEBEMAIL:-} ]] && email=$(git config user.email); then
    export DEBEMAIL=$email
fi

kmake() {
    make "${BUILD_FLAGS[@]}" "$@"
}

echo "==> Preparing $pkgbase $pkgver-$pkgrel"
echo "-$pkgrel" > localversion.10-pkgrel
echo "${pkgbase#linux}" > localversion.20-pkgname
cp config .config

echo "==> Building kernel"
kmake -j"$JOBS" all

kr=$(kmake -s kernelrelease)
[[ $kr == *"${pkgbase#linux}"* ]] || die "kernel release '$kr' does not contain '${pkgbase#linux}'"
echo "==> Kernel release $kr"

image_pkg=linux-image-$kr
headers_pkg=linux-headers-$kr
headers_dir=debian/$headers_pkg/usr/src/$headers_pkg

echo "==> Generating debian/"
KDEB_PKGVERSION=$pkgver-$pkgrel KDEB_SOURCENAME=$pkgbase KDEB_CHANGELOG_DIST=trixie \
    kmake run-command KBUILD_RUN_COMMAND='+$(srctree)/scripts/package/mkdebian'

for pkg in "$image_pkg" "$headers_pkg"; do
    echo "==> Installing files for $pkg"
    kmake -j"$JOBS" run-command KBUILD_RUN_COMMAND="+\$(srctree)/scripts/package/builddeb $pkg"
done
rm -f "debian/$image_pkg/lib/modules/$kr/build" "debian/$image_pkg/lib/modules/$kr/source"

echo "==> Rebuilding objtool for the headers package"
mkdir -p debian/objtool-deb
make -C tools/objtool O="$PWD/debian/objtool-deb" LLVM=1 LDFLAGS= \
    LIBOPCODES_LIBS= HAVE_XXHASH=n -j"$JOBS"
install -m755 debian/objtool-deb/objtool "$headers_dir/tools/objtool/objtool"

echo "==> Checking host programs in $headers_pkg (target glibc $DEB_TARGET_GLIBC)"
bad=0
while IFS= read -r -d '' f; do
    [[ $(head -c4 "$f") == $'\x7fELF' ]] || continue
    rel=${f#"$headers_dir"/}
    while read -r so; do
        if [[ " ${allowed_sonames[*]} " != *" $so "* ]]; then
            echo "  $rel: needs $so, which is not on the allowed list" >&2
            bad=1
        fi
    done < <(readelf -dW "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
    need=$(readelf -W --version-info "$f" | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -n1)
    if [[ -n $need ]] && [[ $(printf '%s\n' "$need" "$DEB_TARGET_GLIBC" | sort -V | tail -n1) != "$DEB_TARGET_GLIBC" ]]; then
        echo "  $rel: needs GLIBC_$need, newer than $DEB_TARGET_GLIBC" >&2
        bad=1
    fi
done < <(find "$headers_dir" -type f -perm -u+x -print0)
[[ $bad == 0 ]] || die "host programs in $headers_pkg would not run on the target"

for pkg in "$image_pkg" "$headers_pkg"; do
    pdir=debian/$pkg
    echo "==> Packaging $pkg"
    install -Dm644 debian/copyright "$pdir/usr/share/doc/$pkg/copyright"
    mkdir -p "$pdir/DEBIAN"    # builddeb only creates it for the image
    chmod -R u+rwX,go=rX "$pdir"
    (
        cd "$pdir"
        find . -path ./DEBIAN -prune -o -type f -printf '%P\0' | LC_ALL=C sort -z |
            xargs -0r md5sum > DEBIAN/md5sums
    )
    chmod 644 "$pdir/DEBIAN/md5sums"
    dpkg-gencontrol -p"$pkg" -P"$pdir" -fdebian/files
    dpkg-deb --root-owner-group -Zxz --build "$pdir" .
done

echo "==> Done"
ls -l "${image_pkg}_$pkgver-${pkgrel}_amd64.deb" "${headers_pkg}_$pkgver-${pkgrel}_amd64.deb"
