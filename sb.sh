#!/usr/bin/env bash
# ============================================================
# sb.sh - Sing-box-smjm 风格一键多协议代理部署脚本（VPS 版）
# 支持: VLESS-Reality-Vision / VMess-WS(+Argo) / Hysteria2 / TUIC v5 / AnyTLS
# 用法（需 root，普通用户先执行 sudo -i）:
#   bash sb.sh                      # 交互式菜单
#   printf '1\n\n\n' | bash sb.sh   # 非交互：选项1，其余回车走默认
#   bash sb.sh --uninstall          # 卸载
# ============================================================
set -uo pipefail

# ---------------- 常量与默认值 ----------------
SB_DIR="${SB_DIR:-/etc/sb-smjm}"
SB_BIN="${SB_BIN:-/usr/local/bin/sing-box}"
CF_BIN="${CF_BIN:-/usr/local/bin/cloudflared}"
SB_FALLBACK_VERSION="${SB_FALLBACK_VERSION:-1.12.4}"
SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/hallteacher/sb-smjm/main/dist/sb.sh}"
# 脚本自身版本号：每次发布递增。--version 查看；sb_self_update 用它对比本地与远端
SB_SCRIPT_VERSION="${SB_SCRIPT_VERSION:-1.2.1}"

PORT_VLESS_DEFAULT=443
PORT_VMESS_DEFAULT=8080
PORT_VMESS_TLS_DEFAULT=2053
PORT_HY2_DEFAULT=8443
PORT_TUIC_DEFAULT=8444
PORT_ANYTLS_DEFAULT=8445
SUB_PORT_DEFAULT=8199

# @BEGIN LIBS@
# 开发模式：逐个 source lib；发布时 build.sh 会把本段替换为各模块内联内容
if [ -d "$(dirname "$0")/lib" ]; then
  for _f in common install config argo subscription; do
    # shellcheck disable=SC1090
    source "$(dirname "$0")/lib/${_f}.sh"
  done
fi
# @END LIBS@

# ---------------- 状态文件（持久化用户选择）----------------
state_file() { printf '%s/state.env' "$SB_DIR"; }

save_state() {
  mkdir -p "$SB_DIR"
  cat > "$(state_file)" <<EOF
UUID=${UUID:-}
NODE_NAME=${NODE_NAME:-sb-smjm}
NODE_ADDR=${NODE_ADDR:-}
ENABLE_VLESS=${ENABLE_VLESS:-n}
ENABLE_VMESS=${ENABLE_VMESS:-n}
ENABLE_VMESS_TLS=${ENABLE_VMESS_TLS:-n}
ENABLE_HY2=${ENABLE_HY2:-n}
ENABLE_TUIC=${ENABLE_TUIC:-n}
ENABLE_ANYTLS=${ENABLE_ANYTLS:-n}
PORT_VLESS=${PORT_VLESS:-$PORT_VLESS_DEFAULT}
PORT_VMESS=${PORT_VMESS:-$PORT_VMESS_DEFAULT}
PORT_VMESS_TLS=${PORT_VMESS_TLS:-$PORT_VMESS_TLS_DEFAULT}
PORT_HY2=${PORT_HY2:-$PORT_HY2_DEFAULT}
PORT_TUIC=${PORT_TUIC:-$PORT_TUIC_DEFAULT}
PORT_ANYTLS=${PORT_ANYTLS:-$PORT_ANYTLS_DEFAULT}
VMESS_PATH=${VMESS_PATH:-}
REALITY_SNI=${REALITY_SNI:-$REALITY_SNI_DEFAULT}
REALITY_PRIVATE=${REALITY_PRIVATE:-}
REALITY_PUBLIC=${REALITY_PUBLIC:-}
REALITY_SHORT=${REALITY_SHORT:-}
TLS_SNI=${TLS_SNI:-$TLS_SNI_DEFAULT}
HY2_PASSWORD=${HY2_PASSWORD:-}
TUIC_PASSWORD=${TUIC_PASSWORD:-}
ANYTLS_PASSWORD=${ANYTLS_PASSWORD:-}
ARGO_MODE=${ARGO_MODE:-none}
ARGO_TOKEN=${ARGO_TOKEN:-}
ARGO_DOMAIN=${ARGO_DOMAIN:-}
SUB_PORT=${SUB_PORT:-$SUB_PORT_DEFAULT}
SUB_PASSWORD=${SUB_PASSWORD:-}
EOF
  return 0
}

load_state() {
  [ -f "$(state_file)" ] || return 0
  set +u
  # shellcheck disable=SC1090
  source "$(state_file)"
  set -u
  return 0
}

# ---------------- 一键安装主流程 ----------------
# 小白模式：一路回车完成；非交互管道输入下全部走默认值
install_all() {
  need_root
  line; info "开始一键部署（五协议直连 + 本地订阅；Argo 为可选项）"; line

  detect_os; detect_arch || die "架构不支持"
  install_packages curl openssl tar python3 gzip || return 1
  # qrencode 只用于装完后在终端显示订阅二维码；部分精简源没有该包，装不上仅跳过二维码
  install_packages qrencode >/dev/null 2>&1 \
    || warn "qrencode 安装失败，订阅二维码不可用（不影响节点使用）"
  detect_ip
  # 把探测结果显示出来：云主机（AWS 等）网卡只有内网 IP，装完才发现节点全是 172.x 就晚了
  info "公网地址探测: IPv4=${IP4:-未检测到}  IPv6=${IP6:-未检测到}"

  install_singbox || return 1
  enable_bbr

  read_input "设置节点备注名（用于节点名前缀）" "${NODE_NAME:-sb-smjm}" NODE_NAME
  if [ -z "${UUID:-}" ]; then
    UUID=$(rand_uuid)
    ok "已生成 UUID: $UUID"
  else
    info "沿用已保存 UUID: $UUID"
  fi

  # 节点地址优先级最高（node_host() 先用它）。detect_ip 已优先走 AWS 元数据/公共接口
  # 探测公网 IP，这里给一次覆盖机会（绑了域名 / 多 IP / 探测不准）；回车留空 = 用自动探测结果。
  read_input "节点地址（公网 IP 或域名，留空=自动探测）" "${NODE_ADDR:-}" NODE_ADDR || true

  read_input "VLESS-Reality 端口" "${PORT_VLESS:-$PORT_VLESS_DEFAULT}" PORT_VLESS
  read_input "VMess-WS 端口（默认公网直连；启用 Argo 后仅本地回源）" "${PORT_VMESS:-$PORT_VMESS_DEFAULT}" PORT_VMESS
  read_input "Hysteria2 端口" "${PORT_HY2:-$PORT_HY2_DEFAULT}" PORT_HY2
  read_input "TUIC v5 端口" "${PORT_TUIC:-$PORT_TUIC_DEFAULT}" PORT_TUIC
  read_input "AnyTLS 端口" "${PORT_ANYTLS:-$PORT_ANYTLS_DEFAULT}" PORT_ANYTLS

  if [ -z "${REALITY_PRIVATE:-}" ] || [ -z "${REALITY_PUBLIC:-}" ]; then
    gen_reality_keypair
    ok "已生成 reality 密钥对"
  fi
  [ -z "${REALITY_SHORT:-}" ]   && REALITY_SHORT=$(rand_hex 8)
  [ -z "${HY2_PASSWORD:-}" ]    && HY2_PASSWORD=$(rand_password)
  [ -z "${TUIC_PASSWORD:-}" ]   && TUIC_PASSWORD=$(rand_password)
  [ -z "${ANYTLS_PASSWORD:-}" ] && ANYTLS_PASSWORD=$(rand_password)
  # ws 路径随机化：固定 /vmess 是全网扫描器都认识的指纹，随机路径让扫描拿不到特征。
  # 旧默认 /vmess 的存量安装会在下次安装/重装时自动迁移到随机路径（订阅自动跟随，客户端刷新一次即可）。
  if [ -z "${VMESS_PATH:-}" ] || [ "${VMESS_PATH}" = "/vmess" ]; then
    VMESS_PATH="/vmess-$(rand_hex 4)"
    ok "VMess ws 路径已随机化: $VMESS_PATH"
  fi
  [ -z "${REALITY_SNI:-}" ]     && REALITY_SNI="$REALITY_SNI_DEFAULT"
  [ -z "${TLS_SNI:-}" ]         && TLS_SNI="$TLS_SNI_DEFAULT"
  [ ! -f "$SB_DIR/cert.pem" ]   && gen_selfsigned_cert "$TLS_SNI"

  ENABLE_VLESS=y; ENABLE_VMESS=y; ENABLE_HY2=y; ENABLE_TUIC=y; ENABLE_ANYTLS=y

  # 【默认 n】VMess 默认公网直连（IP:端口，无 TLS），Argo/CDN 变成显式可选 ——
  # 旧版默认 y，一键命令里的空回车就会吃到它，导致每次全新安装 VMess 都变成
  # trycloudflare:443，隧道域名一漂移节点就 -1。现在想用 CDN 线必须显式输 y。
  _argo=n
  if confirm "是否启用 Argo 临时隧道（vmess 套 CDN；一般回车选 n 走直连）" "n" _argo && [ "$_argo" = "y" ]; then
    install_cloudflared || warn "cloudflared 安装失败，将跳过 Argo 隧道"
  fi
  if [ -x "$CF_BIN" ] && [ "$_argo" = "y" ]; then
    if argo_run_temp; then
      VMESS_LISTEN="127.0.0.1"
    else
      warn "Argo 隧道启动失败，vmess 将以明文端口直接暴露"
      ARGO_MODE=none; VMESS_LISTEN="::"
    fi
  else
    ARGO_MODE=none; VMESS_LISTEN="::"
  fi

  build_config || return 1
  build_subscription || true
  save_state
  # 生成 $SB_DIR/sb.sh 与 $SB_DIR/boot.sh：README 承诺「装完后任意目录执行 sb」，
  # 而且 boot.sh 必须先于 sb_enable_boot 存在，否则它写进 cron 的 @reboot 会指向
  # 一个不存在的文件（与 argo_boot.sh 同一类「只引用不生成」问题）。
  install_shortcut || true
  sb_enable_boot
  sb_restart || true
  if [ "${ARGO_MODE:-none}" != "none" ]; then argo_enable_boot || true; fi

  read_input "本地订阅服务端口" "${SUB_PORT:-$SUB_PORT_DEFAULT}" SUB_PORT
  read_input "订阅路径密码（留空=不要密码）" "${SUB_PASSWORD:-}" SUB_PASSWORD
  sub_start_server || true
  save_state

  line; ok "部署完成！节点信息如下："; line
  cat "$SB_DIR/nodes.txt" 2>/dev/null || true
  show_subscription
  show_about
  return 0
}


# ---------------- 单项管理功能 ----------------
change_params() {
  need_root
  load_state
  # 后面要重建订阅：新进程里 IP4/IP6 未初始化，不探测会把 127.0.0.1 写进全部节点
  detect_ip 2>/dev/null || true
  menu_select sel "修改 VLESS-Reality 端口" "修改 Hysteria2 端口" "修改 TUIC 端口" \
                 "修改 AnyTLS 端口" "修改 reality SNI(偷的站)" "重新生成全部密码/密钥" "返回"
  case "$sel" in
    1) read_input "VLESS-Reality 新端口" "${PORT_VLESS:-443}" PORT_VLESS ;;
    2) read_input "Hysteria2 新端口" "${PORT_HY2:-8443}" PORT_HY2 ;;
    3) read_input "TUIC 新端口" "${PORT_TUIC:-8444}" PORT_TUIC ;;
    4) read_input "AnyTLS 新端口" "${PORT_ANYTLS:-8445}" PORT_ANYTLS ;;
    5) read_input "reality SNI（建议流行的 https 站）" "${REALITY_SNI:-www.yahoo.com}" REALITY_SNI ;;
    6)
      gen_reality_keypair; REALITY_SHORT=$(rand_hex 8)
      HY2_PASSWORD=$(rand_password); TUIC_PASSWORD=$(rand_password); ANYTLS_PASSWORD=$(rand_password)
      ok "已重新生成密钥对与密码"
      ;;
    *) return 0 ;;
  esac
  save_state
  build_config || return 1
  build_subscription || true
  sb_restart || true
  sub_start_server || true
  ok "参数已更新并重启服务"
  return 0
}

install_argo_token() {
  need_root
  install_cloudflared || return 1
  load_state
  # 重建订阅需要 IP4/NODE_ADDR，新进程不探测会写出 127.0.0.1 的废节点
  detect_ip 2>/dev/null || true
  read_input "请输入 Cloudflare 隧道 Token（dash.cloudflare.com 创建后复制）" "" ARGO_TOKEN
  if [ -z "$ARGO_TOKEN" ]; then err "Token 为空，已取消"; return 1; fi
  if argo_run_token "$ARGO_TOKEN"; then
    ENABLE_VMESS=y
    VMESS_LISTEN="127.0.0.1"
    save_state
    build_config || true
    build_subscription || true
    sub_ensure_webroot >/dev/null 2>&1 || true
    sb_restart || true
    argo_enable_boot || true
    ok "请在 CF 后台把隧道域名指向 http://127.0.0.1:${PORT_VMESS}"
  fi
  return 0
}

show_status() {
  load_state
  # show_subscription 要用 IP4/NODE_ADDR 推导订阅地址；新进程里未初始化需补探测
  detect_ip 2>/dev/null || true
  # 顺手自愈：root 身份下，若隧道没跑/假死/域名过期，先修好再展示真实状态
  # （非 root 只读展示，不做有副作用的操作）
  if [ "$(id -u 2>/dev/null || echo 1)" = "0" ] && [ "${ARGO_MODE:-none}" != "none" ]; then
    argo_guard || true
  fi
  line; info "sing-box-smjm 当前状态"; line
  if sb_is_running 2>/dev/null; then
    ok "sing-box: 运行中（版本 $(sb_installed_version 2>/dev/null || echo 未知)）"
  else
    warn "sing-box: 未运行"
  fi
  if [ -n "$(argo_pid 2>/dev/null)" ]; then
    ok "Argo 隧道: 运行中（模式 ${ARGO_MODE:-none}, 域名 ${ARGO_DOMAIN:-未知}）"
  else
    warn "Argo 隧道: 未运行"
  fi
  echo
  if [ -f "$SB_DIR/nodes.txt" ]; then
    info "节点链接:"
    cat "$SB_DIR/nodes.txt"
  else
    warn "尚未生成节点（请先执行安装）"
  fi
  show_subscription
  show_about
  return 0
}

do_uninstall() {
  need_root
  confirm "确认卸载 sing-box、cloudflared 与全部配置（不可恢复）" "n" _u
  if [ "$_u" = "n" ]; then info "已取消"; return 0; fi
  sb_stop 2>/dev/null || true
  sub_stop_server 2>/dev/null || true
  argo_stop 2>/dev/null || true
  if have_systemd; then
    systemctl disable --now sing-box argo-smjm sb-sub 2>/dev/null || true
    rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/argo-smjm.service /etc/systemd/system/sb-sub.service
    systemctl daemon-reload 2>/dev/null || true
  fi
  if command -v crontab >/dev/null 2>&1; then
    ( crontab -l 2>/dev/null | grep -v 'sb-smjm' ) | crontab - 2>/dev/null || true
  fi
  rm -rf "$SB_DIR" "$SB_BIN" "$CF_BIN" /usr/local/bin/sb 2>/dev/null || true
  ok "已卸载干净（$SB_DIR / $SB_BIN / $CF_BIN / 快捷命令 sb）"
  return 0
}


# 注册 sb 快捷命令，并生成无 systemd 时的保活脚本
install_shortcut() {
  need_root
  mkdir -p "$SB_DIR"
  local self="$0"
  sb_self_persist "$self" >/dev/null \
    || { warn "在线拉取脚本失败，快捷命令未安装"; return 1; }
  ln -sf "$SB_DIR/sb.sh" /usr/local/bin/sb
  cat > "$SB_DIR/boot.sh" <<'EOF'
#!/usr/bin/env bash
SB_DIR=/etc/sb-smjm
[ -x /usr/local/bin/sing-box ] && nohup /usr/local/bin/sing-box run -c $SB_DIR/config.json >$SB_DIR/singbox.log 2>&1 &
[ -x $SB_DIR/argo_boot.sh ] && nohup $SB_DIR/argo_boot.sh >/dev/null 2>&1 &
if command -v python3 >/dev/null 2>&1 && [ -f $SB_DIR/state.env ] && [ -d $SB_DIR/web ]; then
  P=$(grep '^SUB_PORT=' $SB_DIR/state.env | cut -d= -f2)
  [ -n "$P" ] && ( cd $SB_DIR/web && nohup python3 -m http.server "$P" --bind 0.0.0.0 >/dev/null 2>&1 & )
fi
EOF
  chmod 0755 "$SB_DIR/boot.sh"
  ok "快捷命令已安装：任意位置执行 sb 即可打开管理菜单"
  return 0
}

# ---------------- 脚本自更新 ----------------
# sb_self_update：从 GitHub 拉取最新 dist/sb.sh，语法校验通过后替换 $SB_DIR/sb.sh 并刷新快捷命令。
# 为什么需要：实际排障中最大的障碍就是「VPS 上跑的脚本是什么版本无法确认」——
# 用户曾两次拿着旧脚本复现已修复的 bug。版本号 + 一键自更新让这类事故从根上消失。
sb_self_update() {
  need_root
  line; info "更新 sb-smjm 脚本（当前 v${SB_SCRIPT_VERSION}）"; line
  command -v curl >/dev/null 2>&1 || { warn "缺少 curl，请先安装"; return 1; }
  local tmp newver curver
  tmp=$(mktemp) || return 1
  if ! curl -Ls --max-time 60 -o "$tmp" "$SCRIPT_URL"; then
    warn "下载失败：$SCRIPT_URL"; rm -f "$tmp"; return 1
  fi
  if ! bash -n "$tmp"; then
    warn "下载内容语法异常，放弃更新（本地脚本未动）"; rm -f "$tmp"; return 1
  fi
  newver=$(grep -m1 'SB_SCRIPT_VERSION=' "$tmp" | cut -d'"' -f2)
  curver=$(grep -m1 'SB_SCRIPT_VERSION=' "$SB_DIR/sb.sh" 2>/dev/null | cut -d'"' -f2)
  if [ -n "$curver" ] && [ "$curver" = "$newver" ]; then
    ok "已是最新版本 v${newver}，无需更新"; rm -f "$tmp"; return 0
  fi
  [ -f "$SB_DIR/sb.sh" ] && cp -f "$SB_DIR/sb.sh" "$SB_DIR/sb.sh.bak"
  mkdir -p "$SB_DIR"
  if ! install -m 0755 "$tmp" "$SB_DIR/sb.sh"; then
    warn "写入 $SB_DIR/sb.sh 失败"; rm -f "$tmp"; return 1
  fi
  rm -f "$tmp"
  ln -sf "$SB_DIR/sb.sh" /usr/local/bin/sb 2>/dev/null || true
  ok "脚本已更新：v${curver:-未知} -> v${newver}（旧版备份为 $SB_DIR/sb.sh.bak）"
  ok "配置、密钥与订阅不受影响，客户端无需任何操作"
  return 0
}

# ---------------- 主菜单 ----------------
main_menu() {
  while true; do
    brand_banner
    printf '  sb-smjm 脚本 v%s\n' "$SB_SCRIPT_VERSION"
    line
    printf '  %s1)%s 一键安装（五协议直连 + 订阅，小白推荐）\n' "$C_GREEN" "$C_RESET"
    printf '  %s2)%s 查看节点 / 订阅 / 运行状态\n' "$C_GREEN" "$C_RESET"
    printf '  %s3)%s 修改端口 / SNI / 重新生成密码\n' "$C_GREEN" "$C_RESET"
    printf '  %s4)%s 启动 / 重启 sing-box\n' "$C_GREEN" "$C_RESET"
    printf '  %s5)%s 停止 sing-box\n' "$C_GREEN" "$C_RESET"
    printf '  %s6)%s 安装 Argo 临时隧道（vmess 套 CDN）\n' "$C_GREEN" "$C_RESET"
    printf '  %s7)%s 安装 Argo 固定 Token 隧道\n' "$C_GREEN" "$C_RESET"
    printf '  %s8)%s 停止 Argo 隧道\n' "$C_GREEN" "$C_RESET"
    printf '  %s9)%s 更新 sing-box 内核\n' "$C_GREEN" "$C_RESET"
    printf '  %s10)%s 安装 sb 快捷命令\n' "$C_GREEN" "$C_RESET"
    printf '  %s11)%s 设置开机自启\n' "$C_GREEN" "$C_RESET"
    printf '  %s12)%s 关于本脚本 / 博客 / 频道\n' "$C_GREEN" "$C_RESET"
    printf '  %s13)%s 修复 Argo 隧道 / 订阅（一键自愈）\n' "$C_GREEN" "$C_RESET"
    printf '  %s14)%s 关闭 Argo：VMess 改公网直连\n' "$C_GREEN" "$C_RESET"
    printf '  %s15)%s 更新本脚本（拉取 GitHub 最新版）\n' "$C_GREEN" "$C_RESET"
    printf '  %s0)%s 退出\n' "$C_RED" "$C_RESET"
    line
    read_input "请选择" "1" _choice || { info "再见！"; break; }
    case "$_choice" in
      1) install_all ;;
      2) show_status ;;
      3) change_params ;;
      4) need_root; sb_restart ;;
      5) need_root; sb_stop ;;
      6)
        need_root
        install_cloudflared || true
        load_state
        # 重建订阅需要 IP4/NODE_ADDR（新进程里未初始化）
        detect_ip 2>/dev/null || true
        if argo_run_temp; then
          VMESS_LISTEN=127.0.0.1; ARGO_MODE=temp
          save_state; build_config; build_subscription; sub_ensure_webroot; sb_restart; argo_enable_boot; show_status
        fi
        ;;
      7) install_argo_token ;;
      8) need_root; argo_stop ;;
      9) update_singbox ;;
      10) install_shortcut ;;
      11) need_root; sb_enable_boot ;;
      12) show_about ;;
      13) need_root; argo_heal ;;
      14) need_root; argo_off ;;
      15) need_root; sb_self_update ;;
      0|q|Q) info "再见！"; break ;;
      *) warn "无效选项: $_choice" ;;
    esac
  done
  return 0
}

usage() {
  cat <<'EOF'
sb.sh - sing-box-smjm 一键多协议脚本（需 root，普通用户先 sudo -i）
用法:
  bash sb.sh                      交互式菜单
  printf '1\n\n\n' | bash sb.sh    非交互：选项1，其余回车走默认
  bash sb.sh --uninstall          卸载
  bash sb.sh --update             更新 sing-box 内核
  bash sb.sh --status             查看节点与订阅
  bash sb.sh --argo-guard         保活检查（供 cron / argo_boot.sh 调用）
  bash sb.sh --heal               一键自愈：修复 Argo 隧道并重建订阅
  bash sb.sh --direct             关闭 Argo：VMess 改公网直连并重建配置/订阅
  bash sb.sh --upgrade            更新本脚本到 GitHub 最新版（配置订阅不受影响）
  bash sb.sh --version            查看本脚本版本
博客: https://smjmblog.blogspot.com/
EOF
}

main() {
  case "${1:-}" in
    --uninstall|-u) do_uninstall; exit $? ;;
    --update)       need_root; update_singbox; exit $? ;;
    --upgrade)      need_root; sb_self_update; exit $? ;;
    --version|-v)   printf 'sb-smjm v%s\n' "$SB_SCRIPT_VERSION"; exit 0 ;;
    --status|-s)    show_status; exit $? ;;
    --install|-i)   install_all; exit $? ;;
    # Argo 保活入口：由 $SB_DIR/argo_boot.sh 与 cron 调用（不是给人用的）
    --argo-guard)   argo_guard "${2:-}"; exit $? ;;
    --heal)         need_root; argo_heal; exit $? ;;
    --direct|-d)    need_root; argo_off; exit $? ;;
    --help|-h)      usage; exit 0 ;;
  esac
  load_state
  main_menu
}

main "$@"

