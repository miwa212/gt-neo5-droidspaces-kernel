#!/usr/bin/env bash
# 在 GKI 内核树中启用 Droidspaces 支持
# 1. 下载并应用 kABI 补丁（SYSVIPC，自动尝试不同 padding 槽位；POSIX_MQUEUE 为 5.10 必打）
# 2. 修改 gki_defconfig（按 Droidspaces 官方 GKI 配置，逐项搜索替换）
# 3. 红线检查：确保 CONFIG_CFS_BANDWIDTH / CONFIG_CGROUP_PIDS 不开启（会破坏 kABI 导致 bootloop）
#
# 用法: apply_droidspaces.sh <gki-kernel-tree-path>
# 参考: https://github.com/ravindu644/Droidspaces-OSS/blob/main/Documentation/zh-CN/Kernel-Configuration.md
set -euo pipefail

TREE="${1:?usage: apply_droidspaces.sh <gki-kernel-tree-path> [CONFIG_A CONFIG_B ...]}"
# 可选第2参数: 空格分隔的 CONFIG 列表（二分诊断用），不传则使用完整 18 项
# 解析为绝对路径，避免后续 cd 导致相对路径失效
TREE="$(cd "$TREE" && pwd)"
API_URL="https://api.github.com/repos/ravindu644/Droidspaces-OSS/contents/Documentation/resources/kernel-patches/GKI/below-kernel-6.12"
RAW_BASE="https://raw.githubusercontent.com/ravindu644/Droidspaces-OSS/main/Documentation/resources/kernel-patches/GKI/below-kernel-6.12"
DEFCONFIG="$TREE/arch/arm64/configs/gki_defconfig"

[ -f "$DEFCONFIG" ] || { echo "❌ 未找到 defconfig: $DEFCONFIG"; exit 1; }

# 环境变量开关（二分诊断用）:
#   KEEP_LTO=1      保留原厂 ThinLTO（no-LTO 内核与 vendor 模块不兼容，已实锤）
#   SKIP_PATCHES=1  跳过 kABI 补丁（只改配置）
#   SKIP_CONFIG=1   跳过 defconfig 修改（只打补丁）

WORK=$(mktemp -d)
SKIP_PATCHES=${SKIP_PATCHES:-0}
SKIP_CONFIG=${SKIP_CONFIG:-0}

if [ "$SKIP_PATCHES" != "1" ]; then
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
# SYSVIPC：默认优先 6_7_8 槽位（官方文档推荐），失败则换 1_2_3 / 3_4_5
# 二分诊断可用 SYSVIPC_SLOTS=1_2_3 或 3_4_5 强制指定槽位
SYSVIPC_678=$(ls "$WORK"/*sysvipc*6_7_8*.patch 2>/dev/null || true)
SYSVIPC_123=$(ls "$WORK"/*sysvipc*1_2_3*.patch 2>/dev/null || true)
SYSVIPC_345=$(ls "$WORK"/*sysvipc*3_4_5*.patch 2>/dev/null || true)
SYSVIPC_OTHERS=$(ls "$WORK"/*sysvipc*.patch 2>/dev/null | grep -v -e '6_7_8' -e '1_2_3' -e '3_4_5' || true)
SYSVIPC_FAIL_MSG="❌ 所有 SYSVIPC kABI 补丁均失败（开启 SYSVIPC/IPC_NS 将导致无限重启）"
case "${SYSVIPC_SLOTS:-auto}" in
  1_2_3)
    echo "  强制槽位: 1_2_3"
    apply_patch_try $SYSVIPC_123 $SYSVIPC_OTHERS || { echo "$SYSVIPC_FAIL_MSG"; exit 1; }
    ;;
  3_4_5)
    echo "  强制槽位: 3_4_5"
    apply_patch_try $SYSVIPC_345 $SYSVIPC_OTHERS || { echo "$SYSVIPC_FAIL_MSG"; exit 1; }
    ;;
  *)
    apply_patch_try $SYSVIPC_678 $SYSVIPC_123 $SYSVIPC_345 $SYSVIPC_OTHERS || { echo "$SYSVIPC_FAIL_MSG"; exit 1; }
    ;;
esac
echo "  ✅ SYSVIPC kABI 补丁完成"

# POSIX_MQUEUE：5.10 及以下必打
MQUEUE=$(ls "$WORK"/*mqueue*.patch "$WORK"/*5.10*.patch 2>/dev/null || true)
if apply_patch_try $MQUEUE; then
  echo "  ✅ POSIX_MQUEUE kABI 补丁完成"
else
  echo "❌ POSIX_MQUEUE kABI 补丁失败（5.10 内核必打）"; exit 1
fi
else
  echo "== SKIP_PATCHES=1: 跳过 kABI 补丁 =="
fi

if [ "$SKIP_CONFIG" = "1" ]; then
  echo "== SKIP_CONFIG=1: 跳过 defconfig 修改 =="
  exit 0
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
# 支持第2参数传入配置子集（二分诊断）；不传则用完整列表
if [ $# -ge 2 ]; then
  echo "== 使用自定义配置子集（共 $(($# - 1)) 项）=="
  CONFIG_OPTS=("${@:2}")
else
  CONFIG_OPTS=(
    CONFIG_SYSVIPC
    CONFIG_POSIX_MQUEUE
    CONFIG_IPC_NS
    CONFIG_PID_NS
    CONFIG_DEVTMPFS
    CONFIG_NETFILTER_XT_MATCH_ADDRTYPE
    CONFIG_USER_NS
    CONFIG_IP6_NF_NAT
    CONFIG_IP6_NF_TARGET_MASQUERADE
    CONFIG_NETFILTER_XT_TARGET_REJECT
    CONFIG_NETFILTER_XT_TARGET_LOG
    CONFIG_NETFILTER_XT_MATCH_RECENT
    CONFIG_IP_SET
    CONFIG_IP_SET_HASH_IP
    CONFIG_IP_SET_HASH_NET
    CONFIG_NETFILTER_XT_SET
    CONFIG_TMPFS_POSIX_ACL
    CONFIG_TMPFS_XATTR
  )
fi

for opt in "${CONFIG_OPTS[@]}"; do
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

# BYPASS_MODVERSIONS=1: 内核侧跳过模块符号 CRC 校验
# 原理: SYSVIPC kABI padding 补丁已保证结构体布局不变, 但 genksyms CRC 仍会变化,
#       导致原厂 vendor 模块因 "disagrees about version of symbol" 拒绝加载 → bootloop。
#       此补丁使 kernel/module.c 的 check_version() 始终返回 1, 模块按符号名正常解析加载。
if [ "${BYPASS_MODVERSIONS:-0}" = "1" ]; then
  echo "== 附加: 绕过模块符号 CRC 校验 (BYPASS_MODVERSIONS=1) =="
  python3 - "$TREE/kernel/module.c" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
if "BYPASS_MODVERSIONS" in s:
    print("  已应用过，跳过")
    sys.exit(0)
key = "static int check_version(const struct load_info *info,"
i = s.find(key)
if i < 0:
    print("❌ 未找到 check_version() 函数"); sys.exit(1)
# C90 安全写法: 新增同名包装函数直接返回 1, 原函数改名并标记 __maybe_unused
wrapper = (
    "static int check_version(const struct load_info *info,\n"
    "\t\t\t const char *symname,\n"
    "\t\t\t struct module *mod,\n"
    "\t\t\t const s32 *crc)\n"
    "{\n"
    "\t/* BYPASS_MODVERSIONS: vendor module symbol CRC check bypass */\n"
    "\treturn 1;\n"
    "}\n\n"
)
s = s[:i] + wrapper + s[i:].replace(key, "static __maybe_unused int check_version_unused(", 1)
open(p, "w").write(s)
print("  ✅ check_version() 已包装为始终返回 1（跳过符号 CRC 校验, C90 安全）")
PYEOF
  [ $? -eq 0 ] || { echo "❌ CRC 绕过补丁失败"; exit 1; }
fi

echo "== Droidspaces 配置完成 =="

# 禁用 check_defconfig 校验（defconfig 手工修改后该检查会报 config 漂移）
if [ -f "$TREE/build.config.gki" ]; then
  sed -i 's/check_defconfig//' "$TREE/build.config.gki"
  echo "已禁用 common/build.config.gki 中的 check_defconfig"
fi
