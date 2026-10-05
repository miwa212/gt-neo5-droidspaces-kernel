# senna Droidspaces 内核（realme GT Neo5 240W / RMX3708）

为 realme GT Neo5 240W（RMX3708，社区代号 senna）编译支持 [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS)（安卓容器方案）的自定义 GKI 内核。

- **设备**: realme GT Neo5 240W / RMX3708 / GT Neo5 / GT3（senna，骁龙 8+ Gen 1）
- **系统**: ColorOS 15 / Android 15，内核 5.10.226-android12-9（GKI，KMI 9）
- **源码**: realme AndroidU 官方内核（经 `Quantom2/gt_neo5_kernel_manifest` 同步 kernel_platform）
- **功能**: Droidspaces 容器支持（namespaces/cgroups/seccomp/netfilter），kABI 安全

## 构建方式

GitHub Actions 云端构建：进入 **Actions → Build senna Droidspaces GKI kernel → Run workflow**。
产物：AnyKernel3 刷入包 + Image + boot.img（Artifact 或 Release）。

构建流程：
1. `repo sync` 拉取 realme kernel_platform（含内置 clang 工具链）
2. 应用 Droidspaces kABI 补丁（SYSVIPC 槽位自动尝试 + POSIX_MQUEUE 5.10 必打）
3. 修改 `common/arch/arm64/configs/gki_defconfig`（kABI 安全配置集合）
4. `oplus_build_kernel.sh wapio gki thin all disable` 编译
5. WildPlusKernel/AnyKernel3（gki-2.0）打包

## 刷入

1. **刷前必备份原厂 boot.img**（救砖用）
2. recovery 刷 AnyKernel3 zip，或 `fastboot flash boot senna-droidspaces-boot.img`
3. 开机后 Droidspaces 应用：设置 → 需求 → 检查需求；终端 `su -c droidspaces check`

## ⚠️ 红线

- `CONFIG_CFS_BANDWIDTH` / `CONFIG_CGROUP_PIDS` **禁止开启**——无 kABI 补丁可修，会改变调度器/cgroup 结构体大小，vendor 模块拒绝加载 → 无限重启。脚本已强制保持关闭。
- SYSVIPC/POSIX_MQUEUE 的 kABI 补丁缺一不可，缺失即 bootloop。
- 升级 ColorOS 大版本后需换对应源码分支重编。

## 致谢

- [Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS) — 容器方案与 kABI 补丁
- [Quantom2/Realme-GT3-neo5-kernels](https://github.com/Quantom2/Realme-GT3-neo5-kernels) — senna 构建链路参考
- [realme-kernel-opensource](https://github.com/realme-kernel-opensource) — 官方内核源码
- KernelSU / SUSFS / AnyKernel3 社区
