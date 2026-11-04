# 来源与致谢 / Credits & Attribution

HyperAudioRouter（模块 id `hyperaudio`）是独立维护的第三方模块，与小米、Google
及下列项目没有官方隶属、合作或背书关系。

## 本项目

除第三方头文件、图标和视觉参考外，以下代码为本项目编写：

- `payload/src/main.cpp`：统一 Zygisk 负载（`createTrack_l` inline hook + AAudio GOT patch）
- `webui/bin/*.sh`：机上后端（名单、属性发布、低延迟 daemon、诊断）
- `webui/webroot/*`：WebUI
- `assets/*`、`build.ps1`、`tests/*`

以 **MIT** 许可发布，见 `LICENSE`。

## 思路与参考（未复制代码）

| 项目 | 作者 | 参考内容 | 本项目的实现 |
|---|---|---|---|
| [DolbyRouter](https://github.com/JEez6/DolbyRouter) | JEez6 | 按应用路由、清理 `AudioTrack` FAST 标志使音轨回落到普通混音/效果链 | 自写 inline hook，按 `mFlags` 偏移清 FAST；未包含其代码或二进制 |
| [AAudio MMAP Hook](https://github.com/2278535805/zygisk-aaudio-mmap-hook) | HLMC | AAudio `strzcmp16` 白名单检查可被绕过的思路 | 自写 GOT patch，不使用其二进制、Dobby 或源码；仅对名单内应用生效 |

## 第三方组件

| 组件 | 许可 | 说明 |
|---|---|---|
| `payload/include/zygisk.hpp` | ISC 风格（Copyright 2022-2023 John "topjohnwu" Wu） | Zygisk 模块 API，原样保留 |
| Miuix | 见 `webroot/vendor/miuix-icons-LICENSE.txt` | 界面/图标参考 |
| Material Symbols | Apache-2.0（见 `webroot/vendor/material-symbols-LICENSE.txt`） | 图标 |
| liquid-glass | MIT（见 `webroot/vendor/liquid-glass-LICENSE.txt`） | 玻璃折射视觉参考 |
| `prebuilt/META-INF` | 见文件内说明 | 模块安装入口 |

## 属性基线

`system.prop` 中的音频/蓝牙/offload 属性是社区常见的 HyperOS 音频调优项整理，
具体取值已在本机（REDMI K90 Pro Max / Android 17）验证；这些属性作用于整个系统，
与两份按应用名单无关。

## 特别说明

本项目的 zygisk 负载是**独立实现**：没有使用 DolbyRouter 的二进制或源码，也没有
使用 AAudio MMAP Hook 的二进制、Dobby 或源码。两个项目仅作为问题定义与实现思路的
参考，在此致谢。

如果任何原作者认为本项目的署名或使用方式需要调整，请通过仓库 issue 联系。
