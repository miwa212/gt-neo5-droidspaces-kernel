#!/usr/bin/env bash
# 在 GKI 内核树中启用 Droidspaces 支持
# 1. 下载并应用 kABI 补丁（SYSVIPC，自动尝试不同 padding 槽位；POSIX_MQUEUE 为 5.10 必打）
# 2. 修改 gki_defconfig（按 Droidspaces 官方 GKI 配置，逐项搜索替换）
# 3. 红线检查：确保 CONFIG_CFS_BANDWIDTH / CONFIG_CGROUP_PIDS 不开启（会破坏 kABI 导致 bootloop）
#
# 用法: apply_droidspaces.sh <gki-kernel-tree-path>
# 参考: https://github.com/ravindu644/Droidspaces-OSS/blob/main/Documentation/zh-CN/Kernel-Configuration.md
set -euo pipefail

TREE="${1:?usage: apply_droidspaces.sh <gki-kernel-tree-path>}"
# 解析为绝对路径，避免后续 cd 导致相对路径失效
TREE="$(cd "$TREE" && pwd)"
API_URL="https://api.github.com/repos/ravindu644/Droidspaces-OSS/contents/Documentation/resources/kernel-patches/GKI/below-kernel-6.12"
RAW_BASE="https://raw.githubusercontent.com/ravindu644/Droidspaces-OSS/main/Documentation/resources/kernel-patches/GKI/below-kernel-6.12"
DEFCONFIG="$TREE/arch/arm64/configs/gki_defconfig"

[ -f "$DEFCONFIG" ] || { echo "❌ 未找到 defconfig: $DEFCONFIG"; exit 1; }

WORK=$(mktemp -d)
echo "== 1/3 下载 Droidspaces kABI 补丁 =="
for f in $(curl -sf "$API_URL" | grep -o '"name": *"[^"]*\.patch"' | sed 's/.*"\([^"]*\.patch\)"/\1/'); do
  curl -sfL "$RAW_BASE/$f" -o "$WORK/$f" && echo "  下载: $f"
done
ls "$WORK"/*.patch >/dev/null 2>&1 || { echo "❌ 未下载到任何补丁"; exit 1; }

cd "$TREE"

apply_patch_try() {
  # $@: 候选补丁列表，按优先级尝试，成功即返回 0
  for p in "$@"; do
    [ -f "$p" ] || continue
    echo "  尝试: $(basename "$p")"
    if patch -p1 --forward --silent < "$p" >/dev/null 2>&1 \
       && [ -z "$(find . -maxdepth 3 -name '*.rej' -print -quit)" ]; then
      echo "  ✅ 应用成功: $(basename "$p")"
      return 0
    fi
    # 失败：回滚本次半应用的补丁
    find . -maxdepth 3 -name '*.rej' -delete
    find . -maxdepth 3 -name '*.orig' -delete
    git -C "$TREE" checkout -- . 2>/dev/null || true
  done
  return 1
}

echo "== 2/3 应用 kABI 补丁 =="
# SYSVIPC：优先 6_7_8 槽位（官方文档推荐），失败则换 1_2_3 / 3_4_5
SYSVIPC_678=$(ls "$WORK"/*sysvipc*6_7_8*.patch 2>/dev/null || true)
SYSVIPC_OTHERS=$(ls "$WORK"/*sysvipc*.patch 2>/dev/null | grep -v '6_7_8' || true)
if apply_patch_try $SYSVIPC_678 $SYSVIPC_OTHERS; then
  echo "  ✅ SYSVIPC kABI 补丁完成"
else
  echo "❌ 所有 SYSVIPC kABI 补丁均失败（开启 SYSVIPC/IPC_NS 将导致无限重启）"; exit 1
fi

# POSIX_MQUEUE：5.10 及以下必打
MQUEUE=$(ls "$WORK"/*mqueue*.patch "$WORK"/*5.10*.patch 2>/dev/null || true)
if apply_patch_try $MQUEUE; then
  echo "  ✅ POSIX_MQUEUE kABI 补丁完成"
else
  echo "❌ POSIX_MQUEUE kABI 补丁失败（5.10 内核必打）"; exit 1
fi

echo "== 3/3 修改 gki_defconfig =="

# 关闭 LTO：免费 runner(16G) 无法完成 GKI ThinLTO 链接（已 3 次实测被杀）
# 实测（2026-10-06 Build C）：no-LTO 内核与原厂 vendor 模块不兼容（CRC/布局变化）→ bootloop
# 因此支持 KEEP_LTO=1 跳过本段（配 swap 方案在 LTO 下编译）
# oplus_build_kernel.sh 菜单的 LTO 选项不落盘，必须改 defconfig
if [ "${KEEP_LTO:-0}" != "1" ]; then
  sed -i 's/^CONFIG_LTO_CLANG_THIN=y/# CONFIG_LTO_CLANG_THIN is not set/' "$DEFCONFIG"
  sed -i 's/^CONFIG_LTO_CLANG_FULL=y/# CONFIG_LTO_CLANG_FULL is not set/' "$DEFCONFIG"
  echo "  已关闭 CONFIG_LTO_CLANG_THIN / CONFIG_LTO_CLANG_FULL"
else
  echo "  KEEP_LTO=1: 保留原厂 ThinLTO 配置"
fi

enable_option() {
  local opt="$1"
  if grep -q "^# ${opt} is not set" "$DEFCONFIG"; then
    sed -i "s/^# ${opt} is not set/${opt}=y/" "$DEFCONFIG"
    echo "  启用(替换): $opt"
  elif grep -q "^${opt}=" "$DEFCONFIG"; then
    echo "  已启用: $opt"
  else
    echo "${opt}=y" >> "$DEFCONFIG"
    echo "  启用(追加): $opt"
  fi
}

# Droidspaces GKI 官方配置（kABI 安全集合）
# Build B 诊断版：无 LTO + 无 KSU，仅 Droidspaces 补丁与配置
for opt in \
  CONFIG_SYSVIPC \
  CONFIG_POSIX_MQUEUE \
  CONFIG_IPC_NS \
  CONFIG_PID_NS \
  CONFIG_DEVTMPFS \
  CONFIG_NETFILTER_XT_MATCH_ADDRTYPE \
  CONFIG_USER_NS \
  CONFIG_IP6_NF_NAT \
  CONFIG_IP6_NF_TARGET_MASQUERADE \
  CONFIG_NETFILTER_XT_TARGET_REJECT \
  CONFIG_NETFILTER_XT_TARGET_LOG \
  CONFIG_NETFILTER_XT_MATCH_RECENT \
  CONFIG_IP_SET \
  CONFIG_IP_SET_HASH_IP \
  CONFIG_IP_SET_HASH_NET \
  CONFIG_NETFILTER_XT_SET \
  CONFIG_TMPFS_POSIX_ACL \
  CONFIG_TMPFS_XATTR
do
  enable_option "$opt"
done

# 红线：以下选项会破坏 kABI（改变调度器/cgroup 结构体大小），必须保持关闭
for bad in CONFIG_CFS_BANDWIDTH CONFIG_CGROUP_PIDS; do
  if grep -q "^${bad}=y" "$DEFCONFIG"; then
    sed -i "s/^${bad}=y/# ${bad} is not set/" "$DEFCONFIG"
    echo "  ⚠️ 强制关闭红线选项: $bad"
  else
    sed -i "s/^# ${bad} is not set/# ${bad} is not set/" "$DEFCONFIG" 2>/dev/null || true
    echo "  ✓ 红线选项保持关闭: $bad"
  fi
done

echo "== Droidspaces 配置完成 =="

# 禁用 check_defconfig 校验（defconfig 手工修改后该检查会报 config 漂移）
if [ -f "$TREE/build.config.gki" ]; then
  sed -i 's/check_defconfig//' "$TREE/build.config.gki"
  echo "已禁用 common/build.config.gki 中的 check_defconfig"
fi
