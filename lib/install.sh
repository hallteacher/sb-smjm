# ============================================================
# install.sh - sing-box / cloudflared 的下载安装、更新、卸载、服务管理
# 依赖外部变量：SB_DIR SB_BIN CF_BIN ARCH（由主脚本设定）
# ============================================================

# GitHub 下载加速镜像（国内 VPS 自动依次尝试）
GH_PROXY_LIST=(
  "https://github.com"
  "https://ghproxy.net/https://github.com"
  "https://gh-proxy.com/https://github.com"
)

# gh_download 存储相对路径 目标文件：依次尝试镜像，成功返回 0
gh_download() {
  local url="$1" dest="$2" base
  for base in "${GH_PROXY_LIST[@]}"; do
    if curl -fsSL --max-time 60 --retry 2 -o "$dest" "${base}${url}"; then
      [ -s "$dest" ] && return 0
    fi
    rm -f "$dest" 2>/dev/null
  done
  return 1
}

# 取 sing-box 最新版本号（失败用兜底版本）
get_latest_sb_version() {
  local v=""
  if command -v curl >/dev/null 2>&1; then
    v=$(curl -fsSL --max-time 15 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null \
        | grep '"tag_name"' | head -n1 | sed -E 's/.*"v?([^"]+)".*/\1/')
  fi
  [ -z "$v" ] && v="${SB_FALLBACK_VERSION:-1.12.4}"
  printf '%s' "$v"
}

# 已安装的 sing-box 版本（未安装返回空）
sb_installed_version() {
  if [ -x "$SB_BIN" ]; then
    "$SB_BIN" version 2>/dev/null | awk '/sing-box version/{print $3; exit}'
  fi
}

install_singbox() {
  need_root
  local ver url tmpdir tarname cur src
  cur=$(sb_installed_version)
  if [ -n "$cur" ]; then
    ok "sing-box 已安装，版本 $cur"
    return 0
  fi
  info "开始下载安装 sing-box ..."
  ver=$(get_latest_sb_version)
  tarname="sing-box-${ver}-linux-${ARCH}.tar.gz"
  url="/SagerNet/sing-box/releases/download/v${ver}/${tarname}"
  tmpdir=$(mktemp -d) || die "无法创建临时目录"
  if ! gh_download "$url" "$tmpdir/${tarname}"; then
    rm -rf "$tmpdir"
    die "sing-box 下载失败，请检查网络（或使用代理/更换镜像后重试）"
  fi
  tar -xzf "$tmpdir/${tarname}" -C "$tmpdir" >/dev/null 2>&1 || { rm -rf "$tmpdir"; die "解压失败: $tarname"; }
  src=$(find "$tmpdir" -type f -name 'sing-box' | head -n1)
  [ -z "$src" ] && { rm -rf "$tmpdir"; die "压缩包内未找到 sing-box 二进制"; }
  mkdir -p "$(dirname "$SB_BIN")" "$SB_DIR"
  install -m 0755 "$src" "$SB_BIN" || die "安装二进制失败"
  rm -rf "$tmpdir"
  ok "sing-box 安装完成: $("$SB_BIN" version 2>/dev/null | head -n1)"
  return 0
}

update_singbox() {
  need_root
  local cur new tmpdir tarname src
  cur=$(sb_installed_version)
  [ -z "$cur" ] && { info "尚未安装 sing-box，转为安装"; install_singbox; return $?; }
  new=$(get_latest_sb_version)
  info "当前版本: $cur   最新版本: $new"
  if [ "$cur" = "$new" ]; then
    ok "已是最新版本，无需更新"
    return 0
  fi
  info "正在更新到 $new ..."
  tarname="sing-box-${new}-linux-${ARCH}.tar.gz"
  tmpdir=$(mktemp -d) || die "无法创建临时目录"
  if ! gh_download "/SagerNet/sing-box/releases/download/v${new}/${tarname}" "$tmpdir/${tarname}"; then
    rm -rf "$tmpdir"; die "下载新版本失败"
  fi
  tar -xzf "$tmpdir/${tarname}" -C "$tmpdir" >/dev/null 2>&1 || { rm -rf "$tmpdir"; die "解压失败"; }
  src=$(find "$tmpdir" -type f -name 'sing-box' | head -n1)
  [ -z "$src" ] && { rm -rf "$tmpdir"; die "压缩包内未找到 sing-box 二进制"; }
  sb_stop >/dev/null 2>&1 || true
  install -m 0755 "$src" "$SB_BIN" || { rm -rf "$tmpdir"; die "覆盖安装失败"; }
  rm -rf "$tmpdir"
  sb_start
  ok "sing-box 已更新到 $new"
  return 0
}

install_cloudflared() {
  need_root
  if [ -x "$CF_BIN" ]; then
    ok "cloudflared 已安装: $("$CF_BIN" -v 2>/dev/null | head -n1)"
    return 0
  fi
  info "下载安装 cloudflared ..."
  local tmp bin
  tmp=$(mktemp -d) || die "无法创建临时目录"
  bin="$tmp/cloudflared"
  if ! gh_download "/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$(cf_arch)" "$bin"; then
    rm -rf "$tmp"; die "cloudflared 下载失败"
  fi
  mkdir -p "$(dirname "$CF_BIN")"
  install -m 0755 "$bin" "$CF_BIN" || die "安装 cloudflared 失败"
  rm -rf "$tmp"
  ok "cloudflared 安装完成"
  return 0
}

uninstall_cloudflared() {
  argo_stop >/dev/null 2>&1 || true
  [ -x "$CF_BIN" ] && rm -f "$CF_BIN"
  ok "cloudflared 已卸载"
  return 0
}


# ---------- 脚本自持久化 ----------
# sb_self_persist [脚本路径]：把当前脚本写到 $SB_DIR/sb.sh，成功输出该路径
# 供「快捷命令 sb」与「argo_boot.sh」复用：两者都需要一个固定路径的完整脚本，
# 因为 `bash <(curl ...)` 这类调用方式下 $0 不是可复用的本地文件。
sb_self_persist() {
  local dest="$SB_DIR/sb.sh" self="${1:-$0}"
  mkdir -p "$SB_DIR" 2>/dev/null || true
  if [ -f "$self" ]; then
    cp -f "$self" "$dest" 2>/dev/null || return 1
  elif command -v curl >/dev/null 2>&1 && [ -n "${SCRIPT_URL:-}" ]; then
    curl -fsSL --max-time 60 -o "$dest" "$SCRIPT_URL" 2>/dev/null || return 1
  else
    return 1
  fi
  chmod 0755 "$dest" 2>/dev/null || true
  printf '%s' "$dest"
  return 0
}


# ---------- 服务管理（有 systemd 用 systemd，否则 nohup + PID 文件）----------
have_systemd() {
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

sb_service_install() {
  # 写入/刷新 systemd unit（无 systemd 时跳过）
  have_systemd || return 0
  cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service (sb-smjm)
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=$SB_BIN run -c $SB_DIR/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  return 0
}

sb_stop_nohup() {
  if [ -f "$SB_DIR/singbox.pid" ]; then
    local pid i
    pid=$(cat "$SB_DIR/singbox.pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null
      for i in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$SB_DIR/singbox.pid"
  fi
  pkill -f "sing-box run -c $SB_DIR/config.json" 2>/dev/null || true
  return 0
}

sb_start() {
  if have_systemd; then
    sb_service_install
    systemctl enable --now sing-box >/dev/null 2>&1 || systemctl restart sing-box >/dev/null 2>&1
  else
    sb_stop_nohup >/dev/null 2>&1 || true
    nohup "$SB_BIN" run -c "$SB_DIR/config.json" >"$SB_DIR/singbox.log" 2>&1 &
    echo $! > "$SB_DIR/singbox.pid"
    disown 2>/dev/null || true
  fi
  sleep 1
  sb_is_running
}

sb_stop() {
  if have_systemd; then
    systemctl stop sing-box >/dev/null 2>&1 || true
  else
    sb_stop_nohup
  fi
  ok "sing-box 已停止"
  return 0
}

sb_is_running() {
  if have_systemd; then
    systemctl is-active --quiet sing-box 2>/dev/null
  else
    [ -f "$SB_DIR/singbox.pid" ] && kill -0 "$(cat "$SB_DIR/singbox.pid" 2>/dev/null)" 2>/dev/null
  fi
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

# ---------------- 订阅服务 systemd 单元 ----------------
# python3 -m http.server 原本是裸 nohup 进程：机器一重启订阅就 404，崩了也没人拉起。
# systemd 机器统一交给这个 unit 托管（Restart=always + 开机自启）。
sub_service_install() {
  have_systemd || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  local port="${SUB_PORT:-${SUB_PORT_DEFAULT:-8199}}" webroot="$SB_DIR/web" py
  [ -d "$webroot" ] || return 1
  py=$(command -v python3)
  cat > /etc/systemd/system/sb-sub.service <<EOF
[Unit]
Description=sb-smjm subscription http server
After=network.target

[Service]
Type=simple
WorkingDirectory=${webroot}
ExecStart=${py} -m http.server ${port} --bind 0.0.0.0
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now sb-sub >/dev/null 2>&1 || systemctl restart sb-sub >/dev/null 2>&1
  return 0
}

# 开机自启（无 systemd 时尝试 cron @reboot）
sb_enable_boot() {
  if have_systemd; then
    systemctl enable sing-box >/dev/null 2>&1 && ok "已设置开机自启 (systemd)"
    if [ -d "$SB_DIR/web" ] && sub_service_install >/dev/null 2>&1; then
      ok "订阅服务已注册开机自启 (sb-sub.service)"
    fi
    return 0
  fi
  if command -v crontab >/dev/null 2>&1; then
    if [ -f "$SB_DIR/boot.sh" ]; then
      ( crontab -l 2>/dev/null | grep -v "sb-smjm boot"; echo "@reboot $SB_DIR/boot.sh # sb-smjm boot" ) \
        | crontab - 2>/dev/null && ok "已设置开机自启 (crontab @reboot)"
    else
      # boot.sh 缺失时不要写入 @reboot，否则会留下指向不存在文件的死引用；
      # 顺手把历史遗留的同类条目清掉
      ( crontab -l 2>/dev/null | grep -v "sb-smjm boot" ) | crontab - 2>/dev/null || true
      warn "boot.sh 不存在，已跳过 crontab 开机自启（可先执行菜单 10 生成）"
    fi
    return 0
  fi
  warn "无 systemd/cron，无法设置开机自启，请自行配置守护进程"
  return 0
}

# ---------------- 内核网络优化 ----------------
# enable_bbr：开启内核 BBR + fq 拥塞控制并持久化。
# 为什么需要：sing-box 配置里的 "congestion_control": "bbr" 只作用于 TUIC（应用层 QUIC）；
# VLESS-Reality / VMess 等 TCP 协议走的是内核 TCP 栈，默认 cubic 算法。
# 高丢包/跨洋链路上 BBR 的吞吐明显更好。LXC 容器或受限内核开启失败时降级跳过，不影响安装。
enable_bbr() {
  command -v sysctl >/dev/null 2>&1 || { warn "无 sysctl，跳过内核 BBR 优化"; return 0; }
  local cur
  cur=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf '')
  if [ "$cur" = "bbr" ]; then
    ok "内核 BBR 已开启（无需处理）"
    return 0
  fi
  if ! sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
    warn "无法开启内核 BBR（LXC 容器/受限内核常见），已跳过，不影响使用"
    return 0
  fi
  printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' \
    > /etc/sysctl.d/99-sb-smjm.conf 2>/dev/null || true
  sysctl -p /etc/sysctl.d/99-sb-smjm.conf >/dev/null 2>&1 || true
  ok "内核 BBR + fq 已开启并持久化（/etc/sysctl.d/99-sb-smjm.conf）"
  return 0
}
