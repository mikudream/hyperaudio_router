# 与 HyperAudio Switch v3.0 的离线对比记录

在没有实机的情况下，把本模块（`main` 通用版 / `feature/perapp` 整合版）与
HyperAudio Switch v3.0（`hyperaudio_compat` 3.0，26101606）逐项对比，
只落地**主机侧可验证**的改进；凡涉及挂载时序、音频策略、真实 dumpsys 格式的改动，
一律不动，留待有设备时验证。

## 1. 文件层面的差异

v3.0 是一套更完整的工具箱（78 个文件），本模块是单一功能模块。对照如下：

| v3.0 有 | 本模块 | 结论 |
|---|---|---|
| `bin/diagnostics.sh`（10.5KB，采集 dumpsys 打包） | 无 | **已补**：`bin/diagnose.sh`，更轻的只读报告 |
| `bin/debug.sh`（10KB 调试面板） | 无 | 不补。与 `diagnose.sh` 职责重叠，且需要实机验证 |
| `bin/lowlat.sh` / `sound.sh` / `ha.sh`（模式分文件） | 单个 `runtime.sh` | 不采纳。单文件事务更不容易出现中间态 |
| `bin/sampling.sh` / `fonts.sh` / `theme.sh` | 无 | 不采纳，与本模块目标无关 |
| `bin/analyze_flinger.awk` / `active_clients.awk` | 无 | 暂不采纳。当前只需"就绪与否"，不需要逐轨分析 |
| `NOTICE` / `README_zh.md` / `docs/` | `README.md` / `CREDITS.md` | 结构不同，不强行对齐 |
| `skip_mount`（空文件） | 无（且**不能**有） | 我们需要管理器自动挂载 `system/lib64/` 下的库 |
| `action.sh` 友好错误映射 | 已有，且更细 | 补了一处"就绪结论"（见下） |

## 2. 已落地的三项改进

### 2.1 只读诊断导出（`bin/diagnose.sh`）

v3.0 的 diagnostics 打包 dumpsys；本模块改成一份**人能直接读**的文本报告：
模块状态 / 挂载层 / 端口 flags / runtime status / 音频就绪（期望·观测·pid）/
音频策略与混音线程摘要 / 调音来源 / 配置与白名单（脱敏）/ 日志尾部。

- 全程只读（测试用"跑完前后文件快照必须一致"锁住）
- 缺段时显式打印 `(缺失)` / `(无 dumpsys)`，绝不静默留空
- `--save` 依次回退 `/sdcard/Download` → `/storage/emulated/0/Download` → `/data/local/tmp`
- 支持 `HA_DIAG_DEST` 指定目录（测试与设备都可用）

### 2.2 `action.sh` 不再一律报"已生效"

原先只看模式文件写没写对就宣布成功。现在解析 `runtime.sh` 的 `audio_ready`：

| 值 | 文案 |
|---|---|
| `passed` | 音频框架：已确认加载当前配置 |
| `failed` / `timeout` | 校验未通过，模式已保留，原因见 WebUI |
| 其它 / 缺失 | 未能确认，配置已写入但不能断言已生效 |

### 2.3 `uninstall.sh` 失败要透传

原先 recover 失败也只是"提醒一句 + `exit 0`"。现在捕获退出码，失败时打印
`清理未完全成功（recover 退出码 N）`、提示重启确认，并以非零退出。
同时显式清 `perapp.conf` 与 `logs/`。

## 3. 可测试性修复

`action.sh` / `uninstall.sh` 原先硬编码 `SH=/system/bin/sh`，主机上无法测试
（所有调用都是 127）。改为 `SH=${HA_SH:-/system/bin/sh}`，与 `runtime.sh` 的
`HA_SH` 约定一致；`uninstall.sh` 也支持 `HA_MOD` 覆盖。

## 4. 测试现状

`sh tests/run.sh` 共 8 节、83 项断言全部通过：

| 节 | 内容 |
|---|---|
| 1 | `patch_ports.awk` 改写与 fail-closed |
| 2 | `report_flags` 位掩码、真实 dumpsys 形状、无法识别/主输出缺失 |
| 3 | `runtime.sh` 状态机（事务/回滚/护栏/挂载归属/就绪，68 项）|
| 4 | `save` 严格校验 |
| 5 | 反复保存不增长 |
| 6 | 诊断导出：只读性/结构/落盘（28 项）|
| 7 | 配置文件不因反复保存而增长 |
| 8 | 动作按钮与卸载：就绪结论/失败原因/退出码（26 项）|

## 5. 明确**没有**做的事（需要实机）

1. **AAudio-MMAP 应用的 DAP 覆盖**：本机 MMAP 由 MI 音频栈决定，
   `resetprop aaudio.mmap_policy 0` + 重启 audioserver 实测无效，
   现有 hook 也不生效。要动它必须 patch `libaaudio_internal_mmap.so`/`_builder.so`。
2. **`feature/perapp` 的整合版从未在设备上安装过**：需要先删独立 `dolbyrouter`
   模块，再刷包重启，并用 AudioProbe 后端 3/8 验证回落 + `DAP_offload`。
3. **v3.0 的滚动工具栏、主题切换、浮动导航**：都需要改 `app.js` 加新逻辑，
   当前 UI 只做了布局与视觉对齐，没引入这些交互。
4. **`analyze_flinger.awk` 式的逐轨分析**：等有需要时再说。

## 6. 遗留问题

- 上游 DolbyRouter 的 zip 包是坏的：`customize.sh` 里 `SKIPUNZIP=1` 却只解压
  `zygisk/*`，导致装完没有 `module.prop`，模块列表里不出现。
  若要分发上游包，需要在 `customize.sh` 里补
  `unzip -o "$ZIPFILE" 'module.prop' 'customize.sh' 'perapp.conf' -d "$MODPATH"`。
- 上游 DolbyRouter 无 LICENSE（README 仅写"仅供学习研究"）。
  `feature/perapp` 把它的二进制随模块分发，属再分发行为：仓库私有可用，
  公开分发前需取得作者许可。
