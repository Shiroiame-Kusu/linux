#!/usr/bin/env bash
# build-kernel-local.sh
# Local kernel build (deb package) - for Arch Linux

set -euo pipefail
IFS=$'\n\t'
trap 'last_cmd="$BASH_COMMAND"; echo "ERROR on line ${LINENO}: ${last_cmd}" >&2' ERR

# ------------------ Color Output ------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }

# ------------------ Default Variables (can be overridden by environment) ------------------
export CC="${CC:-clang}"
export LD="${LD:-ld.lld}"
export LLVM="${LLVM:-1}"
export LLVM_IAS="${LLVM_IAS:-1}"

# deb package related
export DEBFULLNAME="${DEBFULLNAME:-Shiroame Kusu}"
export DEBEMAIL="${DEBEMAIL:-kusu@kusu.moe}"
export KDEB_CHANGELOG_DIST="${KDEB_CHANGELOG_DIST:-bookworm}"
# Use xz compression for deb packages (dpkg-deb defaults to zstd which may not be available everywhere)
export KDEB_COMPRESS="${KDEB_COMPRESS:-gzip}"

# Skip dpkg-checkbuilddeps on non-Debian systems (Arch Linux)
# This prevents errors about missing Debian package names
export DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS:-} nocheck"
export DEB_RULES_REQUIRES_ROOT="no"

# Build configuration
KCONFIG_CONFIG="${KCONFIG_CONFIG:-.config}"
CONFIG_FILE="${CONFIG_FILE:-config}"
jv="${jv:-$(($(nproc) - 2))}"
gv="${gv:-$(git rev-parse --short=7 HEAD 2>/dev/null || echo nogit)}"
dv="${dv:-$(git show -s --date=format:'%Y%m%d' --format=%cd 2>/dev/null || date +%Y%m%d)}"
lv="${lv:-$(make -s kernelversion 2>/dev/null || echo unknown)}"
xv="${xv:-$(cat localversion 2>/dev/null || echo)}"
rv="${rv:-0}"
CI_ASSETS="${CI_ASSETS:-}"

# ------------------ Required Commands Check ------------------
info "Checking required build tools..."

# Basic build tools
require_cmds=(make git tar xz zstd)
# LLVM toolchain
llvm_cmds=(clang ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-readelf llvm-strip)
# deb packaging tools
deb_cmds=(dpkg dpkg-deb fakeroot)

missing_cmds=()

for cmd in "${require_cmds[@]}" "${llvm_cmds[@]}" "${deb_cmds[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing_cmds+=("$cmd")
  fi
done

if [[ ${#missing_cmds[@]} -gt 0 ]]; then
  error "Missing commands: ${missing_cmds[*]}"
  echo ""
  warn "On Arch Linux, install dependencies with:"
  echo "  sudo pacman -S clang llvm lld base-devel bc cpio libelf pahole perl python tar xz zstd git rsync flex bison openssl kmod"
  echo "  yay -S dpkg debhelper"
  exit 2
fi

success "All required tools are ready"

# ------------------ Config File Check ------------------
info "Preparing kernel configuration..."

if [[ ! -f "$CONFIG_FILE" ]]; then
  error "Config file not found: $CONFIG_FILE"
  echo "Available config files:"
  ls -la config* 2>/dev/null || echo "  (none)"
  exit 1
fi

info "Parallel jobs (jv) = ${jv}"
info "Using config file: ${CONFIG_FILE}"

# ------------------ Build Function ------------------
build_native() {
  echo ""
  echo "========================================================"
  echo "             Native Kernel Build (deb)"
  echo "========================================================"
  echo ""

  # Copy config file
  info "Copying config file to .config"
  cp "${CONFIG_FILE}" .config

  if [[ ! -f "$KCONFIG_CONFIG" ]]; then
    error "Kconfig file not found: $KCONFIG_CONFIG"
    return 1
  fi

  # Extract LOCALVERSION (pv), leave empty if not found
  pv="$(sed -n 's/.*LOCALVERSION.*"\([^"]*\)".*/\1/p' "$KCONFIG_CONFIG" | head -n1 || true)"
  info "LOCALVERSION string (pv) = ${pv}"

  # Re-detect version info
  lv="$(make -s kernelversion)"
  gv="$(git rev-parse --short=7 HEAD 2>/dev/null || echo nogit)"
  dv="$(git show -s --date=format:'%Y%m%d' --format=%cd 2>/dev/null || date +%Y%m%d)"
  xv="$(cat localversion 2>/dev/null || echo)"

  pkg_version="${lv}${xv}-${gv}"
  logfile="../build-${pkg_version}_amd64.log"

  info "Kernel version: ${lv}"
  info "Git commit: ${gv}"
  info "Build date: ${dv}"
  info "Full package version: ${pkg_version}"
  info "Log file: ${logfile}"

  echo ""
  info "Running pre-build preparation..."
  
  # Build options
  BUILD_OPTS=(
    "CC=${CC}"
    "LD=${LD}"
    "LLVM=${LLVM}"
    "LLVM_IAS=${LLVM_IAS}"
    "KDEB_PKGVERSION=${pkg_version}"
    "KDEB_COMPRESS=${KDEB_COMPRESS}"
  )



  # Display build configuration
  echo ""
  info "Build configuration:"
  for opt in "${BUILD_OPTS[@]}"; do
    echo "    ${opt}"
  done
  echo ""

  # Patch debian/control to remove Debian-specific build dependencies
  # This is needed because dpkg-checkbuilddeps checks for Debian package names
  # which don't exist on Arch Linux
  if [[ -f "debian/control" ]]; then
    info "Patching debian/control to remove Debian-specific dependencies..."
    sed -i 's/^Build-Depends:.*/Build-Depends:/' debian/control
    sed -i '/^Build-Depends-Arch:/,/^[^ ]/{ /^Build-Depends-Arch:/!{ /^[^ ]/!d }; s/^Build-Depends-Arch:.*/Build-Depends-Arch:/ }' debian/control
  fi

  # Create debian/compat file for debhelper compatibility level
  # This fixes: "Compatibility levels before 7 are no longer supported"
  info "Setting debhelper compatibility level to 12..."
  echo "12" > debian/compat

  # Also patch scripts/package/mkdebian if it exists to prevent regeneration
  if [[ -f "scripts/package/mkdebian" ]]; then
    info "Patching scripts/package/mkdebian to skip Debian-specific dependencies..."
    # Backup original if not already backed up
    if [[ ! -f "scripts/package/mkdebian.orig" ]]; then
      cp scripts/package/mkdebian scripts/package/mkdebian.orig
    fi
    # Remove build dependencies from the generated control file
    sed -i 's/Build-Depends: .*/Build-Depends:/' scripts/package/mkdebian
    sed -i '/Build-Depends-Arch:/,/^[A-Z]/{ s/Build-Depends-Arch:.*/Build-Depends-Arch:/; /^ /d }' scripts/package/mkdebian
    
    # Add debian/compat file creation to mkdebian script (after mkdir debian)
    # This ensures the compat file is created when debian/ is regenerated
    if ! grep -q 'debian/compat' scripts/package/mkdebian; then
      # Find the line number of "mkdir debian" and insert after it
      local mkdir_line
      mkdir_line=$(grep -n "^mkdir debian$" scripts/package/mkdebian | cut -d: -f1)
      if [[ -n "$mkdir_line" ]]; then
        sed -i "${mkdir_line}a echo \"12\" > debian/compat" scripts/package/mkdebian
      fi
    fi
  fi

  # Execute build
  echo ""
  info "Starting kernel compilation and deb package generation (make bindeb-pkg)..."
  info "This may take a long time, please be patient..."
  echo ""

  local build_start
  build_start=$(date +%s)

  set +o pipefail
  yes "" | make -j"${jv}" "${BUILD_OPTS[@]}" V=0 bindeb-pkg 2>&1 | tee "${logfile}"
  local build_status=${PIPESTATUS[1]}
  set -o pipefail

  local build_end
  build_end=$(date +%s)
  local build_time=$((build_end - build_start))
  local build_min=$((build_time / 60))
  local build_sec=$((build_time % 60))

  echo ""
  if [[ $build_status -eq 0 ]]; then
    success "Build completed! Time elapsed: ${build_min}m${build_sec}s"
  else
    error "Build failed! Check log: ${logfile}"
    return 1
  fi

  # Process artifacts
  echo ""
  info "Processing build artifacts..."
  
  pattern="${pv:-${lv}}"
  mkdir -p assets
  
  info "Artifact pattern: ${pattern}"
  
  # Count generated deb packages
  local deb_count=0
  echo ""
  info "Generated deb packages:"
  for debfile in ../*.deb; do
    if [[ -f "$debfile" ]]; then
      deb_count=$((deb_count + 1))
      local deb_name
      deb_name=$(basename "$debfile")
      local deb_size
      deb_size=$(du -h "$debfile" | cut -f1)
      echo "    ${deb_name} (${deb_size})"
    fi
  done

  if [[ $deb_count -eq 0 ]]; then
    warn "No deb packages found"
  fi

  # Compress non-deb artifacts
  mapfile -t candidate_files < <(find ../ -maxdepth 1 -type f -iname "*${pattern}*" ! -iname "*.deb" ! -iname "*.xz" ! -iname "*.zst" 2>/dev/null || true)
  if [[ ${#candidate_files[@]} -gt 0 ]]; then
    info "Compressing ${#candidate_files[@]} non-deb artifacts with xz -e9..."
    xz -e9 "${candidate_files[@]}" || warn "Compression encountered issues"
  fi

  # Move artifacts to assets/
  info "Moving artifacts to ./assets/"
  set +e
  
  if [[ -n "$pattern" ]]; then
    mv ../*"${pattern}"* assets/ 2>/dev/null || true
  fi
  
  for debfile in ../*.deb; do
    [[ -f "$debfile" ]] || continue
    mv -n "$debfile" assets/ 2>/dev/null || true
  done
  
  mv "$logfile" assets/ 2>/dev/null || true
  set -e

  # Display final artifacts
  echo ""
  success "Build complete! Artifacts are in ./assets/"
  echo ""
  info "Artifact list:"
  ls -lh assets/*.deb 2>/dev/null || echo "    (no deb packages)"
  echo ""
  
  # Display installation instructions
  info "To install on Debian/Ubuntu:"
  echo "    sudo dpkg -i assets/linux-image-*.deb assets/linux-headers-*.deb"
  echo ""
  info "To install on Arch Linux (using debtap):"
  echo "    yay -S debtap"
  echo "    sudo debtap -u"
  echo "    debtap assets/linux-image-*.deb"
  echo "    sudo pacman -U linux-image-*.pkg.tar.zst"
}

# ------------------ Main Flow ------------------
echo ""
echo "========================================================"
echo "   Linux Kernel Build Script for Arch Linux -> deb"
echo "========================================================"
echo ""
info "Maintainer: ${DEBFULLNAME} <${DEBEMAIL}>"
info "Target distribution: ${KDEB_CHANGELOG_DIST}"
echo ""

build_native

echo ""
success "Build process complete!"
info "Check assets/ directory for generated deb packages"
info "Build log: assets/build-*.log"
echo ""