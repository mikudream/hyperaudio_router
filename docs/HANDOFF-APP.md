# HyperAudio Router（应用版）交接说明

> 写给接手这个分支的下一个会话。读完这份再动手，可以少走很多弯路。
> 最后更新：2026-11-03，提交 `4ab0ebb`（`router/v2`）

---

## 1. 项目是什么

HyperOS 音频模块，两个版本共用一套 v3.0 架构（前端 + 后端契约），但定位不同：

| 版本 | 分支 | 定位 |
|---|---|---|
| 通用版 | `main` | 全局切换「原生 / 音效」两种音频通路 |
| **应用版（本文档）** | `router/v2` | **固定低延迟**，音效按应用名单开启 |

应用版的核心价值：**同一台设备上，A 应用走 Dolby 效果链，B 应用保持低延迟通路**。

---

## 2. 工作区与仓库

```
D:\DSH\HyperAudioRouter\
├── repo\            ← git 仓库（唯一源码真相）
├── dist\            构建产物
├── refs\            参考资料（v3.0 原包、DolbyRouter 源码、zygisk 负载）
└── README.md        目录约定
```

远端：

```
origin  https://github.com/mikudream/HyperAudio-ModeSwitcher.git
        · main        → 通用版 2.0.1（a852f00）
        · router/v2   → 应用版 2.1.0（4ab0ebb）← 本分支
router  https://github.com/mikudream/hyperaudio_router.git  （私有，main = 4ab0ebb）
```

**注意**：本地还有一条 `hyperaudio_router` 分支，那是旧的 1.1.0 快照，已 12+ 提交落后，不要用它。

设备：REDMI K90 Pro Max（`myron`），Android 17，KernelSU-Next 3.3.0，adb 序列号 `6fe50268`，
adb 路径 `D:\App\UotanToolbox\Bin\platform-tools\adb.exe`（经常掉线，需 `adb reconnect` 重试）。

---

## 3. 当前状态

| 项 | 状态 |
|---|---|
| 代码 | ✅ 已同步主线今日全部改动（合并提交 `4ab0ebb`） |
| 构建 | ✅ 80 项（含 zygisk 负载） |
| 主机测试 | ✅ 11 节全过（含 `test_router_sh.sh` 29 项断言） |
| DOM 审计 | ✅ 143 处引用可解析 |
| **真机验证** | ❌ **从未做过** |

构建产物：`D:\DSH\HyperAudioRouter\repo\hyperaudio_module.zip`

---

## 4. 架构与数据流

```
webroot/index.html  ──加载──> assets/26101606/ui.js        导航与页面切换（唯一导航管理者）
                            assets/26101606/app.js         状态/模式/音效/调音
                            webroot/router-ui.js           应用页（两个名单）

任何前端动作 ──ksu.exec──> bin/webui.sh <action>           参数校验 + 包成 rc=N|base64
                            bin/ha.sh                      动作分发
                              ├─ runtime.sh  模式状态机（bind 挂载 / 事务 / 回滚）
                              ├─ sound.sh    端口 flags + MMAP 属性
                              ├─ lowlat.sh   chrt 逐线程调度
                              ├─ boot.sh     开机恢复与失败回退
                              └─ router.sh   两个名单的读写   ← 应用版新增
```

### 4.1 两条链路

| 名单 | 存储 | 作用 | 是否改通路 |
|---|---|---|---|
| 杜比链路 | `perapp.conf`（模块根目录） | 名单内应用音轨回落普通轨 → 经 Dolby | ✅ 改 |
| 低延迟链路 | `lowlat.conf` 的 `whitelist` | 名单内应用线程提为 `SCHED_FIFO` | ❌ 只改调度 |

`perapp.conf` 格式：

```
enabled=1
app=com.example.game
```

### 4.2 杜比链路怎么生效

zygisk 负载（`zygisk/arm64-v8a.so`，已按本机 `mFlags` 偏移 `0x378 → 0x3c0` 重定位）在目标进程内
hook `AudioTrack::createTrack_l`，剥掉 `FAST | PRIMARY` 标志 → 音轨落到普通混音轨 → 进入效果链。

**双写**：DolbyRouter 的负载把配置路径编译期写死，`router.sh` 写 `perapp.conf` 时必须同时镜像到
`/data/adb/modules/dolbyrouter/perapp.conf`，否则 companion 读不到。

### 4.3 后端接口

```
router-status    两个名单 + 负载/companion 状态
perapp-add/del   维护杜比链路名单
perapp-enable    杜比链路总开关
wl-add/del       维护低延迟链路名单
```

---

## 5. 首要任务：低延迟链路名单目前是坏的

**这是合并带来的回归，必须先修，否则「应用页」第二张卡片是摆设。**

现状：

- `router.sh` 的 `wl-add/wl-del` 读写 `$MODDIR/config.toml`
- 但 v3 架构的调度器 `lowlat.sh` 读的是 `lowlat.conf`
- 主线在今日移除了 `lowlat.conf` 的白名单支持（`LL_ONLY` / `LL_WHITE` 全删）
- `config.toml` 也不再打包

结果：`wl-add` 直接返回 `error=no_config`，即使写进去也没有任何模块会读。

修法（二选一）：

**A. 在应用版恢复白名单支持（推荐）**

1. `lowlat.sh` 恢复：`LL_ONLY`/`LL_WHITE` 解析、`ll_valid` 6 参、`ll_save` 6 参并写
   `only_whitelist`+`whitelist`、`ll_status` 输出、`ll_tick_locked` 里的白名单过滤
2. `webui.sh` 的 `ll-save` 参数个数改回 7
3. `router.sh` 的 `wl-*` 改为读写 `lowlat.conf`（CSV 形式，`only_whitelist=1`）
4. 更新 `tests/test_router_sh.sh`

参考实现可直接看历史提交：`git show refactor/v3:webui/bin/lowlat.sh`

**B. 换存储**：让 `wl-*` 直接写 `lowlat.conf`，同时把白名单逻辑加回去——本质同 A。

---

## 6. 其余已知问题

| 问题 | 说明 | 建议 |
|---|---|---|
| 模式页仍在 | 应用版沿用 v3.0 前端，「模式」页可切到音效模式，与「固定低延迟」定位矛盾 | 隐藏该页与导航项，或在 `ha.sh` 拒绝 `apply:sound` |
| zygisk 偏移写死 | `0x3c0` 只对当前系统版本有效；系统更新后需重新用 `refs/DolbyRouter-myron/patch_mflags_offset.py` 定位 | 装机检测 + 失败提示 |
| 描述会被覆盖 | `runtime.sh` 的 `update_description` 会把 `module.prop` 描述写成「全局切换音频模式，当前模式为：…」，与应用版文案不符 | 按版本区分文案 |
| 从未真机验证 | 所有结论来自静态分析与主机测试 | 见下节验证清单 |

---

## 7. 验证清单（真机）

1. 安装：`adb push zip /sdcard/Download/` → `su -c "ksud module install …"` → 重启
2. `su -c "sh /data/adb/modules/hyperaudio/bin/ha.sh status"` → 应返回 `ok` 与 `boot_result=native`
3. `ps -A | grep zn-zygisk-companion64` → 应看到本模块的 companion
4. 往 `perapp.conf` 加一个应用 → 杀应用重开并播放 → `dumpsys media.audio_flinger` 看端口
   是否从 `AudioOut_15`（Dolby）变 `AudioOut_D`（普通）
5. 低延迟链路：开启后播歌 → `ll-status` 应出现 `ll_state=verified` 且 `ll_verified>0`
6. 关闭低延迟 → `state/lowlat/owned` 归零、线程回到 `SCHED_OTHER`

回滚：删除 `/data/adb/modules/hyperaudio` 后重启。

---

## 8. 踩过的坑（省时间用）

**PowerShell**
- `build.ps1` **必须纯 ASCII**。PS 5.1 按 ANSI 读取无 BOM 文件，中文注释会让解析失败
  （本次合并就是被这个问题卡住：报「意外的标记 }」，实际是上一行的中文注释）
- 字符串里 `"xxx\"` 的反斜杠会转义引号，路径拼接用单引号：`('zygisk\' + $z)`
- 中文弯引号 `“”` 在传给 `git commit -m` 时会被当成字符串分隔符 → 用 `git commit -F 文件`
- `$l` 和 `$L` 是同一个变量（大小写不敏感），别同时用作数组和路径

**设备端**
- `ksu.exec` 只回传**最后一行** stdout → 后端必须把输出压成单行（`\x1f`）或包成 `rc=N|base64`
- 管道截断会杀死执行中的脚本：`sh ha.sh apply sound | head -3` 会因 SIGPIPE 中断，
  留下 `state/lowlat/pause` 导致永久 suspended（已加自愈，但调试时别这么写）
- `ha.sh` 启动即要求：管理器 busybox（`/data/adb/ksu/bin/busybox`）+ root
- 判断「应用在放音」用 `uid >= 10000`；系统进程不算
- toybox 的 `grep` 不支持 `\(a\|b\)`，分开写两次 `grep -q`

**前端**
- v3.0 的页面加载的是 `assets/26101606/app.js`，**不是** `webroot/app.js`
  （曾经改错文件导致「所有页面一直正在加载」）
- 改动 DOM 后必须跑 `node tests/test_webui_dom.js`：它检查脚本访问的每个 id 是否存在
- 导航由 `assets/26101606/ui.js` 统一管理，`router-ui.js` 只负责页面内容，别再自己绑 `.nav-item`

---

## 9. 常用命令

```powershell
# 构建
cd D:\DSH\HyperAudioRouter\repo
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1

# 主机测试（11 节）
& 'D:\App\Git\bin\bash.exe' -lc "cd /d/DSH/HyperAudioRouter/repo && sh tests/run.sh"

# DOM 一致性
& 'C:\Users\Bronya\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe' tests\test_webui_dom.js

# 设备安装
adb push hyperaudio_module.zip /sdcard/Download/
adb shell su -c "/data/adb/ksu/bin/ksud module install /sdcard/Download/hyperaudio_module.zip"
```

---

## 10. 建议的推进顺序

1. 修低延迟链路名单（第 5 节）——否则应用页一半功能是空的
2. 隐藏模式页，确保「固定低延迟」前提不被破坏
3. 真机验证 zygisk 注入（第 7 节 3–4 步）
4. 补 zygisk 偏移的运行时校验
5. 更新作者/描述文案，打 `v2.1.0` 标签
