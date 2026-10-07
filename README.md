# senna Droidspaces 内核（realme GT Neo5 240W / RMX3708）

为 realme GT Neo5 240W（RMX3708，社区代号 senna）编译支持 [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS)（安卓容器方案）的自定义 GKI 内核。

- **设备**: realme GT Neo5 240W / RMX3708 / GT Neo5 / GT3（senna，骁龙 8+ Gen 1 / SM8475）
- **系统**: ColorOS 15 / Android 15，内核 5.10.226-android12-9（GKI，KMI 9）
- **源码**: realme AndroidU 官方内核（经 `Quantom2/gt_neo5_kernel_manifest` 同步 kernel_platform）
- **当前推荐版本**: [`senna-mq4_lto`](../../releases)（POSIX_MQUEUE + IPC_NS + PID_NS + DEVTMPFS_MOUNT + USER_NS，无 SYSVIPC，已在真机验证可正常启动）

## ✅ 实测结论（二分法真机验证，2026-10）

realme 原厂 GKI 内核 **SYSVIPC / POSIX_MQUEUE / IPC_NS / PID_NS 全部默认关闭**。开启它们与闭源 vendor 模块（512 个）存在硬性兼容冲突。以下是 7 个构建变体逐一真机测试的结果：

| 变体 | 配置 | 结果 |
|------|------|------|
| cfgK1_lto | SYSVIPC + MQUEUE | ❌ bootloop |
| cfgK3_lto | 仅 SYSVIPC | ❌ bootloop |
| cfgK5_lto | SYSVIPC(槽位3_4_5) + MQUEUE + IPC_NS | ❌ bootloop |
| modv_lto | 全配置 + 关闭 MODVERSIONS | ❌ bootloop（vermagic 不匹配，此路不通） |
| cfgK2_lto / modv2_lto | 无 MQUEUE/SYSVIPC（modv2 含其余 16 项） | ✅ 启动，但 **IPC_NS 被 Kconfig 静默丢弃** |
| **mq_lto** ⭐ | **POSIX_MQUEUE + IPC_NS**（无 SYSVIPC） | ✅ **启动，IPC_NS/MQUEUE 实测生效** |
| mq2_lto | mq_lto + PID_NS | ❌ bootloop（原因存疑，见 mq4） |
| **mq4_lto** ⭐⭐ | **MQUEUE + IPC_NS + DEVTMPFS_MOUNT + USER_NS + PID_NS**（无 SYSVIPC） | ✅ **启动，/proc/config.gz 实测全部生效** |

**关键发现：**

1. **`CONFIG_SYSVIPC` 是砖因**——其结构体改动无法用 kABI 槽位补丁保住符号 CRC，vendor 模块加载即崩。**无解**，除非同源重建全部 vendor 模块并同刷 vendor_boot / vendor_dlkm / system_dlkm。
2. **`IPC_NS depends on (SYSVIPC || POSIX_MQUEUE)`**（5.10 Kconfig）。只开 IPC_NS 会被静默丢弃——这就是 cfgK2 "能开机" 的真正原因（等于没改配置）。
3. **POSIX_MQUEUE 的 kABI 填充补丁有效**，单独开启不会破坏 CRC；MQUEUE 与 PID_NS 同开并不必然冲突（mq4_lto 实测可开机），mq2_lto 的失败另有原因（疑似缺 DEVTMPFS_MOUNT 时 PID_NS 环境下 devtmpfs 初始化问题），确切根因待查。
4. **关闭 `CONFIG_MODVERSIONS` 是死路**：原厂模块 vermagic 带 `modversions` 标志，直接拒载。
5. ⚠️ **`fastboot flash boot` 直刷任何非原厂 boot.img 都会导致无法开机**（CI 打包的 boot.img 不含 realme 原厂 ramdisk）。**只能用 AnyKernel3 方式刷入**（只替换内核 Image，保留原厂 ramdisk/dtb）。

## 推荐版本：mq_lto

Droidspaces 官方 `check` 结果（mq_lto 真机实测）：

```
[MUST HAVE]
  [✓] Root privileges / Linux version / Mount namespace
  [✓] UTS namespace / IPC namespace
  [✓] pivot_root / /proc / /sys / Seccomp
  [✗] PID namespace      ← oplus GKI 默认关闭，开启后与 MQUEUE 冲突（见 mq2_lto）
[RECOMMENDED]
  [✓] epoll / signalfd / PTY / devpts / Loop / ext4 / Cgroup v2 / Cgroup namespace
  [✗] devtmpfs（tmpfs fallback 可用）
[OPTIONAL]
  [✓] IPv6 / FUSE / TUN-TAP / OverlayFS / Network ns / Bridge / Veth
```

缺 SYSVIPC 对现代发行版影响很小（systemd/Alpine 默认几乎不依赖）；缺 PID_NS 时容器与宿主共享进程号空间，Droidspaces 仍可运行。PID namespace 若需开启，需自行实验 MQUEUE/PID_NS 补丁的兼容组合（mq2_lto 失败供参考）。

## 构建方式

GitHub Actions 云端构建：进入 **Actions → Build senna Droidspaces GKI kernel → Run workflow**，选择 variant。产物：AnyKernel3 刷入包 + Image + boot.img（Artifact 或 Release）。

构建流程：
1. `repo sync` 拉取 realme kernel_platform（含内置 clang 工具链）
2. 应用 Droidspaces kABI 补丁（`scripts/apply_droidspaces.sh`，SYSVIPC 槽位自动尝试 + POSIX_MQUEUE 5.10 必打）
3. 修改 `common/arch/arm64/configs/gki_defconfig`（kABI 安全配置集合）
4. `oplus_build_kernel.sh wapio gki thin all disable` 编译（ThinLTO）
5. WildPlusKernel/AnyKernel3（gki-2.0）打包

### variant 说明

| variant | 用途 |
|---------|------|
| `mq_lto` | **推荐**：MQUEUE + IPC_NS |
| `modv2_lto` | 保守版：无 MQUEUE/SYSVIPC，其余 16 项 |
| `stock_lto` | 基准对照：原厂配置 + ThinLTO |
| `cfgK1-K5_lto` / `modv_lto` / `mq2_lto` | 实验用（见上表） |

## 刷入（务必用 AnyKernel3 方式）

1. **刷前必备份原厂 boot 分区**（救砖用）：
   ```bash
   adb shell "su -c 'dd if=/dev/block/by-name/boot_b of=/data/local/tmp/boot_b.img'"
   adb pull /data/local/tmp/boot_b.img .
   ```
   建议把 vendor_boot / dtbo / vbmeta（A/B 双槽）也一并备份。

2. 刷入 AnyKernel3 zip（三选一）：
   - **KernelSU 管理器**：安装 → 选择 zip → 刷入
   - **recovery**：apply update from sdcard
   - **root shell 在线刷**（PC 端 adb 全自动）：
     ```bash
     adb push senna-mq_lto-AnyKernel3.zip /data/local/tmp/ak3.zip
     adb shell "cd /data/local/tmp && mkdir ak3 && cd ak3 && unzip -q ../ak3.zip && \
       su -c 'export POSTINSTALL=/data/local/tmp; export AKHOME=/data/local/tmp/tmp/anykernel; \
       sh META-INF/com/google/android/update-binary dummy 1 /data/local/tmp/ak3.zip'"
     adb reboot
     ```

3. 开机后验证：Droidspaces 应用 → 设置 → 需求 → 检查需求；或终端 `su -c droidspaces check`。

### 救砖

手机无法开机时：长按 **音量减 + 电源键** 进入 fastboot，刷回备份即可恢复：
```bash
fastboot flash boot boot_b.img && fastboot reboot
```

## ⚠️ 红线

- **`CONFIG_CFS_BANDWIDTH` / `CONFIG_CGROUP_PIDS` 禁止开启**——无 kABI 补丁可修，会改变调度器/cgroup 结构体大小（实测 5.15 树上 4101 个符号 CRC 变化），vendor 模块拒绝加载 → 无限重启。脚本已强制保持关闭。
- **`CONFIG_SYSVIPC` 禁止开启**（本设备实测 bootloop，见上表）。
- **不要 fastboot 直刷 CI 产出的 boot.img**。
- 不要关闭 `CONFIG_MODVERSIONS`。
- 升级 ColorOS 大版本后需换对应源码分支重编。

## 致谢

- [Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS) — 容器方案与 kABI 补丁
- [Quantom2/Realme-GT3-neo5-kernels](https://github.com/Quantom2/Realme-GT3-neo5-kernels) — senna 构建链路参考
- [realme-kernel-opensource](https://github.com/realme-kernel-opensource) — 官方内核源码
- KernelSU / SUSFS / AnyKernel3 社区
