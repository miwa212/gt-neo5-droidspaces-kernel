# senna Droidspaces 内核（realme GT Neo5 240W / RMX3708）

为 realme GT Neo5 240W（RMX3708，社区代号 senna）编译支持 [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS)（安卓容器方案）的自定义 GKI 内核。

- **设备**: realme GT Neo5 240W / RMX3708 / GT Neo5 / GT3（senna，骁龙 8+ Gen 1 / SM8475）
- **系统**: ColorOS 15 / Android 15，内核 5.10.226-android12-9（GKI，KMI 9）
- **源码**: realme AndroidU 官方内核（经 `Quantom2/gt_neo5_kernel_manifest` 同步 kernel_platform）
- **当前推荐版本**: [`senna-mq4nm_lto`](../../releases)（mq4_lto 全部配置 + 移除 oplus_bsp_midas 的 cpufreq_acct hook，修复使用 Droidspaces 时的随机内核 panic，已在真机验证）

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
| mq3_lto | mq_lto + DEVTMPFS_MOUNT + USER_NS | ✅ 启动 |
| **mq4_lto** ⭐⭐ | **MQUEUE + IPC_NS + DEVTMPFS_MOUNT + USER_NS + PID_NS**（无 SYSVIPC） | ✅ **启动，/proc/config.gz 实测全部生效** |
| sv1_lto | mq4 + SYSVIPC + BYPASS_MODVERSIONS + kABI 补丁 | ✅ 构建成功，❌ 刷入 bootloop |
| sv2_lto | **仅 SYSVIPC** + BYPASS_MODVERSIONS，不打任何补丁 | ❌ 刷入即 bootloop（决断实验） |
| **mq4nm_lto** ⭐⭐⭐ | **mq4 + 注释掉 `cpufreq_times.c` 的 midas hook 调用** | ✅ 启动，修复 Droidspaces 使用中随机 panic（见下文） |

**关键发现：**

1. **`CONFIG_SYSVIPC` 是砖因，且与 kABI 补丁无关**——sv2_lto 决断实验（仅 SYSVIPC、绕过 CRC 校验、不打任何补丁）刷入即 bootloop，证明是 SYSVIPC 的结构体/行为本身与闭源 vendor 环境冲突。kABI 槽位补丁（1_2_3/3_4_5/6_7_8）全部无法挽救。**无解**，除非同源重建全部 vendor 模块并同刷 vendor_boot / vendor_dlkm / system_dlkm。
2. **`IPC_NS depends on (SYSVIPC || POSIX_MQUEUE)`**（5.10 Kconfig）。只开 IPC_NS 会被静默丢弃——这就是 cfgK2 "能开机" 的真正原因（等于没改配置）。
3. **POSIX_MQUEUE 的 kABI 填充补丁有效**，单独开启不会破坏 CRC；mq4_lto 实测 MQUEUE + IPC_NS + PID_NS + DEVTMPFS_MOUNT + USER_NS 可同开（mq2_lto 的失败另有原因，非 PID_NS 与 MQUEUE 的冲突）。
4. **关闭 `CONFIG_MODVERSIONS` 是死路**：原厂模块 vermagic 带 `modversions` 标志，直接拒载（BYPASS_MODVERSIONS 包装函数可绕过 CRC 校验让构建通过，但救不了 SYSVIPC）。
5. ⚠️ **`fastboot flash boot` 直刷任何非原厂 boot.img 都会导致无法开机**（CI 打包的 boot.img 不含 realme 原厂 ramdisk）。**只能用 AnyKernel3 方式刷入**（只替换内核 Image，保留原厂 ramdisk/dtb）。

## 🐛 mq4_lto 已知问题：使用 Droidspaces 时随机整机重启（mq4nm_lto 已修复）

mq4_lto 在使用 Droidspaces（容器进程频繁创建/退出）时会**间歇性整机重启**（非冻结）。经持久化 logcat/dmesg + oplus minidump（`/data/persist_log/DCS/minidump/minidump.bin`）抓到完整 panic 现场：

```
pc : strncpy+0x10/0x30
lr : update_or_create_entry_locked+0x1e8/0x288 [oplus_bsp_midas]
调用链: 时钟tick中断 → account_process_tick → cpufreq_acct_update_power
        → midas_record_task_times [oplus_bsp_midas] → strncpy → 💥
现场: entry->task=NULL（任务退出后残留脏记录），strncpy 源地址 0x790 空指针解引用
```

**根因**：oplus 自带 vendor 模块 `oplus_bsp_midas.ko` 通过 `android_vh_cpufreq_acct_update_power` vendor hook 挂在每个时钟 tick 的任务统计路径上，其任务记录表未判空。Droidspaces 的 droidspacesd/ds-monitor 线程创建退出频繁，大幅提高踩中概率。`rmmod` 因模块自固定引用无法卸载。

**修复**（mq4nm_lto）：注释掉 `drivers/cpufreq/cpufreq_times.c` 中 `trace_android_vh_cpufreq_acct_update_power(...)` 调用——midas 的唯一挂载点被切断，按任务功耗统计失效（无实际影响），panic 根治。

**排查经验**：pstore 因 ramoops_region 使用 alloc-ranges 无固定 reg 无法工作；oplus 的崩溃现场可从 `/data/persist_log/DCS/minidump/minidump.bin` 提取（明文 grep `Unable to handle kernel` 即可）。

## 推荐版本：mq4nm_lto

Droidspaces 官方 `check` 结果（mq4_lto 真机实测，全绿）：

```
[MUST HAVE]
  [✓] Root privileges / Linux version / Mount namespace
  [✓] UTS namespace / IPC namespace / PID namespace
  [✓] pivot_root / /proc / /sys / Seccomp
[RECOMMENDED]
  [✓] epoll / signalfd / PTY / devpts / devtmpfs / Loop / ext4 / Cgroup v2 / Cgroup namespace
[OPTIONAL]
  [✓] IPv6 / FUSE / TUN-TAP / OverlayFS / Network ns / Bridge / Veth
```

缺 SYSVIPC 对现代发行版影响很小（systemd/Alpine 默认几乎不依赖）。mq4nm_lto 在此基础上修复 midas panic，可长期稳定使用 Droidspaces。

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
| `mq4nm_lto` | **推荐**：mq4 全部配置 + 修复 midas panic |
| `mq4_lto` | mq3 + PID_NS（有 midas panic 隐患） |
| `mq3_lto` | MQUEUE + IPC_NS + DEVTMPFS_MOUNT + USER_NS |
| `mq_lto` | 最小可用：MQUEUE + IPC_NS |
| `stock_lto` | 基准对照：原厂配置 + ThinLTO |
| `sv1/sv2_lto` / `cfgK1-K5_lto` / `modv(2)_lto` / `mq2_lto` | 实验用（见上表，均不可用） |

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
     adb push senna-mq4nm_lto-AnyKernel3.zip /data/local/tmp/ak3.zip
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
