# 音频模式切换器 · hyperaudio

> 通用机型的 HyperOS 音频模块：**在「音效」与「低延迟」两种工作模式间一键切换**，
> 附带 KernelSU WebUI 可视化配置。

[![模块版本](https://img.shields.io/badge/version-0.4.0-blue)]()
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

- **模式切换**：两个模式按钮，当前模式高亮
- **参数配置**（仅低延迟模式显示）：守护进程总开关、仅白名单生效开关、三档实时优先级
- **白名单编辑**（仅低延迟模式显示）：手动输入包名，白名单内的应用在前台时其音频线程会被提升为 `SCHED_FIFO`
  - 注：音效模式下会**隐藏**这些低延迟设置，白名单数据不会丢失

> 早期版本还带「调音来源检测」，因每次打开 WebUI 都要遍历全部已安装模块并做 md5 比对，
> 实测拖慢加载（检测单项约占 `status` 耗时的 78%），已移除。

### 音频优化（属性层）

| 项目 | 内容 |
|---|---|
| 低延迟通路 | `aaudio.mmap_policy` / `mmap_exclusive_policy` / `hw_burst_min_usec` |
| 缓冲周期 | `vendor.audio_hal.period_size` / `period_multiplier` / `adm.buffering.ms` |
| 蓝牙 | aptX Adaptive / LDAC / LHDC / LC3（LE Audio）编解码解锁、AAC 帧控调整 |
| 硬件直通 | `offload.passthrough`、各 PCM 位深 offload、24/32bit/float 输出 |
| 通路库 | `libaaudio_internal*.so`（HyperOS AAudio MMAP 实现） |
| 中间层退让 | 0 字节占位遮蔽 4 个音频策略库 + 低功耗应用清单 |

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

在模块管理器中卸载即可。模块不修改任何系统分区文件，卸载后由管理器撤销挂载。

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
           module.prop / customize.sh / post-fs-data.sh / service.sh / system.prop
webui/     本项目源码：WebUI 与设备端脚本
           webroot/            KernelSU WebUI 界面（index.html / app.js / style.css）
           helper.sh           WebUI 后端（status / setmode / save）
           mode_switch.sh      音效 ↔ 低延迟 模式切换
           start_daemon.sh     守护进程启动器
           hyperaudio_init.sh  开机初始化
prebuilt/  上游预编译产物（无法从源码重建，按原样保留，见 CREDITS.md）
CREDITS.md 来源与致谢（随模块包分发）
build.ps1  构建脚本：组装 + 清理作者标识 + 三项校验 + 打包
```

### 构建

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1
# 输出 hyperaudio_module.zip
```

构建脚本会自动执行三项校验，任一不通过即拒绝出包：

1. **校验 A**：不得含调音载荷（ACDB / Dolby DAX / mixer / 音量曲线 等）
2. **校验 B**：不得含机型判断
3. **校验 C**：除 `CREDITS.md` 外不得含原作者个人标识（含二进制）

---

## 来源与致谢

本模块并非从零编写，**技术基底来自 [HyperAudio](https://github.com/2278535805/HyperAudio)（作者 HLMC Ray）**，
并由同一作者的 [Mi17Audio](https://github.com/2278535805/Mi17Audio) v0.3.4 扩展而来：

- 继承自 **HyperAudio**：`system.prop` 全部 32 条基础属性（100% 包含，仅 2 条取值微调）、
  4 个音频策略库的遮蔽逻辑、`odm` 兜底挂载的守卫写法、线程提权的设计思路
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
