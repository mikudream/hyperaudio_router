# HyperAudioRouter · hyperaudio

> HyperOS 音频模块。**同一台设备上，A 应用走 Dolby 效果链，B 应用保持低延迟通路，
> 其余应用完全交给系统。**
>
> 当前版本见 `module.prop`（2.2.2）。通用版（全局切换原生/音效）在同一仓库的 `main` 分支。

## 这是什么

模块提供两份互相独立的按应用名单：

| 名单 | 存储 | 作用 | 名单外应用 |
|---|---|---|---|
| 音效链路 | `perapp.conf` | 名单内应用的音轨被剥掉 `FAST\|PRIMARY`，回落到普通混音轨，经过 Dolby 效果链 | 不受影响 |
| 低延迟链路 | `lowlat.conf` 的 `whitelist` | 名单内应用放音时，其音频线程（以及当时共享的 HAL/audioserver 线程）被提为 `SCHED_FIFO` | 不参与调度 |

两条链路的共同设计原则：**名单之外，模块什么都不做**。名单为空时对系统零改动。

同一包不会同时留在两个名单里：加入一边会自动从另一边移出，并回显 `moved_from=`。

## 技术实现

模块只做三件事，全部可按进程或按名单收敛边界：

1. **进程内 hook（音效）**
   zygisk 负载 `zygisk/arm64-v8a.so` 在目标进程内 hook `AudioTrack::createTrack_l`，
   去掉 `FAST | PRIMARY` 标志。配置以 `perapp.conf` 为准，并**双写**到
   `/data/adb/modules/dolbyrouter/perapp.conf`（负载的配置路径是编译期写死的）。
   `mFlags` 偏移已按本机从 `0x378` 重定位到 `0x3c0`。

2. **逐线程调度（低延迟）**
   `bin/lowlat.sh` 的 daemon 每 5 秒读一次 `dumpsys media.audio_flinger`，只对
   `whitelist` 内正在放音的应用提优先级；用 `chrt -f` 逐线程设置，并回读
   `/proc/<pid>/task/<tid>/stat` 校验，journal 记录原策略以便精确还原。
   名单内没有应用在放音时，**HAL/audioserver 的共享线程也不会被改动**。

3. **开机属性基线（全局）**
   `system.prop` 的音频/蓝牙/offload 调优在开机时由管理器统一注入。这些属性作用于
   整个系统、无法按应用拆分，属于"所有应用共享的基础调优"，与两份名单无关。
   其中 `aaudio.mmap_policy` / `aaudio.mmap_exclusive_policy` 保持 `1`（AUTO），
   不用 `2`（ALWAYS）——强制 MMAP 会让名单外应用也绕开普通混音轨。

### 明确不做的事

- ❌ 不改写 `audio_module_config_primary.xml`（无 bind mount、无端口补丁）
- ❌ 不替换 `libaaudio_internal.so` 等系统库
- ❌ 不提供全局"音效模式"，也没有模式切换与开机模式
- ❌ 不重启 `audioserver`、不改 `aaudio.*` 运行期属性
- ❌ 不做"只要在放音就提升"的全局调度

因此模块没有事务回滚、挂载所有权校验那套机制——因为根本没有需要回滚的全局改写。

## WebUI

在 KernelSU / APatch 管理器内打开。四个页面 + 一个调试视图：

- **音效**：音效链路总开关、注入状态（负载 / companion）、名单增删
- **低延迟**：调度开关、HAL / audioserver / 应用三档优先级、名单增删、实时调度状态
- **设置**：调音模块检测、界面与底栏外观
- **关于**：项目信息、许可与来源
- **Debug**（设置 → 诊断打开）：诊断采集、日志解读、技术信息

后端统一走 `bin/webui.sh <action>`：参数校验 → `bin/ha.sh` 分发 → 输出包成
`rc=N|base64`，因为管理器的 `ksu.exec` 只回传最后一行 stdout。

## 配置文件

`perapp.conf`（模块根目录）：

```
enabled=1
app=com.example.game
app=com.example.video
```

`lowlat.conf`（模块根目录）：

```
enabled=1
only_whitelist=1
hal_priority=20
audio_priority=16
app_priority=15
whitelist=com.example.game,com.example.music
revision=...
```

`whitelist` 是逗号分隔的包名；`only_whitelist` 恒为 1（应用版只有按名单一种语义）。

## 后端接口

```
status            只读汇总（低延迟开关、名单规模、audioserver）
router-status     两份名单 + 负载/companion 状态
perapp-add/del    维护音效名单（自动从低延迟名单移出）
perapp-enable     音效链路总开关
wl-add/del        维护低延迟名单（自动从音效名单移出）
ll-save           保存 enabled + 三档优先级（白名单由 wl-* 维护，保存时原样保留）
ll-status         低延迟配置 + daemon 心跳 + 最近一次调度证据
boot / stop       开机收尾 / 卸载前还原线程策略
```

## 安装

1. 把 `hyperaudio_module.zip` 安装到 Magisk / KernelSU / APatch（管理器内安装，不支持 recovery）
2. 安装脚本会检查管理器 busybox、提示与其它音频模块的冲突，并保留升级前的两份名单
3. **与全局版共用 id `hyperaudio`**：直接安装会覆盖全局版，重启后生效（旧版的端口挂载与
   运行期属性在重启后不复存在，覆盖是安全的）；若装有上游 `hyperaudio_compat` 只提示冲突
4. 启用模块并重启（zygisk 负载需要重启后才加载）

### 卸载

管理器内卸载即可。`uninstall.sh` 会先调用 `ha.sh stop`：把已提升的线程还原为原策略，
再结束调度 daemon，避免卸载后残留 `SCHED_FIFO` 线程。

## 构建与测试

```powershell
cd D:\DSH\HyperAudioRouter\repo
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1

# 主机侧测试（不随模块分发）
& 'D:\App\Git\bin\bash.exe' -lc "cd /d/DSH/HyperAudioRouter/repo && sh tests/run.sh"
```

`build.ps1` 是纯 ASCII（PowerShell 5.1 按 ANSI 解析无 BOM 文件，中文会炸）；
打包前会做四类检查：只允许已知文件布局、禁止调音载荷、禁止机型检测、禁止上游作者署名。

主机测试覆盖：`router.sh` 的两份名单与互斥迁移、`lowlat.sh` 的白名单配置解析与保存、
`ha.sh` 桩环境冒烟、`system.prop` 去重与关键项、WebUI 的 DOM 引用一致性。
**它们不能替代真机验证**（线程提权、zygisk 注入、Dolby 是否真的生效都只能在设备上验）。

## 仓库结构

```
repo/
├── assets/           模块根目录脚本与配置（module.prop / customize.sh / service.sh / system.prop …）
├── webui/bin/        机上后端（ha / runtime / lowlat / router / diagnostics / debug …）
├── webui/webroot/    WebUI（index.html + assets/26101606/* + router-ui.js）
├── zygisk/           zygisk 负载与 mFlags 偏移工具
├── prebuilt/         上游预编译件（当前仅用 META-INF 安装入口）
├── tests/            主机侧测试
├── docs/             设计与交接文档
└── build.ps1         构建脚本
```

`webui/vendor-v3/` 是 v3.0 原版 WebUI 的参考快照，不参与构建。

## 已知限制

- **zygisk 偏移写死**：`0x3c0` 只对当前系统版本有效；系统更新后需用
  `zygisk/patch_mflags_offset.py` 重新定位，否则 hook 会失败（表现为音效名单无效）。
- **音效依赖 companion**：`perapp.conf` 必须能被 DolbyRouter 的 companion 读到；
  没有 companion 时音效名单不会生效，WebUI 会显示"负载就绪，进程未启动"。
- **system.prop 是全局的**：无法按应用拆分，所有应用共享同一套参数基线。
- **真机验证有限**：2.2.2 的改动经过主机测试与构建校验，但尚未做完整真机回归。

## 来源与致谢

技术基底来自 [HyperAudio](https://github.com/2278535805/HyperAudio)（作者 HLMC Ray）与
[Mi17Audio](https://github.com/Mi17Audio)；按应用 hook 来自 DolbyRouter。
完整来源、许可与改动说明见 `CREDITS.md`。

## 免责声明

刷机有风险。因使用本模块导致的设备异常、数据丢失或保修失效，由使用者自行承担。
