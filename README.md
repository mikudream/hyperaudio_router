# HyperAudioRouter · hyperaudio

> HyperOS 按应用音频路由模块：**A 应用走 Dolby 效果链，B 应用保持低延迟通路，
> 其余应用完全交给系统。**
>
> 当前版本 **1.01**（首个公开版本）。模块 id `hyperaudio`。

## 这是什么

模块提供两份互相独立的按应用名单：

| 名单 | 存储 | 作用 | 名单外应用 |
|---|---|---|---|
| 音效链路 | `perapp.conf` | 名单内应用的音轨清掉 `FAST` 标志，回落到普通混音轨，经过 Dolby 效果链 | 不受影响 |
| 低延迟链路 | `lowlat.conf` 的 `whitelist` | 名单内应用放音时，其音频线程（以及当时被共享的 HAL/audioserver 线程）提为 `SCHED_FIFO` | 不参与调度 |

两条链路共同的设计原则：**名单之外，模块什么都不做；名单为空时对系统零改动。**

同一个包不会同时留在两个名单里：加入一边会自动从另一边移出，并回显 `moved_from=`。

完整说明见 [`docs/MODULE.md`](docs/MODULE.md)。

## 技术实现

1. **统一 Zygisk 负载**（`zygisk/arm64-v8a.so`，源码在 `payload/`）
   - 音效名单：hook `AudioTrack::createTrack_l`，在调用原函数前把
     `AudioTrack::mFlags`（`this + 0x3c0`）的 `AUDIO_OUTPUT_FLAG_FAST` 清掉。
   - 低延迟名单：patch `libaaudio_internal_builder/core/mmap.so` 的
     `strzcmp16` GOT 表项，让 AAudio 的 MMAP 白名单检查通过。
   - 名单外进程不安装任何 hook；不使用 Dobby，不加载 companion，不替换系统库。

2. **属性通道**
   `preAppSpecialize` 阶段读不到 `/data/adb`，所以名单由 root 侧发布到系统属性：
   `ha.perapp.app.0..7`（音效）与 `ha.mmap_gate.0..7`（低延迟）。
   `router.sh` 在名单增删时发布；`post-fs-data.sh` 与 `boot.sh` 在开机时发布。负载优先读文件，并合并属性。

3. **逐线程调度**（`bin/lowlat.sh`）
   daemon 每 5 秒读一次 `dumpsys media.audio_flinger`，只对 `whitelist` 内正在放音的
   应用提优先级；用 `chrt -f` 逐线程设置，回读 `/proc/<pid>/task/<tid>/stat` 校验，
   journal 记录原策略以便精确还原。名单内没有应用放音时，HAL/audioserver 的共享线程也不动。

4. **开机属性基线**
   `system.prop` 的音频/蓝牙/offload 调优是全局的，无法按应用拆分，属于所有应用共享的
   基础参数；其中 `aaudio.mmap_policy` / `aaudio.mmap_exclusive_policy` 保持 `1`（AUTO），
   不强制 MMAP，避免名单外应用也绕开普通混音轨。

### 明确不做的事

- 不替换 `libaaudio_internal*.so` 等系统库
- 不改写 `audio_module_config_primary.xml`，无端口补丁、无 bind mount
- 不重启 `audioserver`、不改运行期 `aaudio.*` 属性
- 不提供全局“音效模式”，没有模式切换
- 不做“只要在放音就提升”的全局调度

## WebUI

在 KernelSU / APatch 管理器内打开：

- **音效**：注入状态、音效名单增删
- **低延迟**：HAL / audioserver / 应用三档优先级、名单增删、实时调度状态
- **设置**：调音模块检测、界面外观
- **关于**：版本、维护者、许可与来源
- **Debug**：诊断采集与日志解读

后端统一走 `bin/webui.sh <action>`：参数校验 → `bin/ha.sh` 分发 → 输出包成
`rc=N|base64`（管理器的 `ksu.exec` 只回传最后一行 stdout）。

## 安装

1. 在 Magisk / KernelSU / APatch 管理器内安装 `hyperaudio_module.zip`
2. 安装脚本会检查管理器 busybox、提示与其它音频模块的冲突，并保留升级前的两份名单
3. 与全局版共用 id `hyperaudio`：直接安装会覆盖全局版，重启后生效
4. 启用模块并重启（Zygisk 负载需要重启后加载）

卸载：管理器内卸载即可。`uninstall.sh` 会先调用 `ha.sh stop` 还原已提升的线程策略，
再结束调度 daemon。

## 构建与测试

```powershell
# 1) 重新编译 zygisk 负载（需要 Android NDK r27）
powershell -NoProfile -ExecutionPolicy Bypass -File .\payload\build.ps1

# 2) 打模块 zip
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

`build.ps1` 是纯 ASCII（PowerShell 5.1 按 ANSI 解析无 BOM 文件，中文会炸）；
打包前会做四类检查：已知文件布局、无调音载荷、无机型检测、无上游作者署名。

主机测试覆盖：两份名单与互斥迁移、低延迟配置解析与保存、`ha.sh` 冒烟、
`system.prop` 去重与关键项、WebUI DOM 引用一致性、`webui.sh` 带参动作通配。
**它们不能替代真机验证。**

## 仓库结构

```
repo/
├── assets/           模块根目录脚本与配置（module.prop / customize.sh / system.prop …）
├── payload/          统一 zygisk 负载源码 + Zygisk API 头 + 构建脚本
├── zygisk/           构建产物 arm64-v8a.so（模块实际加载的文件）
├── webui/bin/        机上后端（router / lowlat / boot / diagnostics …）
├── webui/webroot/    WebUI（index.html + assets/26101606/* + router-ui.js）
├── prebuilt/         META-INF 安装入口
├── tests/            主机侧测试
├── docs/             模块说明、交接与设计文档
├── build.ps1         打包脚本
└── LICENSE           MIT（第三方许可见 CREDITS.md）
```

`webui/vendor-v3/` 是旧版 WebUI 的参考快照，不参与构建。

## 已知限制

- **只在一台设备上验证**：REDMI K90 Pro Max（myron）/ Android 17。
  `mFlags` 偏移 `0x3c0` 是该系统 `libaudioclient.so` 的布局；换机型/系统版本必须重新
  反汇编确认，不能直接套用。
- **`createTrack_l` 必须是导出符号**；不是导出符号的 ROM 上音效 hook 会失败。
- **MMAP 依赖 GOT 重定位表**：系统库被裁剪/加壳时 patch 会失败，低延迟名单退化。
- **听感回归已完成**：已在真机确认音效名单内的应用经过 Dolby 效果链，听感有效。
- **system.prop 是全局的**：无法按应用拆分。

## 来源与许可

- `DolbyRouter`（JEez6）：按应用路由思路参考 —
  https://github.com/JEez6/DolbyRouter
- `AAudio MMAP Hook`（HLMC）：AAudio MMAP 白名单绕过思路参考 —
  https://github.com/2278535805/zygisk-aaudio-mmap-hook
- `zygisk.hpp`：John "topjohnwu" Wu，ISC 风格许可（见头文件）

本项目代码以 MIT 许可发布，第三方组件保留各自许可；完整说明见 `CREDITS.md`。

## 免责声明

刷机有风险。因使用本模块导致的设备异常、数据丢失或保修失效，由使用者自行承担。
