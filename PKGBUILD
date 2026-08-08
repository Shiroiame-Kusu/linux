# Simplified PKGBUILD for pre-configured kernel source
# Original: CachyOS linux-cachyos
_pkgsuffix="cachyos-lfbmq-hakuu-tlto-expr"
pkgbase="linux-$_pkgsuffix"
_major=7.1
_minor=3
pkgver=${_major}.${_minor}
_stable=${_major}.${_minor}
_srcname=linux-${_stable}
pkgrel=4.1
pkgdesc='Linux CachyOS Kernel (pre-configured build) by Hakuu'
arch=('x86_64')
url="https://github.com/CachyOS/linux-cachyos"
license=('GPL-2.0-only')
_kernver="$pkgver-$pkgrel"
_kernuname="${pkgver}-${_pkgsuffix}"
makedepends=(
    bc
    cpio
    gettext
    libelf
    pahole
    perl
    python
    rust
    rust-bindgen
    rust-src
    tar
    xz
    zstd
    clang
    llvm
    lld
)

### Build nvidia open modules
: "${_build_nvidia_open:=no}"

_patchsource="https://raw.githubusercontent.com/cachyos/kernel-patches/master/${_major}"
_nv_ver=595.58.03
_nv_pkg="NVIDIA-Linux-x86_64-${_nv_ver}"
_nv_open_pkg="NVIDIA-kernel-module-source-${_nv_ver}"

source=()

if [ "$_build_nvidia_open" = "yes" ]; then
    source+=("https://download.nvidia.com/XFree86/${_nv_open_pkg%"-$_nv_ver"}/${_nv_open_pkg}.tar.xz"
             "${_patchsource}/misc/nvidia/0002-Add-IBT-support.patch"
             "${_patchsource}/misc/nvidia/0004-HACK-kernel-open-Makefile-Remove-PAHOLE_VARIABLE.patch"
             "${_patchsource}/misc/nvidia/0003-fix-dsc-correct-RC-parameter-tables-to-match-VESA-DS.patch"
             "${_patchsource}/misc/nvidia/0004-fix-dsc-use-bits_per_component-for-flatnessDetThresh.patch"
             "${_patchsource}/misc/nvidia/0005-fix-dp-add-Bigscreen-Beyond-VR-headset-to-WAR-databa.patch")
fi

b2sums=()

export KBUILD_BUILD_HOST=cachyos
export KBUILD_BUILD_USER="$pkgbase"
export KBUILD_BUILD_TIMESTAMP="$(date -Ru${SOURCE_DATE_EPOCH:+d @$SOURCE_DATE_EPOCH})"

BUILD_FLAGS=(
    CC=clang
    LD=ld.lld
    LLVM=1
    LLVM_IAS=1
)

prepare() {
    cd "$srcdir/../"

    # Apply nvidia patches
    if [ "$_build_nvidia_open" = "yes" ]; then
        local src
        for patch in "${source[@]}"; do
            patch="${patch%%::*}"
            src="${patch##*/}"
            src="${src%.zst}"
            [[ $src = *.patch ]] || continue
            echo "Applying patch $src..."
            if [[ "$patch" == "${_patchsource}"/misc/nvidia/* ]]; then
                patch -Np1 < "${srcdir}/$src" -d "${srcdir}/${_nv_open_pkg}"
            else
                patch -Np1 < "${srcdir}/$src"
            fi
        done
    fi

    echo "Setting version..."
    echo "-$pkgrel" > localversion.10-pkgrel
    echo "${pkgbase#linux}" > localversion.20-pkgname

    echo "Preparing build..."
    cp config .config
    make "${BUILD_FLAGS[@]}" prepare

    make -s kernelrelease > version
    echo "Prepared $pkgbase version $(<version)"
}

build() {
    cd "$srcdir/../"

    echo "Building kernel..."
    cp config .config
    make "${BUILD_FLAGS[@]}" -j"$(($(nproc) - 2))" all

    echo "Building bpftool vmlinux.h..."
    make -C tools/bpf/bpftool vmlinux.h feature-clang-bpf-co-re=1

    local MODULE_FLAGS=(
        KERNEL_UNAME="${_kernuname}"
        IGNORE_PREEMPT_RT_PRESENCE=1
        SYSSRC="${srcdir}/../"
        SYSOUT="${srcdir}/../"
    )

    if [ "$_build_nvidia_open" = "yes" ]; then
        cd "${srcdir}/${_nv_open_pkg}"
        MODULE_FLAGS+=(IGNORE_CC_MISMATCH=yes)
        CFLAGS= CXXFLAGS= LDFLAGS= make "${BUILD_FLAGS[@]}" "${MODULE_FLAGS[@]}" -j"$(($(nproc) - 2))" modules
    fi
}

_package() {
    pkgdesc="The $pkgdesc kernel and modules"
    depends=('coreutils' 'kmod' 'initramfs')
    optdepends=(
        'wireless-regdb: to set the correct wireless channels of your country'
        'linux-firmware: firmware images needed for some devices'
    )
    provides=(VIRTUALBOX-GUEST-MODULES WIREGUARD-MODULE KSMBD-MODULE V4L2LOOPBACK-MODULE NTSYNC-MODULE VHBA-MODULE ADIOS-MODULE)

    cd "$srcdir/../"

    local modulesdir="$pkgdir/usr/lib/modules/$(<version)"

    echo "Installing boot image..."
    install -Dm644 "$(make -s image_name)" "$modulesdir/vmlinuz"

    echo "$pkgbase" | install -Dm644 /dev/stdin "$modulesdir/pkgbase"

    echo "Installing modules..."
    ZSTD_CLEVEL=19 make "${BUILD_FLAGS[@]}" INSTALL_MOD_PATH="$pkgdir/usr" INSTALL_MOD_STRIP=1 \
        DEPMOD=/doesnt/exist modules_install

    rm "$modulesdir"/build
}

_package-headers() {
    pkgdesc="Headers and scripts for building modules for the $pkgdesc kernel"
    depends=('pahole' "${pkgbase}" 'clang' 'llvm' 'lld')

    cd "$srcdir/../"
    local builddir="$pkgdir/usr/lib/modules/$(<version)/build"

    echo "Installing build files..."
    install -Dt "$builddir" -m644 .config Makefile Module.symvers System.map \
        localversion.* version vmlinux

    install -Dt "$builddir" -m644 tools/bpf/bpftool/vmlinux.h
    install -Dt "$builddir/kernel" -m644 kernel/Makefile
    install -Dt "$builddir/arch/x86" -m644 arch/x86/Makefile
    cp -t "$builddir" -a scripts
    ln -srt "$builddir" "$builddir/scripts/gdb/vmlinux-gdb.py"

    install -Dt "$builddir/tools/objtool" tools/objtool/objtool

    if [ -f tools/bpf/resolve_btfids/resolve_btfids ]; then
        install -Dt "$builddir/tools/bpf/resolve_btfids" tools/bpf/resolve_btfids/resolve_btfids
    fi

    echo "Installing headers..."
    cp -t "$builddir" -a include
    cp -t "$builddir/arch/x86" -a arch/x86/include
    install -Dt "$builddir/arch/x86/kernel" -m644 arch/x86/kernel/asm-offsets.s

    install -Dt "$builddir/drivers/md" -m644 drivers/md/*.h
    install -Dt "$builddir/net/mac80211" -m644 net/mac80211/*.h
    install -Dt "$builddir/drivers/media/i2c" -m644 drivers/media/i2c/msp3400-driver.h
    install -Dt "$builddir/drivers/media/usb/dvb-usb" -m644 drivers/media/usb/dvb-usb/*.h
    install -Dt "$builddir/drivers/media/dvb-frontends" -m644 drivers/media/dvb-frontends/*.h
    install -Dt "$builddir/drivers/media/tuners" -m644 drivers/media/tuners/*.h
    install -Dt "$builddir/drivers/iio/common/hid-sensors" -m644 drivers/iio/common/hid-sensors/*.h

    echo "Installing KConfig files..."
    find . -name 'Kconfig*' -exec install -Dm644 {} "$builddir/{}" \;

    if compgen -G "rust/*.rmeta" 1>/dev/null; then
        install -Dt "$builddir/rust" -m644 rust/*.rmeta
    fi
    if compgen -G "rust/*.so" 1>/dev/null; then
        install -Dt "$builddir/rust" rust/*.so
    fi

    echo "Installing unstripped VDSO..."
    make INSTALL_MOD_PATH="$pkgdir/usr" vdso_install link=

    echo "Removing unneeded architectures..."
    local arch
    for arch in "$builddir"/arch/*/; do
        [[ $arch = */x86/ ]] && continue
        echo "Removing $(basename "$arch")"
        rm -r "$arch"
    done

    echo "Removing documentation..."
    rm -r "$builddir/Documentation"

    echo "Removing broken symlinks..."
    find -L "$builddir" -type l -printf 'Removing %P\n' -delete

    echo "Removing loose objects..."
    find "$builddir" -type f -name '*.o' -printf 'Removing %P\n' -delete

    echo "Stripping build tools..."
    local file
    while read -rd '' file; do
        case "$(file -Sib "$file")" in
            application/x-sharedlib\;*)      strip -v $STRIP_SHARED "$file" ;;
            application/x-archive\;*)        strip -v $STRIP_STATIC "$file" ;;
            application/x-executable\;*)     strip -v $STRIP_BINARIES "$file" ;;
            application/x-pie-executable\;*) strip -v $STRIP_SHARED "$file" ;;
        esac
    done < <(find "$builddir" -type f -perm -u+x ! -name vmlinux -print0)

    echo "Stripping vmlinux..."
    strip -v $STRIP_STATIC "$builddir/vmlinux"

    echo "Adding symlink..."
    mkdir -p "$pkgdir/usr/src"
    ln -sr "$builddir" "$pkgdir/usr/src/$pkgbase"
}

_package-nvidia-open(){
    pkgdesc="nvidia open modules of ${_nv_ver} driver for the ${pkgbase} kernel"
    depends=("$pkgbase=$_kernver" "nvidia-utils=${_nv_ver}" "libglvnd")
    provides=('NVIDIA-MODULE')
    conflicts=("$pkgbase-nvidia")
    license=('MIT AND GPL-2.0-only')

    cd "$srcdir/../"
    local modulesdir="$pkgdir/usr/lib/modules/$(<version)/extramodules"

    cd "${srcdir}/${_nv_open_pkg}"
    install -dm755 "${modulesdir}"
    install -m644 kernel-open/*.ko "${modulesdir}"
    install -Dt "$pkgdir/usr/share/licenses/${pkgname}" -m644 COPYING
}

pkgname=("$pkgbase" "$pkgbase-headers")
[ "$_build_nvidia_open" = "yes" ] && pkgname+=("$pkgbase-nvidia-open")

for _p in "${pkgname[@]}"; do
    eval "package_$_p() {
    $(declare -f "_package${_p#$pkgbase}")
    _package${_p#$pkgbase}
    }"
done
