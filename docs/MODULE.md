# HyperAudioRouter 模块说明

> 版本 **2.2.7**（首个公开版本） · 模块 id `hyperaudio` · 作者：月见里幽瞳 / deepseek-flash

## 1. 概览

HyperAudioRouter 是一个面向 HyperOS / Android 的**按应用音频路由**模块。它维护两份
互相独立的名单：

| 名单 | 作用 | 典型用途 |
|---|---|---|
| **音效名单** | 名单内应用的音轨清掉 `FAST` 标志，回落普通混音轨，经过 Dolby 效果链 | 音乐、视频、需要调音的游戏 |
| **低延迟名单** | 名单内应用放音时，其音频线程（及当时共享的 HAL/audioserver 线程）提为 `SCHED_FIFO` | 音游、FPS、对延迟敏感的应用 |

**名单之外，模块什么都不做；两份名单都为空时，对系统零改动。**

同一个包不会同时留在两个名单里：加入一边会自动从另一边移出。

---

## 2. 工作原理

### 2.1 统一 Zygisk 负载

`zygisk/arm64-v8a.so`（源码 `payload/src/main.cpp`）由 Zygisk Next 在 app 进程内加载：

- **音效**：`dlsym` 找到导出的 `AudioTrack::createTrack_l`，在目标 ±120MB 内分配
  trampoline，把入口改成直接跳转；包装函数在**调用原函数前**清掉
  `AudioTrack::mFlags`（`this + 0x3c0`）的 `AUDIO_OUTPUT_FLAG_FAST`。
- **低延迟**：解析 `libaaudio_internal_builder/core/mmap.so` 的 ELF 重定位表，把
  `strzcmp16` 的 GOT 表项指向本模块实现；当比较对象是 AOSP 的 5 个白名单包名之一时
  返回 0，使 AAudio 的 MMAP 白名单检查通过。
- 名单外进程不 patch、不 hook；不使用 Dobby、companion，不替换系统库。

### 2.2 名单 → 系统属性

`preAppSpecialize` 阶段读不到 `/data/adb`，因此名单由 root 侧发布到系统属性：

```
ha.perapp.app.0..7     音效名单（每项最多 80 字符，逗号分隔）
ha.mmap_gate.0..7      低延迟名单
```

- `webui/bin/router.sh` 在 `perapp-add/del`、`wl-add/del` 后立即发布
- `assets/post-fs-data.sh` 与 `webui/bin/boot.sh` 在开机时发布
- 负载优先读 `perapp.conf` / `lowlat.conf` 文件，读不到再回退到属性

### 2.3 低延迟 daemon

`bin/lowlat.sh` 的 daemon 每 5 秒执行一次：

1. `dumpsys media.audio_flinger` 取出正在放音的应用与线程
2. 只保留 `lowlat.conf` 的 `whitelist` 内应用
3. 用 `chrt -f` 逐线程设置优先级，回读 `/proc/<pid>/task/<tid>/stat` 校验
4. journal 记录原策略，名单移出/停止放音/卸载时精确还原

名单内没有应用放音时，HAL/audioserver 的共享线程不会被改动。

### 2.4 全局属性基线

`system.prop` 的音频/蓝牙/offload 调优在开机时由管理器注入，作用于整个系统，无法按
应用拆分；其中 `aaudio.mmap_policy` / `aaudio.mmap_exclusive_policy` 保持 `1`（AUTO），
不强制 MMAP，避免名单外应用也绕开普通混音轨。

---

## 3. 安装

1. 在 Magisk / KernelSU / APatch 管理器内安装 `hyperaudio_module.zip`
2. 安装脚本检查管理器 busybox，提示与其它音频模块的冲突，并保留升级前的两份名单
3. 与全局版共用 id `hyperaudio`：直接安装会覆盖全局版，重启后生效
4. 启用模块并重启（Zygisk 负载需要重启后加载）

### 卸载

管理器内卸载即可。`uninstall.sh` 会先调用 `ha.sh stop` 还原线程策略，再结束 daemon。

---

## 4. 使用

打开管理器内的模块 WebUI：

- **音效**：查看注入状态；输入包名点“添加”即加入音效名单
- **低延迟**：调整 HAL / audioserver / 应用三档优先级；增删低延迟名单；查看实时调度状态
- **设置**：调音模块检测、界面外观
- **关于**：版本、维护者、许可与来源
- **Debug**：诊断采集与日志解读

没有总开关：**加入名单即生效，移出即恢复**。

### 配置文件

`perapp.conf`：

```
enabled=1
app=com.example.game
app=com.example.video
```

`lowlat.conf`：

```
hal_priority=20
audio_priority=16
app_priority=15
whitelist=com.example.game,com.example.music
revision=...
```

`enabled` 仅为兼容旧版读取，恒为 1；旧字段 `enabled` / `only_whitelist` 不再有开关含义。

---

## 5. 兼容性与限制

- **验证设备**：REDMI K90 Pro Max（myron）/ Android 17 / arm64。
- **`mFlags` 偏移 `0x3c0` 是按本机 `libaudioclient.so` 反汇编得到的**；换机型或系统
  版本必须重新确认，不能直接套用。偏移错误可能导致音效名单无效，甚至破坏 `AudioTrack`。
- **`createTrack_l` 必须是导出符号**；否则音效 hook 安装失败（低延迟链路不受影响）。
- **MMAP GOT patch 依赖 `libaaudio_internal_*.so` 的 ELF 重定位表**；系统库被裁剪或
  加壳时 patch 会失败，低延迟名单退化为仅 chrt 调度。
- **听感回归未完成**：本机 AudioProbe 开/关 hook 都落到 SPATIALIZER 线程；已确认
  `mFlags 0x4 → 0x0`，但 Dolby 路由的听感差异仍需真实应用试听确认。
- **system.prop 是全局的**，不能按应用拆分。
- 不要与其它会改写音频策略/端口/AAudio 库的模块同时使用。

---

## 6. 仓库结构

```
assets/          模块根目录脚本与配置
payload/         统一 zygisk 负载源码 + Zygisk API 头 + 构建脚本
zygisk/          构建产物 arm64-v8a.so
webui/bin/       机上后端（router / lowlat / boot / diagnostics）
webui/webroot/   WebUI
prebuilt/        META-INF 安装入口
tests/           主机侧测试
docs/            模块说明 / 交接 / 设计文档
build.ps1        打包脚本
```

---

## 7. 构建与测试

```powershell
# 编译负载（需要 Android NDK r27）
powershell -ExecutionPolicy Bypass -File .\payload\build.ps1

# 打 zip
powershell -ExecutionPolicy Bypass -File .\build.ps1

# 主机测试
& 'D:\App\Git\bin\bash.exe' -lc "cd /d/DSH/HyperAudioRouter/repo && sh tests/run.sh"
```

`build.ps1` 会做四类打包前检查：已知文件布局、无调音载荷、无机型检测、无上游作者署名。
主机测试覆盖名单互斥、低延迟配置、`ha.sh` 冒烟、`system.prop`、WebUI DOM 引用、
`webui.sh` 带参动作通配；不能替代真机验证。

---

## 8. 常见问题

**WebUI 显示“缺少负载文件”**
确认 `zygisk/arm64-v8a.so` 存在、Zygisk Next 已启用，并重启过。

**加入音效名单没效果**
先确认 `createTrack_l` 是导出符号、`mFlags` 偏移匹配当前系统；Debug 页看诊断。
本机可用 `logcat -s AAudioMmapGate` 看 `createTrack_l hooked` 与 `mFlags before/after`。

**加入低延迟名单没效果**
确认应用确实在放音、`lowlat.conf` 的 `whitelist` 包含它；Debug 页看 `ll_status`
的 `ll_verified` / `ll_state`。

**重启后名单还在吗**
在。名单写在模块目录的 `perapp.conf` / `lowlat.conf`，属性在开机时重新发布。

---

## 9. 来源与许可

- [DolbyRouter](https://github.com/JEez6/DolbyRouter)（JEez6）：按应用路由思路参考
- [AAudio MMAP Hook](https://github.com/2278535805/zygisk-aaudio-mmap-hook)（HLMC）：
  AAudio MMAP 白名单绕过思路参考
- `payload/include/zygisk.hpp`：John "topjohnwu" Wu，ISC 风格许可

本项目代码以 MIT 许可发布；完整第三方许可见 `CREDITS.md` 与 `LICENSE`。
