# HyperAudioRouter 交接说明

> 写给接手这个分支的下一个会话。读完这份再动手，可以少走很多弯路。
> 最后更新：2026-11-03，工作区已迁至 `D:\DSH\HyperAudioRouter`（`router/v2`，v2.2.4 修正注入状态误报）

---

## 1. 项目是什么

HyperOS 音频模块。与通用版（`main`）共用 v3.0 前端架构，但定位完全不同：

| 版本 | 分支 | 定位 |
|---|---|---|
| 通用版 | `main` | 全局切换「原生 / 音效」两种音频通路 |
| **应用版（本文档）** | `router/v2` | **按应用**：音效只对音效名单生效，低延迟只对低延迟名单生效，名单外交给系统 |

核心原则（2.2.0 起严格执行）：**名单之外，模块什么都不做**。

---

## 2. 工作区与仓库

```
D:\DSH\HyperAudioRouter\
├── repo\            ← git 仓库（唯一源码真相）
├── dist\            构建产物
├── refs\            参考资料（v3.0 原包、DolbyRouter 源码、zygisk 负载）
├── README.md        目录约定
└── BRIEF-应用版.md  本文件的副本
```

远端：

```
origin  https://github.com/mikudream/HyperAudio-ModeSwitcher.git
        · main        → 通用版 2.0.1（a852f00）
        · router/v2   → 应用版（本分支）
router  https://github.com/mikudream/hyperaudio_router.git  （私有）
```

设备：REDMI K90 Pro Max（`myron`），Android 17，KernelSU-Next 3.3.0，adb 序列号 `6fe50268`，
adb 路径 `D:\App\UotanToolbox\Bin\platform-tools\adb.exe`（经常掉线，需 `adb reconnect` 重试）。

---

## 3. 当前状态（2.2.3）

| 项 | 状态 |
|---|---|
| 代码 | ✅ 纯按应用路由；**没有总开关**，加入名单即生效 |
| 构建 | ✅ 71 项（移除了 .so 与端口补丁） |
| 主机测试 | ✅ 6 节全过（router / lowlat / install / ha 冒烟 / system.prop / DOM） |
| 真机验证 | ✅ 2.2.1 两条链路均已上机验证；2.2.2 WebUI 修复已装机；2.2.3 待解锁后目视 |

构建产物：`repo\hyperaudio_module.zip`

---

## 4. 架构与数据流

模块只做三件事：

1. **进程内 hook（音效）**：zygisk 负载 hook `AudioTrack::createTrack_l`，剥掉
   `FAST|PRIMARY` → 音轨回落普通轨 → 进 Dolby 效果链。配置来自 `perapp.conf`，
   并双写到 `/data/adb/modules/dolbyrouter/perapp.conf`。
2. **逐线程调度（低延迟）**：daemon 每 5 秒扫 `media.audio_flinger`，只处理
   `lowlat.conf` 的 `whitelist` 内正在放音的应用（HAL/audioserver 共享线程也只在
   这种时刻一起提升），`chrt -f` 设置后回读 `/proc` 校验，journal 记录原策略。
3. **开机属性基线（全局）**：`system.prop` 由管理器在开机时注入，作用于整个系统，
   无法按应用拆分，与两份名单无关。`aaudio.mmap_policy` 保持 `1`（AUTO），
   不用 `2`（ALWAYS），避免全局强制 MMAP 破坏"按应用"语义。

**明确不做**：不改端口 XML、不替换 `libaaudio_internal.so`、没有全局音效模式/模式切换/
开机模式、不重启 audioserver、不改 `aaudio.*` 运行期属性。因此没有事务、回滚、挂载所有权、
resetprop 这些机制——因为没有需要回滚的全局改写。

### 4.1 前端与后端

```
webroot/index.html ──> assets/26101606/ui.js        导航（音效/低延迟/设置/关于）
                       assets/26101606/app.js       低延迟设置、状态、Debug、外观
                       webroot/router-ui.js         两份名单的增删

ksu.exec ──> bin/webui.sh <action>     参数校验 + 包成 rc=N|base64
              bin/ha.sh                 busybox / root 检查 + 分发
                ├─ router.sh   两份名单读写、互斥迁移
                ├─ lowlat.sh   白名单过滤 + chrt 调度 + journal 还原
                ├─ runtime.sh  状态汇总与 module.prop 描述
                ├─ boot.sh     开机：标记 applied=native、拉起 daemon
                ├─ diagnostics.sh / sampling.sh / debug.sh  诊断
                └─ theme.sh / fonts.sh                      外观
```

### 4.2 后端接口

```
status / router-status
perapp-add|del|enable    音效名单
wl-add|del               低延迟名单
ll-save                  hal/audio/app 三档优先级
ll-status                配置 + daemon 心跳 + 调度证据
boot / stop              开机收尾 / 卸载前还原线程
diagnose / schedule-diagnose / diag-status / debug-*
```

---

## 5. 2.2.0 做了什么（相对 2.1.0）

**2.2.3（移除总开关）**  

- UI：去掉「音效链路」「低延迟调度」两个开关；**加入名单即生效，移出即恢复**
- 后端：`perapp-enable` 动作删除，`perapp.conf` 恒写 `enabled=1`（仅为兼容 zygisk 负载）；
  `lowlat.conf` 不再有 `enabled`/`only_whitelist`，旧字段读取时忽略
- `ll-save` 改为 3 个参数（hal/audio/app）；daemon 常驻，开机即拉起
- 升级迁移：开机时把旧 `perapp.conf` 的 `enabled=0` 归一化为 1 并同步 dolbyrouter 镜像

**2.2.2（WebUI 修复，实机反馈）**

- 底栏蓝色指示器宽度写死 `/3`、liquid 引擎把位置 clamp 到 2：按实际 tab 数
  （4）计算宽度与上限，`--ha-nav-count` 由 `ui.js` 写入
- 包名输入框用的 `.field` 类在 CSS 中不存在：补齐与 `.target-input` 同级的样式
- 卡内 `.hint` / `.section-note` / `.section-title` 没有内边距（文字贴边）：
  统一为 20px，并补 Material 3 的 16px 覆盖
- `名单为空` 的 `.empty` 没有样式：补齐内边距，并给列表行加分隔线
- 注入状态补 `.value` 右对齐与成功/异常颜色

**2.2.1（本次）**

- 模块名改为 `HyperAudioRouter`（id 仍为 `hyperaudio`）
- 安装检测与全局版对齐：两者共用 id，覆盖安装是安全的，只提示"将替换全局版、需重启"；
  上游 `hyperaudio_compat` 只提示冲突不阻止；升级本分支旧版时保留两份名单，
  并提示旧 `lowlat.conf` 没有白名单（升级后只对名单内应用生效）
- 设置页新增"诊断"入口（此前 Debug 页没有任何可达路径）
- `aaudio.mmap_policy` / `mmap_exclusive_policy` 由 `2`(ALWAYS) 改回 `1`(AUTO)
- 修复 `module.prop` 描述被写成非法行/多行的问题

**功能语义**

1. `lowlat.sh` 恢复白名单：解析 `only_whitelist` / `whitelist=CSV`，`ll_targets` 只保留
   名单内包名；`any=0` 时连 HAL/audioserver 都不碰。`only_whitelist` 强制为 1。
2. `router.sh` 的 `wl-*` 改为读写 `lowlat.conf`（原来写 `config.toml`，已不打包，
   添加直接 `error=no_config`）。
3. 两个名单**互斥**：加入一边自动从另一边移出，回显 `moved_from=`。
4. `perapp-add` 首次创建时 `enabled=1`（原来写入 0，音效链路实际没生效）。
   2.2.1 曾加过总开关，2.2.3 已移除，改为加入名单即生效。
5. `ll-save` 白名单由 `wl-*` 维护，保存优先级时原样保留（不再要求客户端传白名单）。

**删除旧实现**

- `sound.sh` / `patch_ports.awk` / `audio_ready.sh` / `check_audio_ready.awk`
- 顶层 2.x 旧实现（`webui/runtime.sh`、`helper.sh`、`diagnose.sh`、`action.sh`、
  `uninstall.sh`、`start_daemon.sh`、`detect_tuning.sh`、`v3bin/`）及其测试
- `assets/action.sh`、`sound.conf`、`boot.conf`（无模式可切，无 action 按钮）
- 构建不再打包 `system/lib64/*.so` 与端口补丁

**前端**

- 导航：`音效 / 低延迟 / 设置 / 关于`，删除「模式」页与「应用」页
- 音效页：注入状态 + 名单（加入即生效）
- 低延迟页：三档优先级 + 名单（加入即生效）+ 实时状态
- 设置页：调音检测 + 外观（删除开机模式、恢复原生、音效模式设置）

---

## 6. 已知问题 / 未验证

| 问题 | 说明 |
|---|---|
| 真机未验证 | `chrt` 是否被策略允许、zygisk 是否注入、Dolby 是否真的起效，都只能在设备上确认 |
| zygisk 偏移写死 | `0x3c0` 只对当前系统版本有效；系统更新后需用 `zygisk/patch_mflags_offset.py` 重新定位 |
| companion 依赖 | 音效名单依赖 DolbyRouter 的 companion 读 `perapp.conf`；没有 companion 时不生效 |
| system.prop 全局 | 89 条属性作用于所有应用，无法按名单拆分（有意保留） |
| Debug 文案遗留 | `debug.sh` 的解读文案里还有"模式""音效模式"等旧词，属于展示层遗留 |
| 前端重复文件 | `webroot/` 根目录还有一份未被 index.html 引用的旧资源副本，清理前注意确认引用关系 |

---

## 7. 验证清单（真机）

1. 安装：`adb push zip /sdcard/Download/` → `su -c "ksud module install …"` → 重启
2. `su -c "sh /data/adb/modules/hyperaudio/bin/ha.sh status"` → `applied=native`、名单规模正确
3. `ps -A | grep zn-zygisk-companion64` → 应看到本模块的 companion
4. 音效页加一个应用 → 杀应用重开并播放 → `dumpsys media.audio_flinger` 看该应用是否
   从 `AudioOut_15`（Dolby）变 `AudioOut_D`（普通）；名单外应用应保持原样
5. 低延迟页加一个应用并开启 → 播放后 `ll-status` 应出现 `ll_state=verified` 且
   `ll_packages` 只包含名单内包名；`owned/` 下的 tid 都属于该应用（以及当时的 HAL/audioserver）
6. 关闭低延迟 → `state/lowlat/owned` 归零、线程回到 `SCHED_OTHER`
7. 名单为空时播放任意应用 → 不应产生任何 `owned/` 文件

回滚：删除 `/data/adb/modules/hyperaudio` 后重启。

---

## 8. 踩过的坑（省时间用）

**PowerShell**

- `build.ps1` **必须纯 ASCII**（PS 5.1 按 ANSI 读取无 BOM 文件，中文注释会让解析失败）
- 字符串里 `"xxx\"` 的反斜杠会转义引号，路径拼接用单引号：`('zygisk\' + $z)`
- 中文弯引号 `“”` 传给 `git commit -m` 会被当作字符串分隔符 → 用 `git commit -F 文件`

**设备端**

- `ksu.exec` 只回传**最后一行** stdout → 后端统一包成 `rc=N|base64`
- `ha.sh` 启动即要求：管理器 busybox + root；主机测试用 `HA_BUSYBOX=1` / `HA_BOOT_ID=`
- 判断「应用在放音」用 `uid >= 10000`；系统进程不算
- toybox 的 `grep` 不支持 `\(a\|b\)`，分开写两次 `grep -q`
- 白名单判断用 `case ",$LL_WHITE," in *",$pkg,"*)`，不要用 grep 拼字符串

**前端**

- 页面加载的是 `assets/26101606/app.js`，**不是** `webroot/app.js`（后者已无此文件）
- 改动 DOM 后必须跑 `node tests/test_webui_dom.js`：它检查脚本访问的每个 id 是否存在
- 导航由 `assets/26101606/ui.js` 统一管理，`router-ui.js` 只负责页面内容

---

## 9. 常用命令

```powershell
# 构建
cd D:\DSH\HyperAudioRouter\repo
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1

# 主机测试（5 节）
& 'D:\App\Git\bin\bash.exe' -lc "cd /d/DSH/HyperAudioRouter/repo && sh tests/run.sh"

# DOM 一致性
& 'C:\Users\Bronya\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe' tests\test_webui_dom.js

# 设备安装
adb push hyperaudio_module.zip /sdcard/Download/
adb shell su -c "/data/adb/ksu/bin/ksud module install /sdcard/Download/hyperaudio_module.zip"
```

---

## 10. 建议的推进顺序

1. 真机验证第 7 节 2–7 步（最优先：确认 `chrt` 在目标 ROM 上不返回 EPERM）
2. 补 zygisk 偏移的装机检测与失败提示（系统更新后音效名单会静默失效）
3. 清理 `debug.sh` 里遗留的"模式"文案
4. 清理 `webroot/` 下未被引用的重复资源，减小包体
5. 更新 `发布指引.md` 的版本号/描述示例，打 `v2.2.1` 标签
