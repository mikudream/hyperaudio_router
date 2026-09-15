# 来源与致谢 / Credits & Attribution

本模块（`音频模式切换器` / id: `hyperaudio`）并非从零编写。经与上游仓库逐文件比对，
**其技术基底来自 HyperAudio，并由 Mi17Audio 扩展而来** —— 两个仓库同属一位作者。
在此完整标注来源并向原作者致谢。

---

## 上游项目（同一作者的演进关系）

### ① 技术基底：HyperAudio

| 项目 | 信息 |
|---|---|
| 名称 | **HyperAudio**（HyperOS 通用音频优化） |
| 版本 | v0.1.0（versionCode 260716） |
| 仓库 | https://github.com/2278535805/HyperAudio |
| 原作者 | **HLMC Ray** |
| 文件数 | 7 个（无调音载荷、无二进制、无 WebUI） |

### ② 扩展基础：Mi17Audio

| 项目 | 信息 |
|---|---|
| 名称 | **Mi17Audio**（小米 17 音频优化） |
| 版本 | v0.3.4（versionCode 260814） |
| 仓库 | https://github.com/2278535805/Mi17Audio |
| 原作者 | **HLMC Ray nakixii** |
| 文件数 | 50+（含 ACDB / Dolby DAX / mixer 通路等完整调音载荷） |

### 两者的演进关系（据比对推断）

HyperAudio 是**概念基线**：它已包含全部低延迟属性表、4 个音频策略库的遮蔽逻辑、
`odm` 兜底挂载，以及"给音频线程提 SCHED_FIFO 优先级"的思路（以纯 shell 脚本实现）。
Mi17Audio 在其上**叠加了机型适配与调音载荷**，并把线程提权从 shell 脚本重写为
Rust 守护进程 `hyper-audio`。

---

## 本项目具体继承了谁

### 来自 HyperAudio（经比对确认）

| 继承内容 | 证据 |
|---|---|
| **`system.prop` 的 32 条属性全部** | 当前模块的 55 条属性中，HyperAudio 的 32 条**100% 被包含**；其中仅 2 条取值不同（`aaudio.hw_burst_min_usec` 2000→1000、`aaudio.mmap_exclusive_policy` 2→3），其余完全一致 |
| **4 个音频策略库的遮蔽逻辑** | `customize.sh` 的 `remove_files()` 与 HyperAudio 逐字相同（相同的遍历路径、相同 4 个库名、相同的 `audio_lowpower_app_list.xml` 遮蔽） |
| **`odm` 兜底挂载的守卫写法** | `[ -d "$MODPATH/odm" ] \|\| exit 0` 与 HyperAudio 完全一致（Mi17Audio 原文没有这一行） |
| **线程提权的设计思路** | HyperAudio 的 `service.sh` 用 `chrt -p $tid -f 10` 提升 `FastMixer` / `Audio.*Out_.*` / `AAudio_.*` 等线程；本项目沿用同一思路，由 `hyper-audio` 二进制与 `bin/mode_switch.sh` 实现 |

> 注：HyperAudio 的 `service.sh` 以 `dumpsys media.audio_flinger` 解析 FastMixer `activeMask`
> 与 MMAP `Tracks` 数量来判断"是否正在低延迟播放"，这一判定维度与本项目依赖的
> `dumpsys` 输出分析一致。

### 来自 Mi17Audio

| 继承内容 | 说明 |
|---|---|
| `hyper-audio` 二进制 + `config.toml` | 1.9 MB Rust 守护进程及其音游白名单配置 |
| `libaaudio_internal*.so` | HyperOS AAudio MMAP 通路库 |
| Magisk 安装入口 | `META-INF/**` |
| 属性表的补充部分 | 蓝牙编解码 / LE Audio / offload / `vendor.audio.ull.playback.support` 等 23 条 |

---

## 本项目在上游基础上的改动

| 改动 | 说明 |
|---|---|
| **移除全部调音载荷** | 删除 Mi17Audio 带来的 42 个文件（约 6.45 MB）：`odm/etc/acdbdata`、`odm/etc/audio`、`odm/etc/dolby`、`system/vendor/etc/audio` |
| **新增双模式切换** | 「音效模式」摘掉音频端口 FAST 标志，使全部音频落入效果链；「低延迟模式」恢复 FAST 并启动守护进程。新增 `bin/mode_switch.sh`、`bin/hyperaudio_init.sh`，开机按 `mode` 文件自动应用 |
| **新增 KernelSU WebUI** | `webroot/`（界面）+ `webui/helper.sh`（后端）：模式切换、实时优先级、白名单编辑、调音来源检测 |
| **新增调音来源检测** | `bin/detect_tuning.sh`：扫描本机已安装模块并用 md5 比对，判断哪份调音文件真正生效 |
| **去除机型限制** | 删除 Mi17Audio 的 `device_setup()`（按设备代号裁剪配置）与音量键询问逻辑，改为通用机型 |
| **重命名与重新署名** | 模块 ID 改为 `hyperaudio`，名称改为「音频模式切换器」，版本重定为 `0.4.0` |

---

## 许可证状况

**HyperAudio 与 Mi17Audio 两个仓库均未包含 `LICENSE` / `COPYING` / `README` 中的许可声明**
（README 存在但未声明许可条款），即默认保留所有权利，未授予衍生作品的分发权。

本项目在原作许可明确之前，仅作**个人学习与自用**性质的修改。
若原作者对本项目的使用或分发有任何异议，请通过上述仓库的 issue 联系，我会立即处理或删除。

---

## 致谢

感谢 **HLMC Ray / Ray nakixii** 在 HyperOS 音频策略层做出的逆向与整理工作 ——
低延迟属性表、音频中间层遮蔽思路、以及守护进程方案，都是本项目得以成立的基础。
