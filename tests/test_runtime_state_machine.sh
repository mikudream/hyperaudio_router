#!/bin/sh
# ============================================================
# runtime.sh 状态机的依赖注入测试（主机侧）
# ============================================================
# runtime.sh 不能直接跑在主机上：要 root、要真的 mount、要 /proc。
# 注入方式：
#   1) 路径：HA_MOD / HA_TMP / HA_SOURCE_DIR / HA_TARGET_BASE /
#            HA_MOUNTINFO / HA_BOOT_ID_FILE
#   2) PATH mock：mount/umount/chcon/chown/killall/setsid/pidof 换成假命令；
#      mock 的 mount --bind 会**真的把内容复制到目标**，于是"目标内容"
#      这条判据也能被真实测到
#   3) 明确的测试钩子：HA_RT_OURS_TEST（强制归属结果）、
#      HA_RT_TARGET_STAT（指定比对 dev:ino 的那个路径）
#      生产环境都不设，走真实判据
#
# 测的是真实 runtime.sh 的判断与分支，不是它的副本。
# 用法: sh tests/test_runtime_state_machine.sh
# ============================================================
HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
RT="$HERE/../webui/runtime.sh"
[ -f "$RT" ] || { echo "找不到 runtime.sh: $RT"; exit 1; }

B=/tmp/ha_rt
rm -rf "$B"
mkdir -p "$B/bin" "$B/mod/bin" "$B/tmp" \
         "$B/src/tunemod/Link/odm/etc/audio" \
         "$B/root/odm/etc/audio"

SRCXML="$B/src/tunemod/Link/odm/etc/audio/audio_module_config_primary.xml"
TARGET="$B/root/odm/etc/audio/audio_module_config_primary.xml"
SRCXML_ORIG="$B/srcxml.orig"
cat > "$SRCXML_ORIG" <<'EOF'
<audioPolicyConfiguration>
  <mixPorts>
    <mixPort name="low_latency_out" role="source" flags="FAST PRIMARY">
    </mixPort>
    <mixPort name="raw_out" role="source" flags="FAST RAW">
    </mixPort>
  </mixPorts>
</audioPolicyConfiguration>
EOF

cp "$HERE/../webui/patch_ports.awk" "$B/mod/bin/patch_ports.awk"
# 0.4.7 起 runtime.sh 会载入 audio_ready.sh 做音频就绪校验，夹具必须一并提供
cp "$HERE/../webui/audio_ready.sh" "$B/mod/bin/audio_ready.sh"
cp "$HERE/../webui/check_audio_ready.awk" "$B/mod/bin/check_audio_ready.awk"
printf '#!/bin/sh\nexit 0\n' > "$B/mod/bin/start_daemon.sh"
cat > "$B/mod/module.prop" <<'EOF'
id=hyperaudio
name=音频模式切换器
version=0.4.6
description=【当前模式：音效模式】正文
mode.sound=音效模式
mode.fast=低延迟模式
EOF
printf 'fake-boot-id-1\n' > "$B/boot_id"

# ---------- PATH mock ----------
# mount --bind <src> <dst>：记录到挂载表，并把内容真的复制到 dst，
# 这样"目标内容与 active.xml 一致"这条退路判据可被真实验证。
cat > "$B/bin/mount" <<'EOF'
#!/bin/sh
[ "$MOCK_MOUNT" = "ok" ] || exit 1
# 记下覆盖前的内容（因为在下层文件上再挂一层，umount 后应看到"原来那份"）
cp -f "$3" "$MOCK_UNDER_TABLE" 2>/dev/null
printf '%s\n' "$3" >> "$MOCK_MOUNT_TABLE"
cp -f "$2" "$3" 2>/dev/null
exit 0
EOF
cat > "$B/bin/umount" <<'EOF'
#!/bin/sh
[ "$MOCK_UMOUNT" = "ok" ] || exit 1
if [ -f "$MOCK_MOUNT_TABLE" ]; then
  grep -Fvx "$1" "$MOCK_MOUNT_TABLE" > "$MOCK_MOUNT_TABLE.tmp" 2>/dev/null
  mv -f "$MOCK_MOUNT_TABLE.tmp" "$MOCK_MOUNT_TABLE" 2>/dev/null
fi
# 摘掉后露出下层的内容
[ -f "$MOCK_UNDER_TABLE" ] && cp -f "$MOCK_UNDER_TABLE" "$1" 2>/dev/null
exit 0
EOF
for c in chcon chown setsid restorecon; do
  printf '#!/bin/sh\nexit 0\n' > "$B/bin/$c"
done

# pidof：hyper-audio 由 MOCK_DAEMON 控制；audioserver 用 pid 文件模拟，
# 这样 killall 之后 PID 会真的变，就绪校验才能看到"进程已更换"
cat > "$B/bin/pidof" <<'EOF'
#!/bin/sh
case "$1" in
  audioserver) cat "$MOCK_AUDIO_PID_FILE" 2>/dev/null; exit 0 ;;
  hyper-audio|"")
    [ "$MOCK_DAEMON" = "1" ] || exit 1
    echo 4242
    exit 0 ;;
  *) exit 1 ;;
esac
EOF

# killall audioserver：换一个新 PID，模拟 init 重新拉起音频服务
cat > "$B/bin/killall" <<'EOF'
#!/bin/sh
[ "$1" = "audioserver" ] || exit 0
_old=$(cat "$MOCK_AUDIO_PID_FILE" 2>/dev/null)
case "$_old" in ''|*[!0-9]*) _old=1000 ;; esac
printf '%s\n' "$((_old + 1))" > "$MOCK_AUDIO_PID_FILE"
exit 0
EOF

# getprop：就绪校验会问 init.svc.audioserver
cat > "$B/bin/getprop" <<'EOF'
#!/bin/sh
case "$1" in
  init.svc.audioserver) echo running ;;
  *) echo "" ;;
esac
exit 0
EOF

# dumpsys：**从当前生效文件反推"已加载"的 flags**，忠实模拟 audioserver
# 真的读了那份配置。目标文件不存在时输出不可解析的内容（=> 未验证）。
# 十六进制格式化交给 awk —— 部分 sh 的 printf 不支持 %x。
cat > "$B/bin/dumpsys" <<'EOF'
#!/bin/sh
# 调用形如 `dumpsys -t 2 media.audio_policy`，服务名在**最后一个参数**，
# 不能假定是 $2（-t 2 会把它顶到 $3）。
for _a in "$@"; do _svc=$_a; done
case "$_svc" in
  media.audio_policy)
    _low=""; _raw=""
    if [ -f "$MOCK_TARGET_FILE" ] && [ -f "$MOCK_PATCHER" ]; then
      _f=$(awk -v remove_fast_low=0 -v remove_fast_raw=0 -v remove_raw=0 -v report_flags=1 \
            -f "$MOCK_PATCHER" "$MOCK_TARGET_FILE" 2>/dev/null)
      _low=$(printf '%s' "$_f" | sed -n 's/^low_latency_out=//p')
      _raw=$(printf '%s' "$_f" | sed -n 's/^raw_out=//p')
    fi
    if [ -z "$_low" ]; then
      echo "unavailable"; exit 0
    fi
    echo "Primary Output I/O handle: 15"
    echo "Outputs:"
    echo "  1. Handle: 15 ; \"primary\""
    echo "     Output MixPorts:"
    awk -v l="$_low" -v r="$_raw" 'BEGIN{
      printf "       1. \"low_latency_out\"; flags 0x%08x\n", l+0
      printf "       2. \"raw_out\"; flags 0x%08x\n", r+0
    }'
    exit 0 ;;
  media.audio_flinger)
    printf 'Output thread 0x7f: type 0\n'
    printf '  I/O handle: 15\n'
    printf '  HAL frame count: 960\n'
    exit 0 ;;
  *) exit 0 ;;
esac
EOF

# sleep：测试里不需要真的等
printf '#!/bin/sh\nexit 0\n' > "$B/bin/sleep"
chmod +x "$B/bin"/*

# ---------- 断言 ----------
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ✓ %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  ✗ %s\n' "$1"; }

# 把挂载表同步成 mountinfo（runtime.sh 用它判断"是否挂载着"）
sync_mountinfo() {
  : > "$B/mountinfo"
  [ -f "$B/mounts" ] || return 0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf '1 0 0:1 / %s rw - ext4 /dev/block/x rw\n' "$p" >> "$B/mountinfo"
  done < "$B/mounts"
}

reset_tree() {
  rm -rf "$B/mod/state" "$B/mod/mode" "$B/mounts" "$B/mountinfo"
  mkdir -p "$B/mod/state"
  printf 'sound\n' > "$B/mod/mode"
  cp "$SRCXML_ORIG" "$SRCXML"
  cp "$SRCXML_ORIG" "$TARGET"      # 目标当前=带 FAST 的原始配置
  : > "$B/mounts"
  printf '1000\n' > "$B/audiopid"  # 音频服务当前 PID
  sync_mountinfo
}

run_rt() {
  [ "$NO_SYNC_MOUNTINFO" = "1" ] || sync_mountinfo
  # 直接继承调用方的变量（不用 env 的 KEY="${KEY:-}" 写法 —— 那会把调用方
  # 写在命令前面的前缀赋值覆盖成空值，钩子就永远不生效）。每个测试块自己
  # 设置这几个变量。
  PATH="$B/bin:$PATH" HA_MOD="$B/mod" HA_TMP="$B/tmp" HA_SOURCE_DIR="$B/src" \
  HA_TARGET_BASE="$B/root" HA_MOUNTINFO="$B/mountinfo" \
  HA_BOOT_ID_FILE="$B/boot_id" HA_SH=sh \
  MOCK_MOUNT_TABLE="$B/mounts" MOCK_UNDER_TABLE="$B/under" \
  MOCK_AUDIO_PID_FILE="$B/audiopid" \
  MOCK_TARGET_FILE="$TARGET" MOCK_PATCHER="$B/mod/bin/patch_ports.awk" \
  HA_RT_OURS_TEST="$HA_RT_OURS_TEST" \
  HA_RT_TARGET_STAT="$HA_RT_TARGET_STAT" \
  sh "$RT" "$@" > "$B/out.txt" 2>&1
  RC=$?
  OUT=$(cat "$B/out.txt")
}

# 每个测试块开始前重置注入变量，避免上一个测试的取值泄漏过来。
# 注意顺序：必须先 unset 再赋默认值（写成先赋值后 unset 会把默认值也清掉）。
reset_mocks() {
  unset MOCK_MOUNT MOCK_UMOUNT MOCK_DAEMON
  unset HA_RT_OURS_TEST HA_RT_TARGET_STAT NO_SYNC_MOUNTINFO
  MOCK_MOUNT=ok; MOCK_UMOUNT=ok; MOCK_DAEMON=0
  HA_RT_OURS_TEST=""; HA_RT_TARGET_STAT=""; NO_SYNC_MOUNTINFO=""
  export MOCK_MOUNT MOCK_UMOUNT MOCK_DAEMON
  export HA_RT_OURS_TEST HA_RT_TARGET_STAT
}

# 默认场景：目标是"我们的层"（用注入指出比对对象就是 active.xml 本身）
# 默认成功场景：目标是"我们的层"。主机侧伪造不了真实挂载的 dev:ino，
# 所以用 HA_RT_TARGET_STAT 指出比对对象；HA_RT_OURS_TEST=yes 表示归属判定为真。
# 调用方若已设置 HA_RT_TARGET_STAT（例如指向 active.xml）则沿用。
apply_sound_ok() {
  HA_RT_OURS_TEST=yes
  [ -n "$HA_RT_TARGET_STAT" ] || HA_RT_TARGET_STAT="$B/mod/state/active.xml"
  MOCK_MOUNT=ok
  MOCK_UMOUNT=ok
  run_rt apply sound
}

echo "############ 1. 正常应用：不写第三方源文件 ############"
reset_mocks
reset_tree
before=$(md5sum "$SRCXML" | awk '{print $1}')
apply_sound_ok
echo "  (rc=$RC) $(printf '%s' "$OUT" | tr '\n' ' ')"
[ "$RC" = "0" ] && ok "apply sound 成功" || bad "apply sound 失败"
[ "$before" = "$(md5sum "$SRCXML" | awk '{print $1}')" ] && ok "调音模块源文件未被改动" || bad "源文件被改动了！"
[ -f "$B/mod/state/active.xml" ] && ok "生成了 state/active.xml" || bad "没有 active.xml"
[ -f "$B/mod/state/pending" ] && bad "pending 未清除" || ok "pending 已清除"
[ "$(tr -d ' \r\n' < "$B/mod/state/applied" 2>/dev/null)" = "sound" ] && ok "applied=sound" || bad "applied 不对"
[ "$(tr -d ' \r\n' < "$B/mod/mode")" = "sound" ] && ok "mode=sound" || bad "mode 不对"
grep -q 'FAST' "$B/mod/state/active.xml" 2>/dev/null && bad "active.xml 里仍有 FAST" || ok "active.xml 已摘 FAST"
grep -q 'FAST PRIMARY' "$B/mod/state/base.xml" 2>/dev/null && ok "base.xml 保留原始 FAST" || bad "base.xml 不对"
grep -q 'FAST PRIMARY' "$SRCXML" && ok "源文件仍是带 FAST 的原始形态" || bad "源文件被改了"
grep -q 'FAST' "$TARGET" && bad "目标上没看到补丁" || ok "目标内容已是摘掉 FAST 的版本"
grep -qF "$TARGET" "$B/mounts" && ok "在目标路径上建立了挂载" || bad "挂载表里没有目标"

echo ""
echo "############ 2. mount 失败 => 回滚并报错 ############"
reset_mocks
reset_tree
HA_RT_OURS_TEST=yes
MOCK_MOUNT=fail
MOCK_UMOUNT=ok
run_rt apply sound
echo "  (rc=$RC) $(printf '%s' "$OUT" | tr '\n' ' ')"
[ "$RC" != "0" ] && ok "返回非零" || bad "居然成功了"
printf '%s' "$OUT" | grep -q 'apply_failed_restored_native' && ok "报 apply_failed_restored_native" || bad "错误名不对"
[ "$(tr -d ' \r\n' < "$B/mod/mode")" = "fast" ] && ok "mode 回滚为 fast" || bad "mode 未回滚"
[ -f "$B/mod/state/pending" ] && bad "pending 残留" || ok "pending 已清"
[ -f "$B/mod/state/active.xml" ] && bad "回滚后仍留着 active.xml" || ok "active.xml 已清理"

echo ""
echo "############ 3. 异常 XML => fail-closed，不改动任何东西 ############"
reset_mocks
reset_tree
# 畸形源文件：两个端口都带 FAST（所以 repair_legacy_source 认为无需修复），
# 但 flags 里含一个不支持的标记 —— 编辑器必须 fail-closed。
# 注意不能直接塞 state/base.xml：apply_mode 每次都会重新快照 $TARGET，
# 那份自造的基线会被覆盖，测不到想测的路径。
printf '<mixPorts><mixPort name="low_latency_out" role="source" flags="FAST PRIMARY"></mixPort><mixPort name="raw_out" role="source" flags="FAST RAW WEIRD"></mixPort></mixPorts>\n' > "$SRCXML"
cp "$SRCXML" "$TARGET"
badxml=$(md5sum "$SRCXML" | awk '{print $1}')
HA_RT_OURS_TEST=yes
MOCK_MOUNT=ok
MOCK_UMOUNT=ok
run_rt apply sound
echo "  (rc=$RC) $(printf '%s' "$OUT" | tr '\n' ' ')"
[ "$RC" != "0" ] && ok "返回非零" || bad "居然成功了"
printf '%s' "$OUT" | grep -q 'port_patch_rejected' && ok "报 port_patch_rejected_*" || bad "错误名不对（$OUT）"
[ -s "$B/mounts" ] && bad "居然做了挂载" || ok "未做任何挂载"
[ "$badxml" = "$(md5sum "$SRCXML" | awk '{print $1}')" ] && ok "畸形源文件未被改动" || bad "源文件被改了"

echo ""
echo "############ 4. 低延迟模式：不补丁、摘掉我们的层 ############"
reset_mocks
reset_tree
apply_sound_ok >/dev/null 2>&1
[ -s "$B/mounts" ] && ok "前置：已建立挂载" || bad "前置挂载没建立"
HA_RT_OURS_TEST=yes HA_RT_TARGET_STAT="$B/mod/state/active.xml" \
MOCK_MOUNT=ok
MOCK_UMOUNT=ok
run_rt apply fast
echo "  (rc=$RC) $(printf '%s' "$OUT" | tr '\n' ' ')"
[ "$RC" = "0" ] && ok "apply fast 成功" || bad "apply fast 失败"
[ "$(tr -d ' \r\n' < "$B/mod/state/applied" 2>/dev/null)" = "fast" ] && ok "applied=fast" || bad "applied 不对"
[ -s "$B/mounts" ] && bad "挂载没摘掉" || ok "已摘掉我们的层"
[ -f "$B/mod/state/owned" ] && bad "owned 残留" || ok "owned 已清"
grep -q '【当前模式：低延迟模式】' "$B/mod/module.prop" && ok "简介切到低延迟模式" || bad "简介不对"
grep -q 'FAST PRIMARY' "$SRCXML" && ok "源文件仍带 FAST（未被我们碰过）" || bad "源文件被改"

echo ""
echo "############ 4b. sound -> fast -> sound 循环（真机踩到的 bug）############"
# 真机上 fast -> sound -> fast 之后再也切不回 sound：
# 摘层成功却没清掉 active.xml，于是下一次 apply 时 mount_is_ours
# 拿残留的 active.xml 去和"现在挂着的调音模块自己的层"比对 => 误判 conflict
# => 回滚 + 开机护栏。这里把整圈跑一遍验收。
reset_mocks
reset_tree
HA_RT_OURS_TEST=yes
HA_RT_TARGET_STAT="$B/mod/state/active.xml"
run_rt apply sound
[ "$RC" = "0" ] || bad "第 1 次 sound 失败（$OUT）"
[ "$(tr -d ' \r\n' < "$B/mod/state/applied" 2>/dev/null)" = "sound" ] && ok "第 1 次 sound 成功" || bad "第 1 次 sound 的 applied 不对"

run_rt apply fast
[ "$RC" = "0" ] || bad "切回 fast 失败（$OUT）"
[ -f "$B/mod/state/active.xml" ] && bad "摘层后 active.xml 残留（正是真机 bug）" || ok "摘层后已清掉 active.xml"
[ -f "$B/mod/state/target" ]  && bad "摘层后 target 残留" || ok "摘层后已清掉 target"
[ -f "$B/mod/state/owned" ]   && bad "摘层后 owned 残留" || ok "摘层后已清掉 owned"

# 关键：第二次切 sound 必须成功（真机上这一步曾经失败）
reset_mocks
HA_RT_OURS_TEST=yes
HA_RT_TARGET_STAT="$B/mod/state/active.xml"
run_rt apply sound
echo "  (第 2 次 sound: rc=$RC) $(printf '%s' "$OUT" | tr '\n' ' ')"
[ "$RC" = "0" ] && ok "第 2 次 sound 成功（循环可用）" || bad "第 2 次 sound 失败（$OUT）"
printf '%s' "$OUT" | grep -q 'overlay_changed_by_another_module' && bad "又误报 overlay_changed" || ok "未误报 overlay_changed"
[ "$(tr -d ' \r\n' < "$B/mod/state/applied" 2>/dev/null)" = "sound" ] && ok "applied=sound" || bad "applied 不对"

echo ""
echo "############ 4c. 残留 active.xml 时不得把调音模块自己的层当成冲突 ############"
# 真机场景：fast 模式下反复操作后，state 里留着一个旧的 active.xml，
# 而 /odm 上挂着的是**调音模块自己**的 bind mount（内容 = 原始文件）。
# 这不该被判成冲突，否则用户再也切不回音效模式。
# 这里用硬链接让目标与源文件同 inode，忠实模拟"挂的就是原始那份"。
reset_tree
rm -f "$B/mod/state/owned"
printf 'stale\n' > "$B/mod/state/active.xml"        # 残留的旧副本
rm -f "$TARGET"
ln "$SRCXML" "$TARGET" 2>/dev/null || cp "$SRCXML" "$TARGET"
{ printf '%s\n' "$TARGET"; } > "$B/mounts"
sync_mountinfo
HA_RT_OURS_TEST=no
MOCK_MOUNT=ok
MOCK_UMOUNT=ok
NO_SYNC_MOUNTINFO=1
run_rt recover
echo "  (rc=$RC) $(printf '%s' "$OUT" | tr '\n' ' ')"
[ "$RC" = "0" ] && ok "放行（不误报冲突）" || bad "误报冲突（$OUT）"
printf '%s' "$OUT" | grep -q 'overlay_changed_by_another_module' && bad "把调音模块自己的层当成冲突了" || ok "未报 overlay_changed"
grep -qF "$TARGET" "$B/mounts" && ok "调音模块自己的层未被摘" || bad "把调音模块的层摘掉了"

echo ""
echo "############ 5. 开机护栏：残留 pending => 强制原始配置 ############"
reset_mocks
reset_tree
printf 'sound\n' > "$B/mod/state/pending"
HA_RT_OURS_TEST=yes
MOCK_MOUNT=ok
MOCK_UMOUNT=ok
run_rt boot
echo "  (rc=$RC) $(printf '%s' "$OUT" | tr '\n' ' ')"
printf '%s' "$OUT" | grep -q 'guard=' && ok "报告了护栏" || bad "没报护栏"
grep -q 'interrupted_startup_or_transition' "$B/mod/state/boot.failure" 2>/dev/null && ok "记录了 interrupted_startup_or_transition" || bad "未记录原因"
[ "$(tr -d ' \r\n' < "$B/mod/mode")" = "fast" ] && ok "强制 mode=fast" || bad "mode 不对"
[ -f "$B/mod/state/pending" ] && bad "pending 未清" || ok "pending 已清"
[ -s "$B/mounts" ] && bad "护栏下不应做挂载" || ok "未做端口补丁（符合护栏语义）"

echo ""
echo "############ 6. 开机正常路径 + 去重 ############"
reset_mocks
reset_tree
HA_RT_OURS_TEST=yes
HA_RT_TARGET_STAT="$B/mod/state/active.xml"
MOCK_MOUNT=ok
MOCK_UMOUNT=ok
run_rt boot
echo "  第一次: (rc=$RC) $(printf '%s' "$OUT" | tr '\n' ' ')"
[ -s "$B/mod/state/boot" ] && ok "记录了本次 boot_id" || bad "未记录 boot_id"
[ "$(tr -d ' \r\n' < "$B/mod/mode")" = "sound" ] && ok "按 mode 文件应用了 sound" || bad "mode 不对"
NO_SYNC_MOUNTINFO=1
HA_RT_OURS_TEST=yes
MOCK_MOUNT=ok
MOCK_UMOUNT=ok
run_rt boot
printf '%s' "$OUT" | grep -q 'already_ran=1' && ok "同一次启动被去重（already_ran=1）" || bad "未去重（$OUT）"
[ -s "$B/mounts" ] && ok "去重后未重复施加补丁" || bad "去重后又建立了挂载"

echo ""
echo "############ 7. 换 boot_id 应重新应用 ############"
printf 'fake-boot-id-2\n' > "$B/boot_id"
HA_RT_OURS_TEST=yes
HA_RT_TARGET_STAT="$B/mod/state/active.xml"
MOCK_MOUNT=ok
MOCK_UMOUNT=ok
run_rt boot
[ "$(tr -d ' \r\n' < "$B/mod/state/boot")" = "fake-boot-id-2" ] && ok "boot_id 已更新并重新应用" || bad "未重新应用"

echo ""
echo "############ 8. 有我们的层、但已被他人覆盖 => 拒绝 umount ############"
reset_mocks
reset_tree
apply_sound_ok >/dev/null 2>&1
# 场景：我们建立过层（active.xml 在），但路径上现在挂的不是它。
# 验收标准：报 overlay_changed_by_another_module，且**不动**那一层。
# 用显式钩子指定"不是我们的"：主机侧伪造不了 dev:ino 证据。
# 注意：mount 是运行时才记进挂载表的，而 run_rt 只在运行前同步 mountinfo，
# 所以这里必须再同步一次，否则 runtime.sh 会认为"根本没挂着"。
NO_SYNC_MOUNTINFO=1
HA_RT_OURS_TEST=no
MOCK_MOUNT=ok
MOCK_UMOUNT=ok
sync_mountinfo
run_rt recover
echo "  (rc=$RC) $(printf '%s' "$OUT" | tr '\n' ' ')"
[ "$RC" != "0" ] && ok "返回非零" || bad "居然成功了"
printf '%s' "$OUT" | grep -q 'overlay_changed_by_another_module' && ok "拒绝覆盖他人挂载" || bad "错误名不对（$OUT）"
grep -qF "$TARGET" "$B/mounts" && ok "他人的挂载确实没被摘" || bad "把他人的挂载摘掉了"

echo ""
echo "############ 8c. 我们从未建立层、目标被他人挂载 => 必须放行 ############"
# 真机上踩到的场景：模块刚装上、首次开机，/odm 上挂着的是调音模块自己的
# bind mount。此时既没有 active.xml 也没有 owned 标记 —— 这不是冲突，
# 不能因此判定 overlay_changed 并触发回滚/开机护栏。
reset_mocks
reset_tree
rm -f "$B/mod/state/active.xml" "$B/mod/state/owned"
{ printf '%s\n' "$TARGET"; } > "$B/mounts"
sync_mountinfo
HA_RT_OURS_TEST=no
MOCK_MOUNT=ok
MOCK_UMOUNT=ok
NO_SYNC_MOUNTINFO=1
run_rt recover
echo "  (rc=$RC) $(printf '%s' "$OUT" | tr '\n' ' ')"
[ "$RC" = "0" ] && ok "放行（不误报冲突）" || bad "误报冲突（$OUT）"
printf '%s' "$OUT" | grep -q 'overlay_changed_by_another_module' && bad "把调音模块自己的层当成冲突了" || ok "未报 overlay_changed"
grep -qF "$TARGET" "$B/mounts" && ok "调音模块自己的层完好" || bad "把调音模块的层摘掉了"
# 同一场景下 apply sound 也必须能正常建立我们的层
reset_mocks
reset_tree
rm -f "$B/mod/state/active.xml" "$B/mod/state/owned"
{ printf '%s\n' "$TARGET"; } > "$B/mounts"
sync_mountinfo
HA_RT_OURS_TEST=yes
HA_RT_TARGET_STAT="$B/mod/state/active.xml"
NO_SYNC_MOUNTINFO=1
run_rt apply sound
[ "$RC" = "0" ] && ok "首次开机可直接进入音效模式" || bad "首次 apply 失败（$OUT）"

echo ""
echo "############ 8b. 退路判据：没有挂载记录时不得去动别人的东西 ############"
reset_mocks
reset_tree
apply_sound_ok >/dev/null 2>&1
printf '%s\n' "$B/other" > "$B/mounts"
: > "$B/mountinfo"          # mountinfo 里没有目标 => target_mounted 为假
NO_SYNC_MOUNTINFO=1 HA_RT_OURS_TEST= MOCK_MOUNT=ok MOCK_UMOUNT=ok run_rt recover
echo "  (rc=$RC) $(printf '%s' "$OUT" | tr '\n' ' ')"
[ "$RC" = "0" ] && ok "无挂载记录时正常收尾" || bad "不该失败（$OUT）"
grep -qF "$B/other" "$B/mounts" && ok "未触碰并非我们建立的挂载" || bad "动了别人的挂载"

echo ""
echo "############ 9. umount 失败 => 要求重启 ############"
reset_mocks
reset_tree
apply_sound_ok >/dev/null 2>&1
sync_mountinfo
NO_SYNC_MOUNTINFO=1
HA_RT_OURS_TEST=yes
HA_RT_TARGET_STAT="$B/mod/state/active.xml"
MOCK_MOUNT=ok
MOCK_UMOUNT=fail
run_rt recover
echo "  (rc=$RC) $(printf '%s' "$OUT" | tr '\n' ' ')"
[ "$RC" != "0" ] && ok "返回非零" || bad "居然成功了"
printf '%s' "$OUT" | grep -q 'unmount_failed_reboot_required' && ok "报 unmount_failed_reboot_required" || bad "错误名不对（$OUT）"

echo ""
echo "############ 10. recover：撤销一切 ############"
reset_mocks
reset_tree
apply_sound_ok >/dev/null 2>&1
printf 'sound\n' > "$B/mod/state/pending"
printf 'apply_previous_failed\n' > "$B/mod/state/boot.failure"
HA_RT_OURS_TEST=yes
HA_RT_TARGET_STAT="$B/mod/state/active.xml"
MOCK_MOUNT=ok
MOCK_UMOUNT=ok
run_rt recover
echo "  (rc=$RC) $(printf '%s' "$OUT" | tr '\n' ' ')"
[ "$RC" = "0" ] && ok "recover 成功" || bad "recover 失败"
[ -f "$B/mod/state/active.xml" ] && bad "active.xml 残留" || ok "active.xml 已清"
[ -f "$B/mod/state/pending" ] && bad "pending 残留" || ok "pending 已清"
[ -f "$B/mod/state/boot.failure" ] && bad "boot.failure 残留" || ok "boot.failure 已清"
[ -s "$B/mounts" ] && bad "挂载残留" || ok "挂载已清"
[ "$(tr -d ' \r\n' < "$B/mod/mode")" = "fast" ] && ok "mode=fast" || bad "mode 不对"

echo ""
echo "############ 11. 没有调音模块 / 畸形模式参数 ############"
reset_mocks
reset_tree
rm -f "$SRCXML"
HA_RT_OURS_TEST=yes
MOCK_MOUNT=ok
MOCK_UMOUNT=ok
run_rt apply sound
printf '%s' "$OUT" | grep -q 'no_tuning_config' && ok "缺调音模块报 no_tuning_config" || bad "错误名不对（$OUT）"
reset_mocks
reset_tree
HA_RT_OURS_TEST=yes
MOCK_MOUNT=ok
MOCK_UMOUNT=ok
run_rt apply bogus
printf '%s' "$OUT" | grep -q 'bad_mode' && ok "非法模式报 bad_mode" || bad "错误名不对（$OUT）"

echo ""
echo "############ 结果 ############"
echo "  通过 $pass，失败 $fail"
rm -rf "$B"
[ "$fail" = "0" ]
