# Changelog

## 1.02 — 可靠性修复

- 修复低延迟线程筛选调用已删除函数导致调度失效的问题。
- 名单操作、配置保存和属性发布使用共享事务锁与双缓冲快照。
- 统一 WebUI root 命令桥，验证并转义包名，避免重复执行写操作。
- 原生负载校验已适配系统库和调用位置，修复跳板分配和缓存同步问题。
- 修正 MMAP 策略值及名单变更需要重启应用的说明。
- 本版的原生负载与 MMAP 策略需要在目标设备重新验证。

## 1.01 — 首个公开版本（2026-11-04）

首个公开版本，面向 HyperOS / Android 17（REDMI K90 Pro Max / myron）验证。

### 功能

- **音效名单**：按应用 hook `AudioTrack::createTrack_l`，清 `FAST` 标志，使音轨回落
  普通混音轨，经过 Dolby 效果链。
- **低延迟名单**：按应用 patch AAudio `strzcmp16` GOT，使名单内应用通过 MMAP 白名单
  检查；同时由 daemon 用 `chrt -f` 提升放音线程优先级。
- **名单外零改动**；名单为空时对系统零改动；两份名单互斥。
- **WebUI**：音效/低延迟名单增删、三档优先级、实时调度状态与来源页。

### 实现

- 统一 Zygisk 负载（`payload/src/main.cpp`）：
  - `createTrack_l` inline hook（近地址 trampoline，按 `mFlags` 偏移清 FAST）
  - `libaaudio_internal_builder/core/mmap.so` 的 `strzcmp16` GOT patch
  - 不使用 Dobby / companion，不替换系统库
- 名单通过系统属性 `ha.perapp.app.*` / `ha.mmap_gate.*` 传给 app 进程；
  `router.sh` 在增删时发布，`boot.sh` 在开机时发布。
- 低延迟 daemon 每 5 秒读 `dumpsys media.audio_flinger`，只处理名单内应用，
  journal 记录并精确还原线程策略。

### 已知限制

- 仅在 REDMI K90 Pro Max / Android 17 上验证；`mFlags` 偏移 `0x3c0` 不可直接移植。
- `createTrack_l` 必须是导出符号；MMAP GOT patch 依赖系统库重定位表。
- 听感回归已完成：真机确认音效名单内的应用经过 Dolby 效果链，听感有效。
