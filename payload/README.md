# Unified Zygisk payload (source)

`src/main.cpp` 是 `zygisk/arm64-v8a.so` 的完整源码；`include/zygisk.hpp` 是
Zygisk 官方模块 API（John "topjohnwu" Wu，ISC 许可）。

## 做什么

- **音效名单**：在名单内应用进程里 hook `AudioTrack::createTrack_l`，调用原函数前
  把 `AudioTrack::mFlags` 的 `AUDIO_OUTPUT_FLAG_FAST` 清掉（`this + 0x3c0`），
  让音轨回落到普通混音轨，经过 Dolby 效果链。
- **低延迟名单**：在名单内应用进程里 patch `libaaudio_internal_builder/core/mmap.so`
  的 `strzcmp16` GOT 表项，使 AAudio 的 MMAP 白名单检查通过。
- **名单外**：不安装任何 hook。

## 名单从哪来

`preAppSpecialize` 阶段读不到 `/data/adb`，所以名单由 root 侧的
`webui/bin/router.sh` / `boot.sh` 发布到系统属性：

- `ha.perapp.app.0..7`：音效名单
- `ha.mmap_gate.0..7`：低延迟名单

负载优先尝试读 `perapp.conf` / `lowlat.conf` 文件，读不到再回退到属性。

## 构建

```powershell
powershell -ExecutionPolicy Bypass -File .\payload\build.ps1
```

需要 Android NDK r27，或设置 `ANDROID_NDK_HOME`。产物写到 `zygisk/arm64-v8a.so`，
再由仓库根目录的 `build.ps1` 打进模块 zip。

## 兼容性

- 仅在 REDMI K90 Pro Max（myron）/ Android 17 上验证
- `mFlags` 偏移 `0x3c0` 是这台机器 `libaudioclient.so` 的布局；换机型/系统版本
  必须重新反汇编确认，不能直接套用
- `createTrack_l` 需要是导出符号；不是导出符号的 ROM 上音效 hook 会失败
- `strzcmp16` GOT patch 依赖 `libaaudio_internal_*.so` 的 ELF 重定位表
- 不替换任何系统库，也不使用 Dobby / companion
