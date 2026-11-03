# 全局版 2.0.0 代码审查记录

审查对象：`main` 分支（基于 HyperAudio Switch 3.0 前后端重构的通用版）。
方法：静态通读 + 调用链核对 + 打包产物校验 + 主机测试。**不含真机行为验证**（设备离线）。

## 1. 结构

```
service.sh ──► bin/ha.sh boot ─────► boot.sh / runtime.sh / lowlat.sh
action.sh  ──► bin/ha.sh cycle ────► runtime.sh
webroot/   ──► bin/webui.sh ───────► bin/ha.sh <action>
```

`ha.sh` 在启动时做的事（顺序有意义）：

| 行 | 动作 |
|---|---|
| 4–11 | 必须 re-exec 管理器自带 busybox；找不到即 `error=manager_busybox_missing` |
| 28–34 | source `runtime.sh`、`diagnostics.sh`、`sampling.sh`、`lowlat.sh`、`debug.sh`、`theme.sh`、`fonts.sh` |
| 235–237（runtime 内） | source `sound.sh`、`boot.sh`、`audio_ready.sh` |

已核对：`sound.sh` / `boot.sh` 虽未在 `ha.sh` 里直接 source，但由 `runtime.sh` 末尾加载，
而 `runtime.sh` 是第一个被 source 的文件，因此 `ha.sh` 分发到 `sound-status`、`boot-status`
时函数已存在 —— 不存在"函数未定义"的隐患。

## 2. 依赖

| 依赖 | 位置 | 缺失后果 |
|---|---|---|
| 管理器 busybox | `ha.sh:4-11`（`/data/adb/ksu/bin/busybox` / `magisk/`）| 所有动作返回 `manager_busybox_missing` |
| root | `ha.sh`（`id -u`）| `error=root_required` |
| `resetprop` | `runtime.sh:20-31`，含 magisk applet 兜底 | MMAP 属性无法读写，音效模式切换失败 |
| `chrt` | `lowlat.sh:73-77` | 调度优化失败，`details` 记 `denied` |

## 3. 前后端契约一致性（本次重点核对）

UI 实际会发送的动作（从 `app.js` 提取）：

```
status  ll-status  sound-status  diag-status  tuning  theme
apply native|sound   boot-save native|sound
ll-save ENABLE HAL AUDIO APP      sound-save CUSTOM MMAP FAST FAST_RAW RAW
diagnose  schedule-diagnose PKG   debug-summary  debug-reports  debug-analyze NAME
```

`bin/webui.sh` 的白名单覆盖了上述全部动作。两处需要说明：

- `apply compat` 不在白名单，但界面没有 compat 入口（`compat` 只用于把状态映射成中文标签），
  因此不构成功能缺失；
- `ll-status` 额外放行了可变参数长度检查（读取类动作允许无参）。

## 4. 本次修复

### 4.1 白名单移除后的连锁一致性

删除"低延迟白名单"后，以下位置必须同步，否则会出现"保存无效但界面无提示"：

| 位置 | 原状 | 现状 |
|---|---|---|
| `lowlat.sh` `ll_valid` | 6 参 + 白名单校验 | **4 参**（enabled + hal + audio + app） |
| `lowlat.sh` `ll_save` | 写 `only_whitelist` / `whitelist` | 只写 5 个键 |
| `lowlat.sh` `ll_status` | 输出 7 个字段 | 输出 5 个字段 |
| `lowlat.sh` `ll_targets` | 按白名单过滤应用 | 不再过滤 |
| `boot.sh` `recover_native` | `ll_save 0 "$LL_ONLY" ...` | `ll_save 0 "$LL_HAL" "$LL_AUDIO" "$LL_APP"` |
| `webui.sh` | `ll-save` 要求 7 个参数 | 要求 **5 个**（动作 + 4 个数值） |
| `ha.sh` usage | `ll-save ENABLE ONLY HAL AUDIO APP CSV` | `ll-save ENABLE HAL AUDIO APP` |
| `lowlat.conf` | 7 行 | 5 行 |
| `index.html` / `app.js` | 开关 + 白名单折叠块 + 增删逻辑 | 全部移除 |

### 4.2 遗留载荷（本次审查新发现）

`bin/` 全目录**从未引用** `hyper-audio` 与 `config.toml`——那是旧架构（Rust 守护进程）的产物，
v3.0 版改用 `chrt` 逐线程调度。它们仍在打包，属于纯粹的体量浪费与阅读干扰。

- 停止打包后：**1,187,873 → 381,329 字节**（减少约 800 KB）
- `config.toml` 的作者标识清理、`hyper-audio` 的二进制串替换代码一并成为死代码，
  已在 `build.ps1` 中移除，并保留 `$bin` 变量定义以免影响二进制扫描

### 4.3 无效属性值

`assets/system.prop` 中：

```
aaudio.mmap_exclusive_policy=3
```

AOSP 中该属性取值域为 `0=NEVER / 1=AUTO / 2=ALWAYS`，**3 越界**（会被忽略或行为未定义）。
已改为 `2`（ALWAYS），与上一行 `aaudio.mmap_policy=2` 保持一致。

### 4.4 文档

`README.md` 中仍描述旧实现的段落已更新：模式表、参数说明、仓库结构树、卸载流程、
致谢中的继承清单、"不得含原作者标识"的扫描范围。

## 5. 未决问题（需真机或上游决策）

### 5.1 `disable_mmap()` 名与实不符（语义存疑）

```sh
disable_mmap() {
    for P in $PROPS; do rp -n "$P" 1 || return 1; done
}
```

函数名与 UI 文案都是"关闭 MMAP 直通"，但写入的是 **1 = AUTO**（允许），而"关闭"应为 0 (NEVER)。
两种可能：上游对属性语义的理解不同，或这只是一个"恢复自动"的动作。
**无法在离线状态判定**，需要在设备上对比 `AudioMmapOut` 线程数量变化。

### 5.2 `system.prop` 与 `sound.sh` 对同一属性的方向相反

- 开机：`system.prop` 把 `aaudio.mmap_policy` 设为 **2 (ALWAYS)**
- 切入音效模式：`resetprop` 改为 **1 (AUTO)**
- 切回原生：`restore_props` 恢复为开机捕获值 **2**

逻辑自洽（因为原值被保存），但一开机就强制 ALWAYS 与"音效模式下想减少 MMAP"的意图相反。
是否保留 `system.prop` 里的这两行，建议真机 A/B 后再定。

### 5.3 应用版仍带 v3.0 的"模式"页

应用版（`hyperaudio_router`）沿用同一套前端，仍可在那里切到音效模式，
与其"固定低延迟"的定位冲突。已记录在 `docs/ROUTER-NOTES.md`，尚未实施修法。

### 5.4 从未真机验证

以上结论全部来自静态分析。`ha.sh` 的启动链路（busybox → root → source → 事件）
在本机无法完整模拟，必须实机确认。

## 6. 静态验证结果

| 项目 | 结果 |
|---|---|
| 全部 shell / awk 语法（`sh -n`） | 通过 |
| `app.js` 语法（`node --check`） | 通过 |
| 主机测试 `tests/run.sh`（11 节） | 全部通过 |
| 包内 `$MODDIR/...` 引用完整性 | 通过 |
| webroot 内前端资源引用 | 20 条，无缺失 |
| CRLF / shebang | 通过 |
| 包内 `whitelist` 字样 | 无 |
| 包内 `hyper-audio` / `config.toml` | 无（本次移除） |
| 构建条目 | 76 项 |

## 7. 真机验证结果（2026-11-03，Android 17 / KSU-Next）

安装方式：`ksud module install` → 重启生效。以下均为设备实测输出。

### 7.1 首轮发现的致命缺陷（已修）

`runtime.sh` 第 168 行有一处针对"旧版模块并存"的拦截：

```sh
[ -d /data/adb/modules/hyperaudio ] && { err old_hyperaudio_still_installed; return 1; }
```

v3.0 原本检查的是旧 id（`hyperaudio_compat`）。把模块 id 统一为 `hyperaudio` 后，
这条检查**指向模块自身**，于是每次 `apply` 都直接失败：开机日志报
`error=old_hyperaudio_still_installed`，`boot_guard=startup_apply_failed`、
`boot_result=failed`，音效模式完全不可用。

已删除该检查。修复后开机：`boot_guard=none`、`boot_result=native`、`ok=1`。

### 7.2 模式切换（实测通过）

| 阶段 | low_latency_out | raw_out | MMAP 属性 |
|---|---|---|---|
| 原生 | 0x0006 (PRIMARY+FAST) | 0x0104 (FAST+RAW) | 2 / 2 |
| 音效 | 0x0002 (PRIMARY) | 0x0000 (NONE) | 1 / 1 |
| 切回原生 | 0x0006 | 0x0104 | 2 / 2（已还原） |

`state/owned` 在切回原生后被清理，bind 挂载无残留。

### 7.3 低延迟调度（实测通过）

开启（`ll-save 1 20 16 15`）后播放网易云音乐：

```
ll_state=verified  ll_verified=14  ll_failed=0
ll_hal=1  ll_audio=10  ll_app=3   ll_packages=com.netease.cloudmusic
verified tid=30265 group=hal   requested=20 actual=FIFO/20
verified tid=31885 group=app   requested=15 actual=FIFO/15
verified tid=28954 group=audio requested=16 actual=FIFO/16
```

关闭后 `owned` 归零、`DAP_offloadV3` 回到 `SCHED_OTHER`，还原路径干净。
（`FastMixer` / `AudioOut_D` 仍为 FIFO，那是 AudioFlinger 自设的实时线程，本模块未争抢。）

### 7.4 由此发现并修复的第二个问题

初版 `ll_hal=0`：本机 HAL 线程名统一是 `audiohalservice`，不含端口名，
因此原有 `low_latency*|raw_out*|mmap_no_irq*|deep_buffer*` 规则一个都匹配不到。
实际承担播放的是 `DAP_offloadV3`（杜比 offload 线程）。

已把 `AudioOut_*|AudioIn_*|out_*|agm_*|DAP*` 纳入 HAL 组匹配。修复后 `ll_hal=1`，
`DAP_offloadV3` 被提到 `FIFO/20`。

### 7.5 仍未验证

- `audio_ready_check=unverified`：就绪判定依赖重启后的框架回读证据，本次未取得
- `disable_mmap` 的真实效果（属性 2→1 已确认写入，但是否真的减少了 MMAP 通路未验证）
