# 应用版（HyperAudio Router）说明与已知问题

本文件记录应用版相对通用版的差异，以及当前实现里**已知未处理**的点。
写下来是为了避免以后在真机上遇到时重新排查。

## 1. 定位差异

| | 通用版（main） | 应用版（router） |
|---|---|---|
| 工作模式 | 原生 / 音效 可切换 | **固定低延迟**，不提供模式切换 |
| 按应用音效 | 无 | `perapp.conf` 名单，zygisk 负载把名单内应用音轨剥回普通轨 |
| 低延迟优化 | 全局 | 仅对 `config.toml` 白名单内应用提线程优先级 |
| zygisk 负载 | 不打包 | 打包（已按本机 mFlags 偏移重定位） |
| 动作按钮 | 有（`ha.sh cycle`） | 不提供 |

## 2. 后端接口（应用版新增）

`bin/webui.sh` 转发到 `bin/ha.sh`，再分发到新增的 `bin/router.sh`：

| 动作 | 作用 | 输出 |
|---|---|---|
| `router-status` | 汇总两个名单 + 负载/companion 状态 | `perapp_enabled/count/apps`、`wl_count/apps` 等 |
| `perapp-add <pkg>` | 加入杜比链路名单 | `ok=1` 或 `error=bad_package` |
| `perapp-del <pkg>` | 移出杜比链路名单 | 同上 |
| `perapp-enable <0\|1>` | 杜比链路总开关 | `ok=1` 或 `error=bad_value` |
| `wl-add <pkg>` / `wl-del <pkg>` | 维护低延迟链路名单 | 同上 |

契约仍是 v3.0 的 `rc=N|base64`，由 `bin/webui.sh` 统一包裹。

## 3. 已知问题（未修）

### 3.1 界面仍保留了 v3.0 的「模式」页

应用版直接沿用了 v3.0 的完整前端，其中包含原生/音效的模式切换页与底部导航项。
这与"固定低延迟"的定位**矛盾**：用户如果在那里切到音效模式，全局行为会改变。

处理方式（尚未实施）：隐藏 `#page-mode` 与其导航项，或在 `ha.sh` 里把
`apply:sound` / `apply:compat` 对应用版改为拒绝返回错误。

### 3.2 导航绑定有两套

`webroot/router-ui.js` 自己实现了导航切换（为了不依赖 v3.0 的 app.js），
而 v3.0 的 app.js 也会绑定同一批 `.nav-item`。两者同时生效时以最后执行者为准，
表现为偶尔的高亮与页面不一致。彻底解决需要合并成一套。

### 3.3 后端依赖管理器 busybox 与 root

`bin/ha.sh` 启动时会 re-exec 管理器自带的 busybox：

```
/data/adb/ksu/bin/busybox  或  /data/adb/magisk/busybox
```

缺失则所有动作返回 `error=manager_busybox_missing`；非 root 返回 `error=root_required`。
KernelSU-Next / Magisk 环境满足，但某些精简环境可能不满足。

### 3.4 从未在真机验证

两个版本都只经过：构建、打包完整性、CRLF/shebang、主机测试、无头渲染。
**刷入后的实际行为（尤其 v3.0 后端与 k90pm 调音模块的配合）尚未验证。**

## 4. 验证计划（待设备可用时执行）

1. 备份现有模块目录到 `/sdcard` 与主机
2. 刷通用版 → 重启 → `ha.sh status` / `sound-status` / `boot-status` 是否正常
3. 刷应用版 → 重启 → `router-status` 是否返回两个名单
4. 加一个应用到杜比链路 → 杀应用重开 → `dumpsys media.audio_flinger` 看是否落到普通轨
5. 删除该应用 → 确认名单持久化
6. 任一步失败：回滚备份包并重启
