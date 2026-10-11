#!/usr/bin/env bash
# ============================================================
# serv00.sh - Serv00 / Hostuno 共享主机专用（三协议 + 保活）
# 无 root / 无 systemd / FreeBSD 环境，全部文件装在 $HOME 下
# 协议: VLESS-Reality-Vision / VMess-WS / Hysteria2
# 用法:
#   bash serv00.sh                      # 交互式菜单
#   printf '1\n\n\n' | bash serv00.sh   # 非交互一键安装
#   bash serv00.sh --uninstall          # 卸载
# ============================================================
set -uo pipefail

# ---------------- 常量（全部装在用户主目录）----------------
HOME_DIR="${HOME:-/tmp}"
SB_DIR="${SB_DIR:-$HOME_DIR/sb-smjm}"
SB_BIN="${SB_BIN:-$HOME_DIR/sb-smjm/bin/sing-box}"
SB_FALLBACK_VERSION="${SB_FALLBACK_VERSION:-1.12.4}"

PORT_VLESS_DEFAULT=443
PORT_VMESS_DEFAULT=8080
PORT_HY2_DEFAULT=8443
SUB_PORT_DEFAULT=8199

# @BEGIN LIBS@
# 开发模式：逐个 source lib；发布时 build.sh 会把本段替换为各模块内联内容
# serv00 只需 common + config + subscription（不需要 install 的 root 逻辑 / argo）
if [ -d "$(dirname "$0")/lib" ]; then
  for _f in common config subscription; do
    # shellcheck disable=SC1090
    source "$(dirname "$0")/lib/${_f}.sh"
  done
fi
# @END LIBS@

# ---------------- Serv00 特有：状态文件 ----------------
state_file() { printf '%s/state.env' "$SB_DIR"; }

save_state() {
  mkdir -p "$SB_DIR"
  cat > "$(state_file)" <<EOF
UUID=${UUID:-}
NODE_NAME=${NODE_NAME:-sb-smjm}
NODE_ADDR=${NODE_ADDR:-}
ENABLE_VLESS=${ENABLE_VLESS:-y}
ENABLE_VMESS=${ENABLE_VMESS:-y}
ENABLE_HY2=${ENABLE_HY2:-y}
PORT_VLESS=${PORT_VLESS:-$PORT_VLESS_DEFAULT}
PORT_VMESS=${PORT_VMESS:-$PORT_VMESS_DEFAULT}
PORT_HY2=${PORT_HY2:-$PORT_HY2_DEFAULT}
VMESS_PATH=${VMESS_PATH:-/vmess}
REALITY_SNI=${REALITY_SNI:-$REALITY_SNI_DEFAULT}
REALITY_PRIVATE=${REALITY_PRIVATE:-}
REALITY_PUBLIC=${REALITY_PUBLIC:-}
REALITY_SHORT=${REALITY_SHORT:-}
TLS_SNI=${TLS_SNI:-$TLS_SNI_DEFAULT}
HY2_PASSWORD=${HY2_PASSWORD:-}
SUB_PORT=${SUB_PORT:-$SUB_PORT_DEFAULT}
SUB_PASSWORD=${SUB_PASSWORD:-}
IP4=${IP4:-}
IP6=${IP6:-}
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

# ---------------- Serv00 特有：FreeBSD 二进制安装 ----------------
# Serv00 是 FreeBSD，uname -m 输出 amd64/arm64，包名带 freebsd-
detect_arch_freebsd() {
  local m
  m=$(uname -m 2>/dev/null) || return 1
  case "$m" in
    x86_64|amd64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l|armv7*) ARCH="armv7" ;;
    *) err "不支持的 CPU 架构: $m"; return 1 ;;
  esac
  return 0
}

install_singbox_freebsd() {
  if [ -x "$SB_BIN" ]; then
    ok "sing-box 已安装: $("$SB_BIN" version 2>/dev/null | head -n1)"
    return 0
  fi
  mkdir -p "$(dirname "$SB_BIN")"
  local ver tarname url tmpdir src
  ver=$(get_latest_sb_version)
  tarname="sing-box-${ver}-freebsd-${ARCH}.tar.gz"
  url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/${tarname}"
  info "下载 sing-box ${ver} (freebsd-${ARCH}) ..."
  tmpdir=$(mktemp -d) || die "无法创建临时目录"
  if ! curl -fsSL --max-time 120 --retry 2 -o "$tmpdir/${tarname}" "$url"; then
    rm -rf "$tmpdir"
    die "sing-box 下载失败，请检查网络或手动放置二进制到 $SB_BIN"
  fi
  tar -xzf "$tmpdir/${tarname}" -C "$tmpdir" >/dev/null 2>&1 || { rm -rf "$tmpdir"; die "解压失败: $tarname"; }
  src=$(find "$tmpdir" -type f -name 'sing-box' | head -n1)
  [ -z "$src" ] && { rm -rf "$tmpdir"; die "压缩包内未找到 sing-box 二进制"; }
  install -m 0755 "$src" "$SB_BIN" || die "安装二进制失败（磁盘配额满？）"
  rm -rf "$tmpdir"
  ok "sing-box 安装完成: $("$SB_BIN" version 2>/dev/null | head -n1)"
  return 0
}

# ---------------- Serv00 特有：进程管理（无 systemd）----------------
sb_pid_file() { printf '%s/singbox.pid' "$SB_DIR"; }

sb_start() {
  mkdir -p "$SB_DIR"
  nohup "$SB_BIN" run -c "$SB_DIR/config.json" >"$SB_DIR/singbox.log" 2>&1 &
  echo $! > "$(sb_pid_file)"
  disown 2>/dev/null || true
  sleep 1
  sb_is_running
}

sb_stop() {
  if [ -f "$(sb_pid_file)" ]; then
    local pid
    pid=$(cat "$(sb_pid_file)" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null
      local i
      for i in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$(sb_pid_file)"
  fi
  pkill -f "sing-box run -c $SB_DIR/config.json" 2>/dev/null || true
  ok "sing-box 已停止"
  return 0
}

sb_is_running() {
  [ -f "$(sb_pid_file)" ] && kill -0 "$(cat "$(sb_pid_file)" 2>/dev/null)" 2>/dev/null
}

sb_restart() {
  sb_stop >/dev/null 2>&1 || true
  sleep 1
  sb_start
  if sb_is_running; then
    ok "sing-box 已启动"
  else
    err "sing-box 启动失败，请查看日志: $SB_DIR/singbox.log"
    tail -n 20 "$SB_DIR/singbox.log" 2>/dev/null || true
    return 1
  fi
  return 0
}

# ---------------- Serv00 特有：crontab 保活 ----------------
# 掉线自动拉起，crontab 每 5 分钟调用一次
keepalive_install() {
  cat > "$SB_DIR/keepalive.sh" <<EOF
#!/usr/bin/env bash
# sb-smjm 保活脚本（由 crontab 每 5 分钟调用）
SB_DIR="$SB_DIR"
SB_BIN="$SB_BIN"
[ -x "\$SB_BIN" ] || exit 0
if ! kill -0 "\$(cat "\$SB_DIR/singbox.pid" 2>/dev/null)" 2>/dev/null; then
  cd "\$SB_DIR" 2>/dev/null || exit 0
  nohup "\$SB_BIN" run -c "\$SB_DIR/config.json" >>"\$SB_DIR/singbox.log" 2>&1 &
  echo \$! > "\$SB_DIR/singbox.pid"
fi
EOF
  chmod 0755 "$SB_DIR/keepalive.sh"
  if command -v crontab >/dev/null 2>&1; then
    ( crontab -l 2>/dev/null | grep -v "sb-smjm keepalive"; \
      echo "*/5 * * * * $SB_DIR/keepalive.sh # sb-smjm keepalive" ) \
      | crontab - 2>/dev/null && ok "保活已安装（crontab 每 5 分钟检测）" \
      || warn "crontab 写入失败，请手动添加: */5 * * * * $SB_DIR/keepalive.sh"
  else
    warn "无 crontab 命令，请自行配置保活: $SB_DIR/keepalive.sh"
  fi
  return 0
}

keepalive_remove() {
  if command -v crontab >/dev/null 2>&1; then
    crontab -l 2>/dev/null | grep -v "sb-smjm keepalive" | crontab - 2>/dev/null || true
  fi
  return 0
}

# ---------------- 查看状态 ----------------
show_status() {
  load_state
  # 推导订阅地址需要 NODE_ADDR/IP4；没有节点地址时现场探测一次
  if [ -z "${NODE_ADDR:-}" ]; then detect_ip 2>/dev/null || true; fi
  line; info "sb-smjm (serv00) 当前状态"; line
  if sb_is_running; then
    ok "sing-box: 运行中 (PID $(cat "$(sb_pid_file)" 2>/dev/null))"
  else
    warn "sing-box: 未运行"
  fi
  [ -f "$SB_DIR/keepalive.sh" ] && ok "保活: 已安装" || warn "保活: 未安装"
  line
  if [ -f "$SB_DIR/nodes.txt" ]; then
    info "节点链接:"
    cat "$SB_DIR/nodes.txt"
    show_subscription
  else
    warn "尚未生成节点链接，请先执行安装"
  fi
  show_about
  return 0
}

# ---------------- 卸载 ----------------
do_uninstall() {
  warn "将停止服务并删除 $SB_DIR 下的配置与节点信息"
  confirm "确认卸载？" "n" _ans
  [ "$_ans" = "y" ] || { info "已取消"; return 0; }
  sb_stop >/dev/null 2>&1 || true
  keepalive_remove
  rm -rf "$SB_DIR"
  ok "已卸载（二进制保留在 $(dirname "$SB_BIN")，可手动删除）"
  return 0
}

# ---------------- 一键安装（三协议 + 保活）----------------
install_all() {
  line; info "开始部署（VLESS-Reality + VMess-WS + Hysteria2 + 保活）"; line

  detect_arch_freebsd || die "架构不支持"
  command -v curl >/dev/null 2>&1 || die "需要 curl，请在 Serv00 面板确认已开启"
  command -v openssl >/dev/null 2>&1 || die "需要 openssl 生成证书与密钥"
  command -v tar >/dev/null 2>&1 || die "需要 tar 解压"

  install_singbox_freebsd || return 1

  read_input "设置节点备注名（用于节点名前缀）" "${NODE_NAME:-sb-smjm}" NODE_NAME || true
  if [ -z "${UUID:-}" ]; then
    UUID=$(rand_uuid)
  fi
  read_input "VLESS-Reality 端口（Serv00 面板需放行）" "${PORT_VLESS:-$PORT_VLESS_DEFAULT}" PORT_VLESS || true
  read_input "VMess-WS 端口" "${PORT_VMESS:-$PORT_VMESS_DEFAULT}" PORT_VMESS || true
  read_input "Hysteria2 端口" "${PORT_HY2:-$PORT_HY2_DEFAULT}" PORT_HY2 || true
  read_input "VMess-WS 路径" "${VMESS_PATH:-/vmess}" VMESS_PATH || true
  read_input "Reality 伪装 SNI" "${REALITY_SNI:-$REALITY_SNI_DEFAULT}" REALITY_SNI || true
  read_input "TLS SNI（自签证书 CN）" "${TLS_SNI:-$TLS_SNI_DEFAULT}" TLS_SNI || true

  # Serv00 通常无公网 IPv4 传入，用面板域名作为节点地址更稳妥
  read_input "节点地址（留空则用公网 IP 自动检测）" "${NODE_ADDR:-}" NODE_ADDR || true

  # 本地订阅服务（README 承诺与 VPS 同款；端口需在面板 Port reservations 放行）
  read_input "本地订阅服务端口" "${SUB_PORT:-$SUB_PORT_DEFAULT}" SUB_PORT || true
  read_input "订阅路径密码（留空=不要密码）" "${SUB_PASSWORD:-}" SUB_PASSWORD || true

  # 密钥与密码
  if [ -z "${REALITY_PRIVATE:-}" ] || [ -z "${REALITY_PUBLIC:-}" ]; then
    info "生成 Reality 密钥对 ..."
    gen_reality_keypair || return 1
  fi
  if [ -z "${REALITY_SHORT:-}" ]; then
    REALITY_SHORT=$(rand_hex 8)
  fi
  if [ -z "${HY2_PASSWORD:-}" ]; then
    HY2_PASSWORD=$(rand_password 20)
  fi
  # Hysteria2 需要自签证书
  gen_selfsigned_cert "$TLS_SNI" || return 1

  # 公网地址检测（用户没填 NODE_ADDR 时）
  if [ -z "${NODE_ADDR:-}" ]; then
    detect_ip || true
  fi

  save_state
  build_config || return 1
  build_subscription || return 1
  sub_start_server || warn "订阅服务启动失败（不影响节点，可用 $SB_DIR/sub.txt 手动导入）"
  sb_restart || return 1
  keepalive_install || true

  line; ok "部署完成！节点信息如下:"; line
  cat "$SB_DIR/nodes.txt"
  show_subscription
  line
  info "Base64 订阅: $(cat "$SB_DIR/sub.txt" 2>/dev/null)"
  line
  warn "提示: 请在 Serv00 面板 → Port reservations 放行以上端口（TCP/UDP）"
  show_about
  return 0
}

# ---------------- 主菜单 ----------------
main_menu() {
  while true; do
    line
    printf '  %s1)%s 一键安装（三协议 + 保活）\n' "$C_GREEN" "$C_RESET"
    printf '  %s2)%s 查看节点 / 订阅 / 运行状态\n' "$C_GREEN" "$C_RESET"
    printf '  %s3)%s 启动 / 重启 sing-box\n' "$C_GREEN" "$C_RESET"
    printf '  %s4)%s 停止 sing-box\n' "$C_GREEN" "$C_RESET"
    printf '  %s5)%s 安装 / 刷新保活（crontab）\n' "$C_GREEN" "$C_RESET"
    printf '  %s6)%s 卸载\n' "$C_RED" "$C_RESET"
    printf '  %s7)%s 关于本脚本 / 博客 / 频道\n' "$C_GREEN" "$C_RESET"
    printf '  %s0)%s 退出\n' "$C_RED" "$C_RESET"
    line
    read_input "请选择" "1" _choice || { info "再见！"; break; }
    case "$_choice" in
      1) install_all ;;
      2) show_status ;;
      3) sb_restart ;;
      4) sb_stop ;;
      5) keepalive_install ;;
      6) do_uninstall ;;
      7) show_about ;;
      0|q|Q) info "再见！"; break ;;
      *) warn "无效选项: $_choice" ;;
    esac
  done
  return 0
}

usage() {
  cat <<'EOF'
serv00.sh - sb-smjm Serv00/Hostuno 专用（三协议 + 保活）
用法:
  bash serv00.sh                      交互式菜单
  printf '1\n\n\n' | bash serv00.sh   非交互：选项1，其余回车走默认
  bash serv00.sh --uninstall          卸载
  bash serv00.sh --status             查看节点与订阅
博客: https://smjmblog.blogspot.com/
EOF
}

main() {
  case "${1:-}" in
    --uninstall|-u) do_uninstall; exit $? ;;
    --status|-s)    show_status; exit $? ;;
    --install|-i)   install_all; exit $? ;;
    --help|-h)      usage; exit 0 ;;
  esac
  load_state
  main_menu
}

main "$@"
