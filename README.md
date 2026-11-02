# 音频模式切换器 · hyperaudio

> 通用机型的 HyperOS 音频模块：**在「音效」与「低延迟」两种工作模式间一键切换**，
> 附带 KernelSU WebUI 可视化配置。

[![模块版本](https://img.shields.io/badge/version-0.4.7-blue)]()
[![适配](https://img.shields.io/badge/机型-通用-green)]()
[![管理器](https://img.shields.io/badge/KernelSU%20%7C%20APatch%20%7C%20Magisk-WebUI-orange)]()

---

## 这是什么

HyperOS 的音频链路里存在一对**框架层互斥**：

- **fast track**（FastMixer 直通）—— 延迟最低，但**绕过 AudioFlinger 效果链**，音效调音不生效；
- **普通混音线程** —— 音频经过效果链，Dolby 等调音生效，但调度抖动更大、可能卡顿。

这两条路的选择由音频端口的 `FAST` 标志决定，**是全局的**，同一端口无法"对 A 应用生效、对 B 应用不生效"。

本模块把这组全局开关做成了**可切换的两种模式**，让你按场景选择：

| 模式 | 做什么 | 适合 |
|---|---|---|
| **音效模式**（默认） | 摘掉音频端口 `FAST` 标志 → 全部音频落入效果链 | 听歌、看视频、慢节奏游戏 —— 追求听感 |
| **低延迟模式** | 恢复 `FAST` 标志，并启动守护进程提升音频线程实时优先级 | 音游、竞速、FPS —— 追求延迟与流畅 |

> 实测依据：同一游戏在两种模式下的 A/B 对比中，"摘掉 FAST"后 Dolby 调音才可闻；
> 保留 FAST 时不卡顿但调音被绕过。详见下文「技术说明」。

---

## 功能

### 双模式切换

- 切换在 WebUI 内一键完成，**约 8 秒生效**（会重启音频服务，可能有短暂静音）
- 模式记录在 `/data/adb/modules/hyperaudio/mode`，**开机自动应用**
- 音效模式下自动停用 `hyper-audio` 守护进程（不需要 RT 提权），低延迟模式下自动启用

### WebUI（KernelSU / APatch 管理器内打开）

- **模式切换**：两个模式按钮，当前模式高亮；切换期间按钮显示旋转动画并禁用，
  期间界面保持可见（不遮屏），完成后提示"音频服务已重启"
- **一键切换**：右上角按钮直接切到另一种模式；顶部徽章常显当前模式
- **KernelSU 执行按钮**：模块卡片上的「执行」调用 `action.sh`，一键切换模式，
  并把当前模式写进 `module.prop` 的 `description` 前缀，因此**模块列表里就能看到当前模式**
  - 前缀形如 `【当前模式：音效模式】…`；标记文案存在 `module.prop` 的 `mode.sound` / `mode.fast` 行
  - 每次刷新先剥掉旧前缀，反复切换不会层层叠加；开机时 `service.sh` 会补刷一次
- **参数配置**（仅低延迟模式显示）：守护进程总开关、仅白名单生效开关、三档实时优先级
- **白名单编辑**（仅低延迟模式显示）：手动输入包名，白名单内的应用在前台时其音频线程会被提升为 `SCHED_FIFO`
  - 注：音效模式下会**隐藏**这些低延迟设置，白名单数据不会丢失
- **调音来源**：显示当前生效的第三方调音模块名与版本；**未检测到则显示「官方默认调音」**
  - 检测遍历全部已安装模块，耗时较长，因此界面**先用默认值立即渲染**，
    调音来源在 `status` 返回后**再异步拉取填充**（不阻塞主界面）
  - 命中判定按「路径 + 文件名」两个条件：位于 `dolby` / `audio` / `acdbdata` 目录下，
    或直接位于 `*/etc/` 下，且文件名符合 `dax-*` `dax_default*` `mixer_paths*` `acdb*`
    `audio_effects_config.*` `audio_module_config_*` `resourcemanager*`
  - 排除属路由/音量策略而非调音的文件：`audio_policy_configuration.xml`、
    `audio_policy_engine_*`、`*volume*`、`audio_lowpower_app_list.xml`
  - 命中多支调音模块时会列出全部目录名并提示可能互相覆盖

### 音频优化（属性层）

| 项目 | 内容 |
|---|---|
| 低延迟通路 | `aaudio.mmap_policy` / `mmap_exclusive_policy` / `hw_burst_min_usec` |
| 缓冲周期 | `vendor.audio_hal.period_size` / `period_multiplier` / `adm.buffering.ms` |
| 蓝牙 | aptX Adaptive / LDAC / LHDC / LC3（LE Audio）编解码解锁、AAC 帧控调整 |
| 硬件直通 | `offload.passthrough`、各 PCM 位深 offload、24/32bit/float 输出 |
| 通路库 | `libaaudio_internal*.so`（HyperOS AAudio MMAP 实现） |

> 早期版本还包含「遮蔽 4 个音频策略库 + 低功耗清单」的做法，**现已彻底移除**：
> 实测遮蔽 `*impl.so` 会让音频实现层失效 —— 音效模式下调音全无、部分音频无声，
> 低延迟模式仍有声但调音同样失效。详见 `assets/customize.sh` 中的说明。

---

## 安装

**前置**：已安装 KernelSU / APatch / Magisk（v20.4+），已解锁并刷入 HyperOS。

1. 下载本仓库 Releases 中的 `hyperaudio_module.zip`（或自行运行 `build.ps1` 生成）
2. 在模块管理器中刷入
3. 重启
4. 打开管理器的 **WebUI** 入口进行配置

> **通用机型**：模块内无任何机型判断，任何 HyperOS 设备均可安装。
> 但**音效模式需要设备上存在调音模块**（提供 `audio_module_config_primary.xml`）才有实际效果；
> 若只是想要低延迟优化，可保持低延迟模式。

### 卸载

在模块管理器中卸载即可。模块不修改任何系统分区文件。

由于音效模式会用 `mount --bind` 覆盖 `/odm/etc/audio/audio_module_config_primary.xml`，
而运行时建立的挂载**不由管理器管理**，本模块附带 `uninstall.sh`：卸载时会停止守护进程、
把端口 FAST 标志还原、摘掉该挂载并清理 `/data/local/tmp` 下的临时文件。
仍建议**卸载后重启一次**，以彻底清除本次开机建立的所有挂载。

---

## 技术说明

### 为什么两种模式互斥

```
音效模式：low_latency_out/raw_out 无 FAST
          → 应用音频落入普通混音线程 → 经过效果链（Dolby 生效）→ HAL
低延迟模式：low_latency_out/raw_out 带 FAST
          → 应用音频由 FastMixer 直通混音 → 绕过效果链 → HAL
```

端口只有一个，标志是全局的。想"对指定应用启用低延迟"在框架层做不到 ——
实测确认 `audio_app_registry.xml` 的 `ull_app` 名单**无法剥夺**名单外应用的 ULL/MMAP 通路。

### 已排除的卡顿成因（供参考）

在非 fast 路径上出现的卡顿，实测排除了以下原因：

| 尝试 | 结果 |
|---|---|
| 音频线程 RT 优先级拉满（12 线程 `SCHED_FIFO/16`） | 卡顿依旧 |
| 停用调音模块的周期性 mixer 写入守护进程 | 卡顿依旧 |
| 加大 HAL 缓冲（period_size / adm.buffering） | 帧数未变 |
| `underrun` 计数 | 始终为 0 —— **不是缓冲饿死**，是非 fast 路径的固有调度代价 |

### 环境适配备注

- 本设备（KernelSU Next）的 `ksu.exec()` **只回传 stdout 最后一行**且不支持 shell 重定向，
  故设备端 `webui/helper.sh` 的所有输出都用 `\x1f` 压成单行，由前端拆分解析。
- `/internal/insets.css` 在部分设备上不存在，WebUI 未依赖它，改用 CSS 变量提供状态栏留白。

---

## 仓库结构

```
assets/    本项目维护的文本源码
           module.prop / customize.sh / service.sh / system.prop
webui/     本项目源码：WebUI 与设备端脚本
           webroot/            KernelSU WebUI 界面（index.html / app.js / style.css）
           helper.sh           WebUI 后端（status / tuning / setmode / save / recover）
           action.sh           KernelSU 执行按钮（一键在两种模式间切换）
           uninstall.sh        卸载清理（撤销端口层 / 停守护进程 / 修旧版遗留 / 清临时文件）
           runtime.sh          模式状态机（改副本再 bind + 事务 + 开机护栏 + 回滚 + 就绪校验）
           audio_ready.sh      音频就绪校验（重启后确认框架真的加载了配置）
           check_audio_ready.awk  dumpsys 解析器（端口 flags 位掩码比对）
           patch_ports.awk     有界 XML 编辑器（只改两个端口的 flags，异常一律 fail-closed）
           start_daemon.sh     守护进程启动器
           detect_tuning.sh    调音来源检测（异步调用，不在关键路径）
           diagnose.sh         只读诊断导出（模式/挂载/端口/就绪/日志，不改状态）
tests/     主机侧测试（不随包分发，用 `sh tests/run.sh` 跑）
           run.sh                       测试入口
           test_patch_ports.sh          patch_ports.awk 改写与 fail-closed 用例（16 项）
           test_runtime_state_machine.sh runtime.sh 的事务/回滚/护栏/挂载归属/就绪校验（68 项）
           test_audio_ready.sh          report_flags 位掩码与 dumpsys 解析（29 项）
           test_diagnose.sh             诊断导出：只读性/结构完整/落盘（28 项）
           test_action_uninstall.sh     动作按钮与卸载：就绪结论/失败原因/退出码（26 项）
           test_save_validation.sh      save 的严格校验（非法输入必须整体拒绝）
           test_save_no_accumulation.sh 反复保存不应让配置文件增长

> `runtime.sh` 跑在主机上需要注入：路径用 `HA_MOD` / `HA_TMP` / `HA_SOURCE_DIR` /
> `HA_TARGET_BASE` / `HA_MOUNTINFO` / `HA_BOOT_ID_FILE` 重定向；`mount`/`umount` /
> `dumpsys` / `pidof` / `getprop` 用 PATH mock；归属判定用测试钩子
> `HA_RT_OURS_TEST` / `HA_RT_TARGET_STAT`。
> 这些变量**只在测试里设置**，真机上不设，取值与默认行为完全一致。
> 注意：就绪校验的 dumpsys 夹具是**离线构造**的，真实输出格式必须真机确认。
prebuilt/  上游预编译产物（无法从源码重建，按原样保留，见 CREDITS.md）
CREDITS.md 来源与致谢（随模块包分发）
build.ps1  构建脚本：组装 + 清理作者标识 + 校验 + 打包（产物逐字节可复现）
```

### 端口补丁是怎么做的（0.4.6 起）

音效模式需要摘掉 `low_latency_out` / `raw_out` 的 FAST 标志，本模块的做法是：

1. 找到提供 `audio_module_config_primary.xml` 的调音模块源文件（按文件名探测，不认机型）
2. 把**生效路径上的那份文件**快照到 `state/base.xml`
3. 用 `patch_ports.awk` 从快照生成 `state/active.xml`（只改两个端口的 flags，其余字节不动；
   任何不支持的构造都拒绝执行）
4. 把 `active.xml` **叠加 bind mount** 到生效路径 —— **不先 umount**
   （失败的 umount 会让该文件彻底失挂、比 mount 失败更糟）

因此：

- **不写调音模块的任何文件**，升级/禁用/卸载都不会留下被改过的第三方文件
- 卸载只需摘掉自己那一层，系统原始配置即刻恢复
- 挂载归属用 `dev:ino` + `/proc/self/mountinfo` 判断；若发现已被别的模块替换则**拒绝动手**

> 从 0.4.5 及更早版本升级上来的设备，源文件可能已被旧版**直接改过**（缺 FAST）。
> `runtime.sh` 会在应用前识别并修复这一遗留状态；判据保守（两个端口都缺 FAST 才认定）。

### 诊断导出（0.4.7 起）

出问题时不用反复追问"你的模式是什么 / 层挂上了吗 / 框架加载了吗"：
WebUI 底部「支持 → 诊断」里点一下，或在终端跑 `sh bin/diagnose.sh --save`，
会生成一份**只读**报告：

```
hyperaudio-diag-<时间戳>.txt
├─ 版本 / 模式 / applied / pending / 开机护栏 / 按应用音效是否启用
├─ 目标路径上的挂载层（谁叠在谁上面）
├─ 当前生效文件的端口 flags（low_latency_out / raw_out）
├─ runtime status 原文
├─ 音频就绪校验：期望值、观测值、结果、pid
├─ 音频策略与混音线程摘要（含 DAP 效果链出现次数）
├─ 调音来源、配置项、白名单（前 15 项）
└─ 日志尾部（每个日志最多 40 行）
```

它**不写任何配置、不动挂载、不重启服务**（测试里用"跑完前后文件快照必须一致"锁住了
这一点）。输出目录优先 `/sdcard/Download`，不可用时退到 `/data/local/tmp`；
也可用 `HA_DIAG_DEST=<目录>` 指定。报告不含应用数据与账号信息。

### 音频就绪校验（0.4.7 起）

**只验证磁盘文件是不够的。** 端口补丁写完、bind mount 挂上，只说明"文件内容对"；
audioserver 还要读策略、建主输出、填 HAL 缓冲才真正生效。这中间有个真实窗口，
用户会看到"已切换"但实际行为没变。

所以改完端口后，本模块会：

1. 只在端口 flags **确实变化**时才重启音频服务（`killall audioserver`）
2. 重启后逐次探测，要求「同一 audioserver PID + 同一观测签名**连续 3 次**」
3. 每次都核对：`init.svc.audioserver` 在跑、`dumpsys media.audio_policy` 与
   `media.audio_flinger` 可读、主输出存在、HAL frame count > 0、
   **dumpsys 里实际加载的端口 flags 与我们写入的位掩码一致**
4. 上限 30 秒 / 20 次（双保险，慢机型不会无限等）

结果的语义（WebUI「音频框架」一行 + `status` 的 `audio_ready=`）：

| 值 | 含义 | 处置 |
|---|---|---|
| `passed` | 已确认加载，且 flags 与写入一致 | `verified=1` |
| `failed` / `timeout` | 尝试过但没通过 | 保留模式，`verified=0` 并显示原因 |
| `stale` | 上次记录已过期（音频服务重启过 / 换过开机） | 需要重新切换才有结论 |
| `unverified` | dumpsys 读不到或格式认不出 | 不断言，`verified=0` |

只有 **flags 确实不符** 或 **音频服务起不来** 才回滚；读不到、格式不认、
等待超时只记 `unverified` —— 区别"证明错了"与"无法验证"，
避免在 dumpsys 输出格式不同的机型上把好配置回滚掉。

> 边界：`passed` 只代表**框架加载了配置**，不代表能出声，也不代表 Dolby 正在处理。
> 该结论来自主机侧离线夹具 + 真机实测，dumpsys 格式差异仍需在具体机型上确认。

### 事务与开机护栏

- `apply` 前先写 `state/pending`；**全部成功**才写 `state/applied` 与 `mode`，并清除 pending
- 任一步失败 → 撤销全部改动、`mode` 写回 `fast`、报 `apply_failed_restored_native`；
  回滚自身失败则报 `rollback_incomplete_reboot_required` 并**保留 pending**
- 开机时若发现残留 `pending` 或上次开机失败记录，**强制回到原始配置**并记入
  `state/boot.failure`，**绝不反复重试一个已知失败的配置**
- WebUI 会在需要恢复时显示「需要恢复」卡片，提供一键 `recover`

### 与 HyperAudio Switch 2.0 的差异（有意为之）

参考 2.0 时**没有**采用这两点：

- **不用 `setprop ctl.restart audioserver`**：本机实测重启音频服务会让调音失效，
  因此仍用 `killall audioserver`，且**只在端口标志真的变化时**才做
- **不在运行时改 `aaudio.*` 属性、不替换 AAudio 库**：本模块继续用 `system.prop` 与预编译库，
  也不做"每 5 秒 dumpsys 巡检"式的常驻调度（那是 2.0 自己的取舍）

### 构建

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1
# 输出 hyperaudio_module.zip
```

构建脚本会在打包前执行下列校验，任一不通过即拒绝出包：

1. **文件布局白名单**：staged 目录内出现任何未预期的文件即失败。
   （原先只按文件扩展名做内容检查，放一个 `webroot/extra.xml` 就能把机型代号、
   作者标识、调音载荷关键词原样打进包里 —— 已实测复现并修掉。）
2. **不得含调音载荷**：ACDB / Dolby DAX / mixer / resourcemanager / 音量曲线 等
3. **不得含机型判断**
4. **除 `CREDITS.md` 外不得含原作者个人标识**：文本与二进制（`hyper-audio`、`*.so`）都扫
5. **`system.prop` 必须是净化后的版本**（含特定注释、且不含上游署名注释）

构建产物**逐字节可复现**：zip 条目时间戳已固定，同样内容两次构建哈希相同。
校验失败时**不会留下任何产物**（旧包在构建开始时即被删除）。

---

## 来源与致谢

本模块并非从零编写，**技术基底来自 [HyperAudio](https://github.com/2278535805/HyperAudio)（作者 HLMC Ray）**，
并由同一作者的 [Mi17Audio](https://github.com/2278535805/Mi17Audio) v0.3.4 扩展而来：

- 继承自 **HyperAudio**：`system.prop` 全部 32 条基础属性（100% 包含，仅 2 条取值微调）、
  `odm` 兜底挂载的守卫写法、线程提权的设计思路
  （其"遮蔽 4 个音频策略库"的做法本项目**已移除**，见上方说明）
- 继承自 **Mi17Audio**：`hyper-audio` 守护进程、`libaaudio_internal*.so`、`META-INF` 安装入口、
  蓝牙与 offload 等补充属性

本项目在其基础上的改动、以及上游的许可证状况，详见 **[CREDITS.md](CREDITS.md)**。

感谢原作者在 HyperOS 音频策略层所做的逆向与整理工作 —— 这是本项目得以成立的基础。

---

## 免责声明

- 本项目为**个人学习与自用**性质的修改。上游两个仓库均**未声明开源许可证**（默认保留所有权利）；
  若原作者对本项目有任何异议，请通过上游仓库 issue 或本项目 issue 联系，我会立即处理或删除。
- 刷机有风险。请自行确认设备与系统版本，并做好数据备份。
- 音效模式的卡顿、低延迟模式的调音缺失，都是 Android 音频框架的固有权衡，非本模块缺陷。
