#!/usr/bin/env bash
# build-kernel-local.sh
# 本地内核构建（native build, 不指定 ISA）

set -euo pipefail
IFS=$'\n\t'
trap 'last_cmd="$BASH_COMMAND"; echo "ERROR on line ${LINENO}: ${last_cmd}" >&2' ERR

# ------------------ 可被环境覆盖的默认变量 ------------------
export CC=clang
export LD=ld.lld
export LLVM=1
BLEEDING_EDGE=1
if [[ ${BLEEDING_EDGE} -eq 1 ]]; then
  echo "BLEEDING_EDGE is 1, using no profiles"
else
  export CLANG_AUTOFDO_PROFILE=kernel.afdo
  export CLANG_PROPELLER_PROFILE_PREFIX=kernel
fi
NEED_APT_UPDATE=0

ensure_xanmod_repo() {
  # 使用 /usr/share/keyrings 以保持和官方文档兼容；若不存在则创建
  local keyring_path="/usr/share/keyrings/xanmod-archive-keyring.gpg"
  local repo_entry="deb [signed-by=${keyring_path}] http://deb.xanmod.org releases main"
  local repo_file="/etc/apt/sources.list.d/xanmod-toolchain.list"

  if [[ ! -f "$repo_file" ]] || ! grep -Fxq "$repo_entry" "$repo_file" 2>/dev/null; then
    echo "Configuring XanMod APT repository at http://deb.xanmod.org"
    sudo install -d -m 755 /usr/share/keyrings
    sudo install -d -m 755 /etc/apt/sources.list.d
    if [[ ! -f "$keyring_path" ]]; then
      echo "Fetching XanMod GPG key"
      wget -qO - "https://dl.xanmod.org/gpg.key" | sudo gpg --dearmor -vo "$keyring_path"
      sudo chmod 644 "$keyring_path"
    fi
    printf '%s\n' "$repo_entry" | sudo tee "$repo_file" >/dev/null
    NEED_APT_UPDATE=1
  fi
}

ensure_llvm_toolchain() {
  echo "Ensuring required LLVM toolchain components are installed"

  local apt_updated=0
  local -a pre_repo_packages=()
  if ! command -v gpg >/dev/null 2>&1; then
    pre_repo_packages+=(gnupg)
  fi

  if [[ ${#pre_repo_packages[@]} -gt 0 ]]; then
    echo "Installing prerequisite packages: ${pre_repo_packages[*]}"
    sudo apt update
    apt_updated=1
    sudo apt install -y "${pre_repo_packages[@]}"
  fi

  declare -A cmd_pkg_map=(
    [clang]=clang
    [ld.lld]=lld
    [llvm-ar]=llvm
  )

  local -a packages=()
  for cmd in "${!cmd_pkg_map[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Missing required command: $cmd (package ${cmd_pkg_map[$cmd]})"
      packages+=("${cmd_pkg_map[$cmd]}")
    fi
  done

  if [[ ${#packages[@]} -eq 0 ]]; then
    return
  fi

  ensure_xanmod_repo

  local -A seen_packages=()
  local -a unique_packages=()
  for pkg in "${packages[@]}"; do
    if [[ -z ${seen_packages[$pkg]:-} ]]; then
      unique_packages+=("$pkg")
      seen_packages[$pkg]=1
    fi
  done

  if [[ ${NEED_APT_UPDATE} -eq 1 ]]; then
    sudo apt update
    NEED_APT_UPDATE=0
    apt_updated=1
  fi

  if [[ $apt_updated -eq 0 ]]; then
    sudo apt update
    apt_updated=1
  fi

  echo "Installing missing packages from http://deb.xanmod.org: ${unique_packages[*]}"
  sudo apt install -y "${unique_packages[@]}"
}
# 基础构建依赖（若已安装则 apt 会跳过）
#sudo apt update
sudo apt install -y wget curl git build-essential flex bison libncurses-dev libssl-dev libelf-dev bc dwarves xz-utils tar lz4

ensure_llvm_toolchain

DEBFULLNAME="${DEBFULLNAME:-Alexandre Frade}"
DEBEMAIL="${DEBEMAIL:-kernel@xanmod.org}"
KDEB_CHANGELOG_DIST="${KDEB_CHANGELOG_DIST:-bookworm}"
KCONFIG_CONFIG="${KCONFIG_CONFIG:-.config}"
jv="${jv:-$(($(nproc) * 2))}"
gv="${gv:-$(git rev-parse --short=7 HEAD 2>/dev/null || echo nogit)}"
dv="${dv:-$(git show -s --date=format:'%Y%m%d' --format=%cd 2>/dev/null || date +%Y%m%d)}"
lv="${lv:-$(make -s kernelversion 2>/dev/null || echo unknown)}"
xv="${xv:-$(cat localversion 2>/dev/null || echo)}"
rv="${rv:-0}"
CI_ASSETS="${CI_ASSETS:-}"
BMQ_ENABLED="${BMQ_ENABLED:-1}"
# ------------------ 必需命令检查 ------------------
require_cmds=(wget tar make git xz clang ld.lld llvm-ar)
for cmd in "${require_cmds[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command not found: $cmd" >&2
    exit 2
  fi
done

# ------------------ 下载资产 (可选) ------------------
if [[ ${BLEEDING_EDGE} -eq 0 ]]; then
  echo "Downloading/refreshing llvm profiles: https://dl.xanmod.org/llvm_profiles/x86_64/latest.tar.xz"
  wget -O - "https://dl.xanmod.org/llvm_profiles/x86_64/latest.tar.xz" | tar xvJ
fi

echo "Parallel jobs (jv) = ${jv}"

# ------------------ 构建函数 ------------------
build_native() {
  echo "==================== Native Build ===================="
#  isa=3
#  echo "Setting LOCALVERSION -> -x64v${isa} and X86_64_VERSION -> ${isa} in ${KCONFIG_CONFIG}"
#  scripts/config --file "$KCONFIG_CONFIG" --set-str LOCALVERSION -x64v"${isa}" --set-val X86_64_VERSION "${isa}"
#  make -j"${jv}" KDEB_PKGVERSION="${pkg_version}" bindeb-pkg
#  if [[ "${BMQ_ENABLED}" -eq 1 ]]; then
#    echo "BMQ_ENABLED is set to 1, enabling BMQ Scheduler features"
#    cp config-bmq .config
#  else
#    echo "BMQ_ENABLED is not set or is 0, proceeding without BMQ Scheduler features"
    cp config .config
#  fi
  if [[ ! -f "$KCONFIG_CONFIG" ]]; then
    echo "Kconfig file not found: $KCONFIG_CONFIG" >&2
    return 1
  fi

  # 提取 LOCALVERSION（pv），若未找到则留空
  pv="$(sed -n 's/.*LOCALVERSION.*"\([^"]*\)".*/\1/p' "$KCONFIG_CONFIG" | head -n1 || true)"
  echo "LOCALVERSION string (pv) = ${pv}"

  # 重新探测版本号信息
  lv="$(make -s kernelversion)"
  gv="$(git rev-parse --short=7 HEAD 2>/dev/null || echo nogit)"
  dv="$(git show -s --date=format:'%Y%m%d' --format=%cd 2>/dev/null || date +%Y%m%d)"
  xv="$(cat localversion 2>/dev/null || echo)"

  pkg_version="${lv}${pv}${xv}"
  echo $pkg_version
  logfile="../build-${pkg_version}_amd64.log"

  echo "Computed package version: ${pkg_version}"
  echo "Log will be written to: ${logfile}"

  # 执行构建
  echo "Running make bindeb-pkg (this may take a long time)"

  set +o pipefail
  yes "" | make -j"${jv}" KDEB_PKGVERSION="${pkg_version}" V=0 bindeb-pkg 2>&1 | tee "${logfile}"
  set -o pipefail
  # 压缩产物并移动到 assets/
  pattern="${pv:-${lv}}"
  mkdir -p assets
  echo "Artifact pattern base: ${pattern}"
  # 仅压缩非 .deb 与尚未压缩的文件，避免对 .deb 再次 xz 造成混淆
  mapfile -t candidate_files < <(find ../ -maxdepth 1 -type f -iname "*${pattern}*" ! -iname "*.deb" ! -iname "*.xz" 2>/dev/null || true)
  if [[ ${#candidate_files[@]} -gt 0 ]]; then
    echo "Compressing ${#candidate_files[@]} non-deb artifacts with xz -e9"
    xz -e9 "${candidate_files[@]}" || echo "Compression step encountered issues (continuing)"
  else
    echo "No extra non-deb artifacts to compress"
  fi
  echo "Moving artifacts into ./assets/"
  set +e
  # 按 pattern 移动
  if [[ -n "$pattern" ]]; then
    mv ../*"${pattern}"* assets/ 2>/dev/null || true
  fi
  # 移动全部 .deb
  for debfile in ../*.deb; do
    [[ -f "$debfile" ]] || continue
    mv -n "$debfile" assets/ 2>/dev/null || true
  done
  # 移动日志
  mv "$logfile" assets/ 2>/dev/null || true
  set -e

  echo "Native build finished. Artifacts (if any) are in ./assets/"
}

# ------------------ 主流程 ------------------
build_native

echo "Build process complete. Check assets/ and ../build-*.log for details."
echo "Done."
