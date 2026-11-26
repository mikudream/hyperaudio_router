# Unified Zygisk payload (source)

`src/main.cpp` 是 `zygisk/arm64-v8a.so` 的完整源码；`include/zygisk.hpp` 是
Zygisk 官方模块 API（John "topjohnwu" Wu，ISC 许可）。

## 做什么

- **音效名单**：在名单内应用进程里 hook `AudioTrack::createTrack_l`，调用原函数前
  把 `AudioTrack::mFlags` 的 `AUDIO_OUTPUT_FLAG_FAST` 清掉（`this + 0x3c0`），
  让音轨回落到普通混音轨，经过 Dolby 效果链。
- **低延迟名单**：在名单内应用进程里 patch 已校验的 AAudio builder 库的
  `strzcmp16` GOT 表项，针对已验证的白名单比较放行，其他调用转发给原函数。
- **名单外**：不安装任何 hook。

## 名单从哪来

root 侧由 `router.sh` 在名单修改和系统启动完成后发布属性快照。每份名单使用双缓冲属性组，发布完成并核对后切换代际。

负载在目标进程创建时读取配置文件，文件不可读时读取属性快照。名单变更后需要重启目标应用。

## 构建

```powershell
powershell -ExecutionPolicy Bypass -File .\payload\build.ps1
```

需要 Android NDK r27，或设置 `ANDROID_NDK_HOME`。产物写到 `zygisk/arm64-v8a.so`，
再由仓库根目录的 `build.ps1` 打进模块 zip。

## 兼容性

- 仅在 REDMI K90 Pro Max（myron）/ Android 17 上验证
- 负载校验已验证系统库的 Build ID、函数入口与调用位置，校验失败时跳过对应 hook
- `mFlags` 偏移 `0x3c0` 与已验证系统库绑定，OTA 后可能需要重新适配
- `createTrack_l` 需要是导出符号，AAudio patch 依赖 builder 库的重定位表
- 不替换任何系统库，也不使用 Dobby / companion
