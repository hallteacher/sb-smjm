#!/usr/bin/env bash
# ============================================================
# run_tests.sh - 本地可执行的逻辑测试（不需要 VPS / root / sing-box）
# 1) 所有脚本语法检查
# 2) source lib，用假参数生成五协议配置，校验 JSON 合法性
# 3) 生成节点链接并校验：vmess 的 base64 能解码、各链接含必要参数
# 4) 非交互管道输入：printf 喂菜单能正常退出
# ============================================================
set -uo pipefail

cd "$(dirname "$0")/.."
export PATH="/usr/bin:/bin:$PATH"
# 测试全程禁止真实外网探测（fetch_public_ip 见 SB_NO_NETWORK），否则 dist 子进程里的
# detect_ip 会逐个等 curl 超时，把整个套件拖过 30 秒
export SB_NO_NETWORK=1

PASS=0; FAIL=0
ok_t()   { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
fail_t() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
say()    { printf '\n%s=== %s ===%s\n' "" "$1" ""; }

# python3 可用时做 JSON 校验，否则用简易括号配平检查
json_check() {
  local f="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" 2>/dev/null
  else
    # 简易：花括号/方括号配平
    local o c
    o=$(tr -cd '{' < "$f" | wc -c); c=$(tr -cd '}' < "$f" | wc -c)
    [ "$o" -eq "$c" ] || return 1
    o=$(tr -cd '[' < "$f" | wc -c); c=$(tr -cd ']' < "$f" | wc -c)
    [ "$o" -eq "$c" ] || return 1
  fi
}

say "1) 语法检查 bash -n"
for f in sb.sh serv00.sh build.sh lib/*.sh dist/*.sh; do
  [ -f "$f" ] || continue
  if bash -n "$f" 2>/dev/null; then ok_t "$f"; else fail_t "$f"; fi
done

say "2) 单元：rand_uuid / rand_hex / rand_password / b64 / url_encode"
# shellcheck disable=SC1091
source lib/common.sh
_u=$(rand_uuid)
if printf '%s' "$_u" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
  ok_t "uuid 格式: $_u"
else
  fail_t "uuid 格式异常: $_u"
fi
_h=$(rand_hex 8)
if [ ${#_h} -eq 16 ] && printf '%s' "$_h" | grep -qE '^[0-9a-f]+$'; then
  ok_t "rand_hex 8 字节 = 16 个十六进制字符"
else
  fail_t "rand_hex 异常: $_h"
fi
_p=$(rand_password 20)
if [ ${#_p} -eq 20 ] && ! printf '%s' "$_p" | grep -qE '[0O1l]'; then
  ok_t "rand_password 长度 20 且无易混字符"
else
  fail_t "rand_password 异常: $_p"
fi
_e=$(printf 'hello world' | b64)
if [ "$_e" = "aGVsbG8gd29ybGQ=" ]; then ok_t "b64 编码正确"; else fail_t "b64 异常: $_e"; fi
if [ "$(url_encode '节点 测试')" != "节点 测试" ]; then ok_t "url_encode 可用"; else warn "url_encode 仅 ASCII 兜底"; fi

say "2b) 单元：is_private_ip（云主机内网 IP 不得混入节点链接）"
for _a in 10.0.0.1 127.0.0.1 172.16.0.1 172.26.15.104 172.31.255.254 192.168.1.1 169.254.169.254 100.64.0.1 fe80::1 fd00::1 fc00::1; do
  is_private_ip "$_a" && ok_t "私网判定: $_a" || fail_t "漏判私网: $_a"
done
for _a in 13.55.13.192 8.8.8.8 1.1.1.1 2406:da1c:1917:8a00:3e6d:535:a284:cdd7 2606:4700:4700::1111; do
  ! is_private_ip "$_a" && ok_t "公网判定: $_a" || fail_t "误判公网为私网: $_a"
done

say "2c) 单元：fetch_public_ip 拒绝私网地址（AWS 网卡 IP 场景回归）"
mkdir -p /tmp/sb-fakebin
printf '#!/usr/bin/env bash\necho 172.31.0.5\n' > /tmp/sb-fakebin/curl
chmod +x /tmp/sb-fakebin/curl
_fp=$(SB_NO_NETWORK=0 PATH=/tmp/sb-fakebin:$PATH fetch_public_ip 4 2>/dev/null) || _fp=""
[ -z "$_fp" ] && ok_t "fetch_public_ip 过滤私网 IP" || fail_t "fetch_public_ip 放过私网: $_fp"
printf '#!/usr/bin/env bash\necho 13.55.13.192\n' > /tmp/sb-fakebin/curl
_fp=$(SB_NO_NETWORK=0 PATH=/tmp/sb-fakebin:$PATH fetch_public_ip 4 2>/dev/null) || _fp=""
[ "$_fp" = "13.55.13.192" ] && ok_t "fetch_public_ip 返回公网 IP" || fail_t "fetch_public_ip 异常: ${_fp:-空}"
rm -rf /tmp/sb-fakebin

say "2d) 单元：订阅地址推导 sub_url / 状态页二维码"
SB_DIR=/tmp/sb-smjm-test
# shellcheck disable=SC1091
source lib/subscription.sh
NODE_ADDR="13.55.13.192"; SUB_PORT=8199; SUB_PASSWORD=""; SUB_URL=""
_su=$(sub_url)
[ "$_su" = "http://13.55.13.192:8199/sub" ] && ok_t "sub_url 无密码: $_su" || fail_t "sub_url 异常: $_su"
SUB_PASSWORD="pw123"
_su=$(sub_url)
[ "$_su" = "http://13.55.13.192:8199/pw123/sub" ] && ok_t "sub_url 带密码: $_su" || fail_t "sub_url 异常: $_su"
NODE_ADDR=""; IP4="203.0.113.9"
_su=$(sub_url)
[ "$_su" = "http://203.0.113.9:8199/pw123/sub" ] && ok_t "sub_url 自动回退到 IP4" || fail_t "sub_url 回退失败: $_su"
NODE_ADDR="2406:da1c::1"; IP4=""; SUB_PASSWORD=""; SUB_PORT=8443
_su=$(sub_url)
[ "$_su" = "http://[2406:da1c::1]:8443/sub" ] && ok_t "sub_url IPv6 自动加方括号: $_su" || fail_t "sub_url IPv6 异常: $_su"
unset NODE_ADDR IP4 SUB_PORT SUB_PASSWORD SUB_URL
grep -q 'qrencode -t ANSIUTF8' lib/subscription.sh \
  && ok_t "状态页二维码渲染存在（qrencode ANSIUTF8）" || fail_t "缺少二维码渲染"
grep -q 'SUB_URL:-$(sub_url)' lib/subscription.sh \
  && ok_t "show_subscription 兜底推导订阅地址（不再误报「未启动」）" || fail_t "show_subscription 仍依赖会话内 SUB_URL"

say "3) 五协议配置生成 + JSON 合法性"
mkdir -p /tmp/sb-smjm-test
SB_DIR=/tmp/sb-smjm-test
SB_BIN=/nonexistent/sing-box
# shellcheck disable=SC1091
source lib/config.sh

UUID="test-uuid-0000-0000-000000000000"
PORT_VLESS=443; PORT_VMESS=8080; PORT_VMESS_TLS=2053
PORT_HY2=8443; PORT_TUIC=8444; PORT_ANYTLS=8445
VMESS_PATH="/vmes"
REALITY_SNI="www.yahoo.com"; TLS_SNI="www.bing.com"
REALITY_PRIVATE="testprivatekey"; REALITY_PUBLIC="testpublickey"; REALITY_SHORT="0123456789abcdef"
HY2_PASSWORD="hy2pass"; TUIC_PASSWORD="tuicpass"; ANYTLS_PASSWORD="anytlspass"
VMESS_LISTEN="127.0.0.1"

inbound_vless        > /tmp/sb-smjm-test/in_vless.json
inbound_vmess_ws     > /tmp/sb-smjm-test/in_vmess.json
inbound_vmess_ws_tls > /tmp/sb-smjm-test/in_vmess_tls.json
inbound_hysteria2    > /tmp/sb-smjm-test/in_hy2.json
inbound_tuic         > /tmp/sb-smjm-test/in_tuic.json
inbound_anytls       > /tmp/sb-smjm-test/in_anytls.json

for f in /tmp/sb-smjm-test/in_*.json; do
  if json_check "$f" 2>/dev/null; then ok_t "$(basename "$f") JSON 合法"; else fail_t "$(basename "$f") JSON 非法"; cat "$f"; fi
done

say "4) build_config 完整配置组装"
ENABLE_VLESS=y; ENABLE_VMESS=y; ENABLE_VMESS_TLS=y
ENABLE_HY2=y; ENABLE_TUIC=y; ENABLE_ANYTLS=y
IPSTACK="dual"
if build_config 2>/dev/null && json_check "$SB_DIR/config.json" 2>/dev/null; then
  ok_t "完整 config.json 生成且 JSON 合法（6 个 inbound）"
else
  fail_t "build_config 失败或 JSON 非法"
  cat "$SB_DIR/config.json" 2>/dev/null
fi
# inbound 数量应为 6
if command -v python3 >/dev/null 2>&1; then
  _n=$(python3 -c "import json;print(len(json.load(open('$SB_DIR/config.json'))['inbounds']))" 2>/dev/null)
  [ "$_n" = "6" ] && ok_t "inbound 数量 = 6" || fail_t "inbound 数量异常: $_n"
fi

# 回归：sing-box 1.13.0 移除 inbound 的 sniff、1.14.0 移除 outbound 的 legacy domain_strategy
#       配置里若残留这些字段，sing-box 1.14.x 会直接拒绝启动（节点全部 -1 不通）
if grep -q '"sniff"' "$SB_DIR/config.json" 2>/dev/null; then
  fail_t "config.json 含已移除的 sniff 字段（sing-box>=1.13 拒绝启动）"
else
  ok_t "config.json 不含已移除的 sniff 字段"
fi
if grep -q '"domain_strategy"' "$SB_DIR/config.json" 2>/dev/null; then
  fail_t "config.json 含已移除的 legacy domain_strategy（sing-box>=1.14 拒绝启动）"
else
  ok_t "config.json 不含已移除的 legacy domain_strategy"
fi

say "5) 节点链接生成与解析"
IP4="1.2.3.4"; IP6=""; NODE_NAME="test"
# shellcheck disable=SC1091
source lib/subscription.sh
build_subscription 2>/dev/null

_links=$(cat "$SB_DIR/nodes.txt" 2>/dev/null)
_n=$(printf '%s\n' "$_links" | grep -c '://' 2>/dev/null || echo 0)
[ "$_n" -ge 6 ] && ok_t "生成 $_n 条节点链接（>=6）" || fail_t "节点链接数量不足: $_n"

# vless 链接必要参数
if printf '%s\n' "$_links" | grep -q '^vless://.*security=reality.*pbk=testpublickey.*sid=0123456789abcdef'; then
  ok_t "vless-reality 链接参数完整"
else
  fail_t "vless-reality 链接异常"
  printf '%s\n' "$_links" | grep '^vless://' || true
fi

# hysteria2 / tuic / anytls 链接
printf '%s\n' "$_links" | grep -q '^hysteria2://hy2pass@1.2.3.4:8443/?insecure=1' && ok_t "hysteria2 链接正常" || fail_t "hysteria2 链接异常"
printf '%s\n' "$_links" | grep -q '^tuic://.*tuicpass@1.2.3.4:8444?congestion_control=bbr' && ok_t "tuic 链接正常" || fail_t "tuic 链接异常"

# 回归：首次安装场景（state.env 不存在 => REALITY_SNI/TLS_SNI 未初始化）
# build_config / build_subscription 必须用 _DEFAULT 兜底，不得因 set -u 报 unbound
say "5b) 回归：SNI 未初始化的首次安装场景"
(
  unset REALITY_SNI TLS_SNI
  if build_config 2>/tmp/sb-smjm-test/unbound.err \
     && json_check "$SB_DIR/config.json" 2>/dev/null; then
    ok_t "SNI 缺失时 build_config 仍生成合法 JSON"
  else
    fail_t "SNI 缺失时 build_config 异常"; cat /tmp/sb-smjm-test/unbound.err
  fi
  unset REALITY_SNI TLS_SNI
  if build_subscription 2>>/tmp/sb-smjm-test/unbound.err; then
    ok_t "SNI 缺失时 build_subscription 正常（默认 SNI 兜底）"
  else
    fail_t "SNI 缺失时 build_subscription 异常"; cat /tmp/sb-smjm-test/unbound.err
  fi
  grep -q '"server_name": "www.yahoo.com"' "$SB_DIR/config.json" \
    && ok_t "reality server_name 已用默认值兜底" || fail_t "reality server_name 为空"
)

printf '%s\n' "$_links" | grep -q '^anytls://anytlspass@1.2.3.4:8445/?insecure=1' && ok_t "anytls 链接正常" || fail_t "anytls 链接异常"

# vmess 的 base64 载荷必须可解码且含 add/port/id
_v=$(printf '%s\n' "$_links" | grep '^vmess://' | head -n1 | sed 's#^vmess://##')
if [ -n "$_v" ] && command -v base64 >/dev/null 2>&1; then
  _d=$(printf '%s' "$_v" | base64 -d 2>/dev/null || printf '%s' "$_v" | base64 -d - 2>/dev/null)
  case "$_d" in
    *'"add":"1.2.3.4"'*'"port":"8080"'*'"id":"test-uuid-0000-0000-000000000000"'*)
      ok_t "vmess base64 载荷可解码且字段完整" ;;
    *) fail_t "vmess 载荷异常: $_d" ;;
  esac
else
  fail_t "未找到 vmess 链接或无 base64"
fi

# 订阅文件必须是有效 base64
if command -v base64 >/dev/null 2>&1 && [ -s "$SB_DIR/sub.txt" ]; then
  if base64 -d < "$SB_DIR/sub.txt" >/dev/null 2>&1; then
    ok_t "sub.txt 是有效 base64 订阅"
  else
    fail_t "sub.txt base64 非法"
  fi
fi

say "6) 非交互管道输入（printf 喂菜单）"
# 菜单选项 2 = 查看状态（不需要 root），0/EOF 应自动退出
_out=$(printf '2\n' | bash dist/sb.sh 2>&1)
_rc=$?
if [ $_rc -eq 0 ] && printf '%s' "$_out" | grep -q '当前状态'; then
  ok_t "printf '2' | sb.sh 能查看状态并正常退出（rc=$_rc）"
else
  fail_t "非交互模式异常 (rc=$_rc)"
  printf '%s\n' "$_out" | tail -n 5
fi
# usage 参数
if bash dist/sb.sh --help 2>&1 | grep -q '用法'; then ok_t "--help 正常"; else fail_t "--help 异常"; fi

say "7) serv00.sh 专项（三协议 + 非交互 + 用法）"
# serv00 三协议默认开关应为 y，其余 n（避免装出 6 个协议）
_s=$(grep -c 'ENABLE_VLESS=\${ENABLE_VLESS:-y}' serv00.sh)
[ "$_s" -ge 1 ] && ok_t "serv00 默认启用 VLESS" || fail_t "serv00 默认开关异常"
# serv00 不得依赖 root（不应出现 need_root 调用）
if grep -q 'need_root' serv00.sh; then fail_t "serv00 不应调用 need_root（共享主机无 root）"; else ok_t "serv00 无 need_root 依赖"; fi
# serv00 二进制路径必须落在 $HOME 下
if grep -q 'SB_BIN="\${SB_BIN:-\$HOME_DIR' serv00.sh; then ok_t "serv00 二进制路径在 \$HOME 下"; else fail_t "serv00 二进制路径异常"; fi
# serv00 非交互：选项 2 查看状态应正常退出（ serv00 无状态文件时会提示未运行 ）
_out=$(printf '2\n' | bash dist/serv00.sh 2>&1)
_rc=$?
if [ $_rc -eq 0 ] && printf '%s' "$_out" | grep -q 'sb-smjm (serv00)'; then
  ok_t "printf '2' | serv00.sh 能查看状态并正常退出（rc=$_rc）"
else
  fail_t "serv00 非交互模式异常 (rc=$_rc)"
  printf '%s\n' "$_out" | tail -n 5
fi
# serv00 --help
if bash dist/serv00.sh --help 2>&1 | grep -q 'serv00'; then ok_t "serv00 --help 正常"; else fail_t "serv00 --help 异常"; fi

# 三条频道链接必须存在（博客 / YouTube / Telegram）
say "8) 频道链接完整性（博客 / YouTube / Telegram）"
for f in lib/common.sh README.md dist/sb.sh dist/serv00.sh; do
  _miss=0
  grep -q 'smjmblog.blogspot.com'        "$f" || _miss=$((_miss+1))
  grep -q 'youtube.com/@DECODING-w7d'    "$f" || _miss=$((_miss+1))
  grep -q 't.me/+tVg48WK48tlkNGVl'       "$f" || _miss=$((_miss+1))
  if [ "$_miss" -eq 0 ]; then ok_t "$f 三条链接齐全"; else fail_t "$f 缺少 $_miss 条链接"; fi
done
# show_about 函数定义必须存在于 common.sh
grep -q 'show_about()' lib/common.sh && ok_t "common.sh 已定义 show_about()" || fail_t "common.sh 缺少 show_about()"
# sb.sh / serv00.sh 必须调用 show_about
grep -q 'show_about' sb.sh    && ok_t "sb.sh 调用 show_about"    || fail_t "sb.sh 未调用 show_about"
grep -q 'show_about' serv00.sh && ok_t "serv00.sh 调用 show_about" || fail_t "serv00.sh 未调用 show_about"

say "9) Argo 保活：argo_boot.sh 生成 + 临时隧道域名自动同步"
# 回归背景：argo_boot.sh 曾被 boot.sh / crontab / README 引用，但项目里从未生成过它；
# 且 trycloudflare 临时域名每次重启都会变，旧订阅会一直指向失效域名（只有 Argo 线连不上）。
mkdir -p /tmp/sb-smjm-argo
SB_DIR=/tmp/sb-smjm-argo
ARGO_LOG="$SB_DIR/argo.log"
ARGO_PID_FILE="$SB_DIR/argo.pid"
ARGO_BOOT_FILE="$SB_DIR/argo_boot.sh"
# shellcheck disable=SC1091
source lib/install.sh
# shellcheck disable=SC1091
source lib/argo.sh
# shellcheck disable=SC1091
source lib/subscription.sh
save_state() { :; }   # 桩：真实实现位于 sb.sh

# 脚本自持久化（argo_boot.sh 依赖它拿到固定路径的完整脚本）
if _sp=$(sb_self_persist "tests/run_tests.sh") && [ -f "$_sp" ]; then
  ok_t "sb_self_persist 落盘到 $_sp"
else
  fail_t "sb_self_persist 失败"
fi

argo_write_boot_script >/dev/null 2>&1
if [ -x "$ARGO_BOOT_FILE" ]; then
  ok_t "argo_boot.sh 已真正生成且可执行（原先只被引用、无人生成）"
else
  fail_t "argo_boot.sh 未被生成"
fi
grep -q -- '--argo-guard' "$ARGO_BOOT_FILE" 2>/dev/null \
  && ok_t "argo_boot.sh 通过 --argo-guard 复用主脚本" || fail_t "argo_boot.sh 内容异常"
# 生成者必须在 lib/argo.sh 里（防止再次退化成"只引用不生成"）
grep -q 'ARGO_BOOT_FILE' lib/argo.sh && ok_t "lib/argo.sh 持有 argo_boot.sh 生成逻辑" || fail_t "缺少生成逻辑"
grep -q -- '--argo-guard' sb.sh && ok_t "sb.sh 暴露 --argo-guard 入口" || fail_t "sb.sh 缺少 --argo-guard"
grep -q -- '--argo-guard' dist/sb.sh && ok_t "dist/sb.sh 已含 --argo-guard（发布产物同步）" || fail_t "dist/sb.sh 未同步"

# 域名解析：日志里有多条时必须取最后一条（即当前生效的域名）
printf '%s\n' \
  'INF |  https://first-old-name.trycloudflare.com                     |' \
  'INF |  https://current-live-name.trycloudflare.com                  |' > "$ARGO_LOG"
_dom=$(argo_domain_from_log)
if [ "$_dom" = "current-live-name.trycloudflare.com" ]; then
  ok_t "argo_domain_from_log 取到最新域名: $_dom"
else
  fail_t "argo_domain_from_log 异常: $_dom"
fi

# 核心回归：隧道换域名后，state 与订阅里的 vmess 地址都必须跟着换
UUID="test-uuid-0000-0000-000000000000"
NODE_NAME="sb-smjm"; NODE_ADDR=""
PORT_VMESS=8080; VMESS_PATH="/vmes"
ENABLE_VMESS=y; ENABLE_VLESS=n; ENABLE_VMESS_TLS=n
ENABLE_HY2=n; ENABLE_TUIC=n; ENABLE_ANYTLS=n
ARGO_MODE=temp; ARGO_DOMAIN="stale-dead-name.trycloudflare.com"
if argo_sync_domain >/dev/null 2>&1; then
  ok_t "argo_sync_domain 检测到域名变化"
else
  fail_t "argo_sync_domain 未检测到域名变化"
fi
if [ "$ARGO_DOMAIN" = "current-live-name.trycloudflare.com" ]; then
  ok_t "state 里的 ARGO_DOMAIN 已更新为新域名"
else
  fail_t "ARGO_DOMAIN 未更新: $ARGO_DOMAIN"
fi
_vp=$(grep '^vmess://' "$SB_DIR/nodes.txt" 2>/dev/null | head -n1 | sed 's#^vmess://##')
_vd=$(printf '%s' "$_vp" | base64 -d 2>/dev/null || true)
case "$_vd" in
  *'"add":"current-live-name.trycloudflare.com"'*)
    ok_t "订阅里的 vmess 地址已换成新域名（-1 的直接原因已消除）" ;;
  *) fail_t "订阅未随域名更新: $_vd" ;;
esac
# 幂等：域名没变时不得重复重建订阅
if argo_sync_domain >/dev/null 2>&1; then
  fail_t "域名未变时不应触发同步"
else
  ok_t "域名未变时 argo_sync_domain 正确跳过（幂等）"
fi

# --argo-guard 入口：ARGO_MODE=none 时必须安全退出
export SB_DIR=/tmp/sb-smjm-argo-none
mkdir -p "$SB_DIR"
printf 'ARGO_MODE=none\n' > "$SB_DIR/state.env"
_ag=$(bash dist/sb.sh --argo-guard 2>&1); _rc=$?
if [ $_rc -eq 0 ]; then
  ok_t "--argo-guard 在未装 Argo 时安全退出 (rc=0)"
else
  fail_t "--argo-guard 异常 (rc=$_rc): $_ag"
fi

say "10) 一键安装必须生成 sb 命令与 boot.sh（原先只有菜单 10 才生成）"
# 回归背景：README 承诺「装完后任意目录执行 sb」，但 install_all 从未调用
# install_shortcut，于是 /usr/local/bin/sb 与 $SB_DIR/boot.sh 都不会生成；而
# sb_enable_boot 在非 systemd 机器上会往 cron 写 @reboot $SB_DIR/boot.sh ——
# 又是一处「只引用不生成」的死引用（与 argo_boot.sh 同类）。
if sed -n '/^install_all()/,/^}/p' sb.sh | grep -q 'install_shortcut'; then
  ok_t "install_all 调用了 install_shortcut（一键装完即注册 sb）"
else
  fail_t "install_all 未调用 install_shortcut：一键装完没有 sb 命令也没有 boot.sh"
fi
grep -qF 'cat > "$SB_DIR/boot.sh"' sb.sh \
  && ok_t "boot.sh 有生产者（install_shortcut）" || fail_t "boot.sh 无生产者"
grep -qF 'argo_boot.sh' sb.sh \
  && ok_t "boot.sh 仍会拉起 argo_boot.sh（自启链路完整）" || fail_t "boot.sh 丢失 argo_boot.sh 引用"

# 行为验证：sb_enable_boot 在 boot.sh 缺失时不得写下指向它的 @reboot
mkdir -p /tmp/sb-smjm-boot /tmp/fakebin3
cat > /tmp/fakebin3/crontab <<'CRONEOF3'
#!/usr/bin/env bash
if [ "${1:-}" = "-l" ]; then cat /tmp/fake_crontab3 2>/dev/null; exit 0; fi
cat > /tmp/fake_crontab3
CRONEOF3
chmod +x /tmp/fakebin3/crontab
export PATH="/tmp/fakebin3:$PATH"
SB_DIR=/tmp/sb-smjm-boot
# shellcheck disable=SC1091
source lib/install.sh
have_systemd() { return 1; }

rm -f /tmp/fake_crontab3 "$SB_DIR/boot.sh"
sb_enable_boot >/dev/null 2>&1
if grep -q 'boot\.sh' /tmp/fake_crontab3 2>/dev/null; then
  fail_t "boot.sh 缺失时仍写入了 @reboot 死引用"
else
  ok_t "boot.sh 缺失时不写 @reboot（死引用已杜绝）"
fi

printf '#!/usr/bin/env bash\n' > "$SB_DIR/boot.sh"
chmod 0755 "$SB_DIR/boot.sh"
sb_enable_boot >/dev/null 2>&1
if grep -q "@reboot $SB_DIR/boot.sh" /tmp/fake_crontab3 2>/dev/null; then
  ok_t "boot.sh 存在时正常写入 @reboot"
else
  fail_t "boot.sh 存在时未写入 @reboot"
fi

say "7) 新增能力：版本号 / 自更新 / ws 路径随机化 / 内核 BBR"
grep -q 'SB_SCRIPT_VERSION=' dist/sb.sh \
  && ok_t "脚本版本号已内置（SB_SCRIPT_VERSION）" || fail_t "缺少脚本版本号"
grep -q -- '--version' dist/sb.sh \
  && ok_t "--version 入口存在" || fail_t "缺少 --version 入口"
grep -q 'sb_self_update()' dist/sb.sh \
  && ok_t "脚本自更新函数存在（sb_self_update）" || fail_t "缺少 sb_self_update"
grep -q -- '--upgrade' dist/sb.sh \
  && ok_t "--upgrade 入口存在" || fail_t "缺少 --upgrade 入口"
grep -q 'vmess-$(rand_hex' dist/sb.sh \
  && ok_t "VMess ws 路径随机化（/vmess-<random>）" || fail_t "ws 路径未随机化"
if grep -q 'VMESS_PATH=${VMESS_PATH:-/vmess}' dist/sb.sh; then
  fail_t "VPS 版默认路径仍写死 /vmess"
else
  ok_t "VPS 版不再默认写死 /vmess"
fi
grep -q 'enable_bbr()' dist/sb.sh \
  && ok_t "内核 BBR 优化函数存在（enable_bbr）" || fail_t "缺少 enable_bbr"
grep -q 'tcp_congestion_control=bbr' dist/sb.sh \
  && ok_t "BBR sysctl 参数存在" || fail_t "缺少 BBR sysctl 参数"
grep -q 'fetch_public_ip()' dist/sb.sh \
  && ok_t "公网 IP 探测已内联（fetch_public_ip：AWS 元数据 + 公共接口）" || fail_t "dist 缺少 fetch_public_ip"
grep -q 'is_private_ip()' dist/sb.sh \
  && ok_t "私网 IP 过滤已内联（is_private_ip）" || fail_t "dist 缺少 is_private_ip"
grep -q '节点地址' dist/sb.sh \
  && ok_t "VPS 安装流程提供「节点地址」输入项" || fail_t "VPS 安装流程缺少「节点地址」输入项"
if sed -n '/^argo_off()/,/^}/p' dist/sb.sh | grep -q 'sub_ensure_webroot'; then
  ok_t "--direct（argo_off）重建订阅后同步 web/ 目录"
else
  fail_t "--direct（argo_off）未刷新 web/ 订阅目录"
fi
grep -q 'install_packages qrencode' dist/sb.sh \
  && ok_t "安装流程自动安装 qrencode（订阅二维码）" || fail_t "缺少 qrencode 可选安装"
if sed -n '/^change_params()/,/^}/p' dist/sb.sh | grep -q 'detect_ip'; then
  ok_t "菜单 3 重建订阅前补探测 IP（防 127.0.0.1）"
else
  fail_t "change_params 未探测 IP"
fi
if sed -n '/^show_status()/,/^}/p' dist/sb.sh | grep -q 'detect_ip'; then
  ok_t "菜单 2 展示前补探测 IP（订阅地址显示正确）"
else
  fail_t "show_status 未探测 IP"
fi
if sed -n '/^argo_guard()/,/^}/p' dist/sb.sh | grep -q 'detect_ip'; then
  ok_t "argo_guard 重建订阅前补探测 IP（cron 保活不写废节点）"
else
  fail_t "argo_guard 未探测 IP"
fi
if sed -n '/cat > "$SB_DIR\/boot.sh"/,/^EOF/p' dist/sb.sh | grep -q 'command -v python3'; then
  ok_t "boot.sh 用 command -v 找 python3（Debian/Ubuntu 路径修复）"
else
  fail_t "boot.sh 仍写死 /usr/local/bin/python3"
fi
grep -q 'sub_service_install()' dist/sb.sh \
  && ok_t "订阅服务 systemd 单元存在（sb-sub.service，重启不掉订阅）" || fail_t "缺少 sub_service_install"
grep -q 'sb-sub' dist/sb.sh \
  && ok_t "卸载流程清理 sb-sub.service" || fail_t "卸载未清理 sb-sub.service"
grep -q 'sub_start_server' dist/serv00.sh \
  && ok_t "serv00 版接入本地订阅服务" || fail_t "serv00 缺少订阅服务"
_vout=$(bash dist/sb.sh --version 2>/dev/null)
case "$_vout" in
  sb-smjm?v*) ok_t "--version 正常输出: $_vout" ;;
  *) fail_t "--version 输出异常: ${_vout:-空}" ;;
esac
_menu15=$(printf '0\n' | bash dist/sb.sh 2>/dev/null | grep -c '更新本脚本')
if [ "$_menu15" -ge 1 ]; then
  ok_t "菜单 15（更新本脚本）已存在"
else
  fail_t "菜单缺少「更新本脚本」项"
fi

say "测试完成"
printf '通过: %s  失败: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && { printf '全部通过!\n'; rm -rf /tmp/sb-smjm-test; exit 0; }
exit 1

