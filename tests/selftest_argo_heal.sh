#!/usr/bin/env bash
# 沙箱自测：验证 argo_guard 假死自愈 + argo_heal 全流程（不打真实网络）
set -u
DIST="$(cd "$(dirname "$0")/.." && pwd)/dist/sb.sh"
SBX="$(mktemp -d)"
# 提取 lib 区段；先导出沙箱变量再 source，最后用桩覆盖被测函数的依赖
sed -n '/^# @BEGIN LIBS@/,/^# @END LIBS@/p' "$DIST" > "$SBX/lib.sh"
export SB_DIR="$SBX" ARGO_LOG="$SBX/argo.log" ARGO_PID_FILE="$SBX/argo.pid"
export PORT_VMESS=8080 SUB_PORT=8081
export SCRIPT_URL=   # 沙箱不做联网自更新
source "$SBX/lib.sh"

# ---------- 桩（必须在 source 之后定义才能生效） ----------
ok(){ echo "[ok] $*"; }
err(){ echo "[err] $*"; }
warn(){ echo "[warn] $*"; }
info(){ echo "[info] $*"; }
line(){ :; }
need_root(){ :; }
load_state(){ :; }
save_state(){ echo "ARGO_MODE=$ARGO_MODE" > "$SBX/state.written"; }
build_subscription(){ echo "sub rebuilt with domain=$ARGO_DOMAIN" >> "$SBX/state.written"; }
sub_ensure_webroot(){ :; }
sb_is_running(){ return 1; }
sb_restart(){ :; }
sb_stop(){ :; }
argo_enable_boot(){ echo "boot-registered" >> "$SBX/state.written"; }

export SB_DIR="$SBX" ARGO_LOG="$SBX/argo.log" ARGO_PID_FILE="$SBX/argo.pid"
export PORT_VMESS=8080 SUB_PORT=8081
export SCRIPT_URL=   # 沙箱不做联网自更新
# 假 cloudflared：立刻写一个新域名到 stdout（会被重定向进 ARGO_LOG）
printf '#!/usr/bin/env bash\necho "conn... https://new-%s.trycloudflare.com registered"\nsleep 300\n' "$$" > "$SBX/fake-cf"
chmod +x "$SBX/fake-cf"
CF_BIN="$SBX/fake-cf"

PASS=0; FAIL=0
chk(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  [PASS] $1"; else FAIL=$((FAIL+1)); echo "  [FAIL] $1 (got: $2, want: $3)"; fi; }

echo "=== 用例1：进程活着但日志没域名（假死）→ guard 自动重启换新域名 ==="
ARGO_MODE="temp"; ARGO_DOMAIN="old-dead.trycloudflare.com"
sleep 300 & ZOMBIE=$!
echo "$ZOMBIE" > "$ARGO_PID_FILE"
echo "2024-01-01 old boot, no url here" > "$ARGO_LOG"   # 旧日志：mtime 超过 2 分钟
touch -d "5 minutes ago" "$ARGO_LOG"
argo_guard
NEWDOM="$(argo_domain_from_log)"
case "$NEWDOM" in new-*) chk "假死被识别且换到新域名" "yes" "yes";; *) chk "假死被识别且换到新域名" "$NEWDOM" "new-*";; esac
kill -0 "$ZOMBIE" 2>/dev/null && chk "旧假死进程已被清理" "alive" "dead" || chk "旧假死进程已被清理" "dead" "dead"
grep -q "sub rebuilt with domain=$NEWDOM" "$SBX/state.written" 2>/dev/null && chk "订阅已用新域名重建" yes yes || chk "订阅已用新域名重建" no yes

echo "=== 用例2：日志 2 分钟内有动静（正在重连）→ guard 不误杀 ==="
ARGO_MODE="temp"; echo "$$" > "$ARGO_PID_FILE"   # 借用当前 shell 的 pid（活着）
echo "retrying edge..." > "$ARGO_LOG"            # 刚写 → mtime 新鲜
BEFORE_PID="$(argo_pid)"
argo_guard
chk "新鲜日志不被重启" "$(argo_pid)" "$BEFORE_PID"

echo "=== 用例3：argo_heal 在 ARGO_MODE=none 时安全完成 ==="
rm -f "$ARGO_PID_FILE" "$ARGO_LOG" "$SBX/state.written"
ARGO_MODE="none"
argo_heal; chk "mode=none 自愈返回 0" "$?" "0"

echo "=== 用例4：argo_heal 对假死隧道完成全链路修复 ==="
ARGO_MODE="temp"; ARGO_DOMAIN="old-dead.trycloudflare.com"
sleep 300 & Z2=$!
echo "$Z2" > "$ARGO_PID_FILE"
echo "2024-01-01 dead" > "$ARGO_LOG"; touch -d "30 minutes ago" "$ARGO_LOG"
argo_heal; RC=$?
case "$(argo_domain_from_log)" in new-*) D=yes;; *) D=no;; esac
chk "heal 返回 0" "$RC" "0"
chk "heal 后拿到新域名" "$D" "yes"
grep -q "boot-registered" "$SBX/state.written" && chk "保活注册已补上" yes yes || chk "保活注册已补上" no yes

echo "=== 用例5：argo_off（--direct）在 IP4/IP6 未初始化时不崩溃（回归：IP4 unbound variable）==="
unset IP4 IP6 NODE_ADDR IPSTACK
detect_ip(){ :; }   # 桩掉 IP 探测，模拟"独立运行 --direct 且探测失败"的最坏情况
argo_stop(){ :; }
build_config(){ echo "config built" >> "$SBX/state.written"; }
ARGO_MODE="temp"
argo_off; RC=$?
chk "argo_off 返回 0（不再 unbound 崩溃）" "$RC" "0"
chk "node_host 无 IP 时兜底 127.0.0.1" "$(node_host)" "127.0.0.1"
grep -q "config built" "$SBX/state.written" && chk "配置已重建" yes yes || chk "配置已重建" no yes
chk "状态已切到 ARGO_MODE=none" "$(grep -o 'ARGO_MODE=none' "$SBX/state.written" | head -n1)" "ARGO_MODE=none"
unset -f detect_ip   # 恢复真实函数，避免影响后续用例

echo
echo "通过: $PASS  失败: $FAIL"

echo
echo "通过: $PASS  失败: $FAIL"
rm -rf "$SBX" 2>/dev/null
[ "$FAIL" = "0" ]
