# GhostLock — Honor Pad 9 Pro (ROD-W09) EXP

> **GhostLock（CVE-2026-43499）** 本地提权 EXP 的 **荣耀平板9Pro（ROD-W09）** 适配成品。
> 内核 `rtmutex` `remove_waiter` 路径的 use-after-free；本仓库已在本设备上真机适配并稳定运行。
> 目前仍处于**开发阶段**，只有Root shell，目前不支持任何Root管理器（正在积极适配）。

|      |                                                                                        |
| ---- | -------------------------------------------------------------------------------------- |
| 设备 | 荣耀平板9Pro，型号**ROD-W09**，SoC **联发科天玑 8100（MT6895）**                       |
| 系统 | MagicOS 8.1.0.230（`C00E230R10P2H1`），Android 14                                      |
| 内核 | **5.10.66-android12-9-ge639f4185278**（`#1 SMP PREEMPT Wed Oct 29 10:08:49 UTC 2025`） |
| 结果 | **临时 root（uid 0）+ SELinux permissive + `sig_enforce=0`** —— 真机验证通过         |

这是**临时 root**：一次运行把内核凭据翻成 root 并关掉模块签名校验，**重启即复原**。
仅供在**自己的设备**上做安全研究。

## 警告

仅供在**自己的设备**上做安全研究。运行本工具会给进程完整 root 权限、并把
SELinux 变为宽容模式；失败时平板会重启（内核开了 `CONFIG_PANIC_ON_OOPS=y`，
不存在“无害的失败”）。**使用风险自负**，不提供任何担保，先备份。
见 [LICENSE](LICENSE)（exploit 部分 Apache-2.0）。
**请在确认设备版本精确匹配后再运行**，每个版本的内核偏移量都可能不同，需要重新适配。**在不匹配版本的情况下运行不保证成功性和稳定性！**

---

## 本适配相对上游改了什么

上游是 **Honor 70 Pro（SDY-AN00）** 的 GhostLock 移植。荣耀平板9Pro（ROD-W09）
与它运行**逐字节相同的内核**（版本串、编译时间一致），因此直接复用了同一份
`mtk-SDY-AN00_8.0.0.220` target 偏移表，仅做了针对性适配：

| 文件                                                  | 改动                                                                                                                                                                                                                  |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `exploit/src/targets/mtk-SDY-AN00_8.0.0.220/target.h` | 栈载具落点重调：`SLIDE_MCAST_SHIFT` 由上游的 `7` 改为 **`15`**（本设备 `setsockopt(MCAST_JOIN_SOURCE_GROUP)` 的 `group_source_req` 拷贝落在 `S−0x360`）                                                              |
| `exploit/src/slide.c`                                 | MCAST 载具调试打点（`gsr[]` 布字、`if_nametoindex`、全量 gsr dump），用于在本设备上调校载具                                                                                                                           |
| `root.ps1`                                            | **新增**——Windows 端一键驱动：WSL 实时编译 → `adb` 推送 → 启动 EXP → 轮询成功标记 → 打开连接窗口连 root shell。连接客户端支持降级链（本地 nc → WSL → 系统 ncat/nc → PowerShell 内置 TCP），无 WSL 环境也能用 |

> `main.c` 与上游一致，无需改动；KernelSU 组件（`ksu/`、`tools/`）在本设备内核上
> 不适用（无 `CONFIG_KPROBES`），已剔除。

---

## 使用方式（Windows，推荐）

**前置条件**（按需满足，脚本会自动选择可用路径）：

| 用途        | 必需         | 说明                                            |
| ----------- | ------------ | ----------------------------------------------- |
| EXP运行文件 | 完整项目克隆 | 若无WSL环境需在 releases 中下载`exploit_static` |
| 编译 EXP | 推荐 WSL + `aarch64-linux-gnu-gcc` | 无 WSL 时回退到预编译产物 `exploit_static` |
| 推送 / 启动 EXP | 内置 `adb-fastboot-tools\adb.exe` | 无需手动安装 ADB，找不到时回退 PATH 中的 `adb` |
| 连接 root shell | **任一**连接客户端 | 本地 nc（推荐）→ WSL → 系统 ncat/nc → PowerShell 内置 TCP |
| 设备 | 平板开无线调试，与 PC 同网段 | — |

**若为下载`exploit_static`运行则需要将`exploit_static`放置在`.\exploit\build\mtk-SDY-AN00_8.0.0.220\bin`下才可被脚本检测。**

一键运行：

```powershell
# 编译 + 推送 + 提权 + 连 root shell（一键）
powershell -ExecutionPolicy Bypass -File .\root.ps1
```

打印 "完成" 后，root shell 已通过 WSL/项目自带 的 nc 打开
（或手动： nc <平板IP> 34567   →  uid=0 的 shell）

`root.ps1` 会依次：探测设备 IP → 用 WSL 实时编译 EXP（回退到 `exploit_static`）→
`adb push` 并赋权 → 后台启动 EXP 并轮询 `exploit chain complete` 标记 → 从 WSL
`nc <设备IP> 34567` 连入 root shell。失败（内核崩溃）会自动提示重试。

> 关键运行时参数（`root.ps1` 已内置）：`SLIDE_MCAST_SHIFT=15 SLIDE_MCAST_OPT=44`，
> 与本仓库 target 表的载具偏移匹配。

### 手动（Linux / macOS / adb shell）

```sh
adb push exploit_static /data/local/tmp/gl_sdy && adb shell chmod 755 /data/local/tmp/gl_sdy
adb shell 'cd /data/local/tmp && nohup env KSU_RUNDIR=/data/local/tmp/glrun_sdy \
           SLIDE_MCAST_SHIFT=15 SLIDE_MCAST_OPT=44 /data/local/tmp/gl_sdy > /data/local/tmp/gl.log 2>&1 &'
# 等 40~90 秒，然后： nc <平板IP> 34567   →  uid=0 shell
```

`exploit_static` 预编译产物在 *GitHub Release*，按需下载。
下载`exploit_static`后文件放在`exploit/build/mtk-SDY-AN00_8.0.0.220/bin/`即可识别推送

---

## 目录结构

```
root.ps1                     Windows 端一键驱动（编译→推送→提权→连 shell）
tools/          内置 EXP 所需运行时（adb.exe + DLL，ncat.exe）
exploit/                     GhostLock 源码（Android arm64）+ 构建系统
  src/targets/mtk-SDY-AN00_8.0.0.220/target.h   本设备偏移表
  Makefile / docker-build.sh 构建脚本（NDK 或 aarch64 交叉编译）
LICENSE                      许可证（exploit 部分 Apache-2.0）
SECURITY.md                 滥用、安全信息联系渠道
```

---

## 构建 EXP

```sh
cd exploit
# 方式一：交叉编译器
make CC=aarch64-linux-gnu-gcc PROJECT=mtk-SDY-AN00_8.0.0.220 bin

# 方式二：Android NDK（Makefile 自动探测 NDK_ROOT / ANDROID_NDK_HOME）
make PROJECT=mtk-SDY-AN00_8.0.0.220 bin

# 方式三：Docker 构建器（宿主机免依赖）
./docker-build.sh

# 产物：
#   build/mtk-SDY-AN00_8.0.0.220/bin/exploit          （PIE 动态，adb 用）
#   build/mtk-SDY-AN00_8.0.0.220/bin/exploit_static   （静态，可无依赖运行）
```

---

## 提权原理（简述）

`futex_wait_requeue_pi` 返回 `EDEADLK` 会在任务内核栈上留下一个 stale
`struct rt_mutex_waiter`（0x50 字节）。随后 `sched_setattr` 驱动的
`rt_mutex_adjust_prio_chain` 会跟随该栈字上的 `pi_tree_entry.rb_node` 指针
解引用——即读取**当前栈上任意数据**。通过一个“载具”系统调用
（本设备为 IPv4 `setsockopt(MCAST_JOIN_SOURCE_GROUP)` 的 `group_source_req`
逐字拷贝）把受控数据放到栈上正确深度，即可让 `rb_erase`/`rb_insert` 变成任意地址写，
进而：KASLR 泄基 → `boot_id` ctl_table 劫持 → 任意内核读写 → cred 换成
`init_cred`（uid 0）→ SELinux permissive + `sig_enforce=0`。

---

## 致谢

- [CyberMeowfia / IonStack](https://github.com/NebuSec/CyberMeowfia) —— 上游 PoC
- [GhostLock-H80GT](https://github.com/yakidango-official/GhostLock-H80GT)
- [Ghostlock-Honor70Pro](https://github.com/litianyuan-91/Ghostlock-Honor70Pro) —— 本次适配所基于的上游仓库