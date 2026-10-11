# ============================================================
# subscription.sh - 节点分享链接生成、Base64 订阅、本地 IP 订阅服务
# 依赖：SB_DIR IP4 IP6 UUID 等协议参数（全局）
# ============================================================

# 取本机地址：优先用户填的域名，其次 IPv4，其次 IPv6
node_host() {
  if [ -n "${NODE_ADDR:-}" ]; then
    printf '%s' "$NODE_ADDR"
  elif [ -n "${IP4:-}" ]; then
    printf '%s' "$IP4"
  elif [ -n "${IP6:-}" ]; then
    printf '%s' "$IP6"
  else
    printf '127.0.0.1'
  fi
}

# IPv6 地址加方括号（用于 URL）
bracket_host() {
  local h; h=$(node_host)
  case "$h" in
    *:*) printf '[%s]' "$h" ;;
    *)   printf '%s' "$h" ;;
  esac
}

# ================= 各协议分享链接 =================

# vless://uuid@host:port?encryption=none&flow=...&security=reality&sni=...&pbk=...&sid=...#name
link_vless() {
  local host; host=$(bracket_host)
  local name; name=$(url_encode "${NODE_NAME:-sb-smjm}-vless")
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n' \
    "$UUID" "$host" "$PORT_VLESS" "$REALITY_SNI" "$REALITY_PUBLIC" "$REALITY_SHORT" "$name"
}

# vmess://base64(json)  —— 明文/Argo 模式
link_vmess() {
  local host port tls security
  if [ "${ARGO_MODE:-none}" != "none" ] && [ -n "${ARGO_DOMAIN:-}" ]; then
    # Argo 模式且域名已就绪：地址=Argo 域名，端口 443，TLS 开
    # 【为什么必须再判域名非空】ARGO_MODE 非 none 但 ARGO_DOMAIN 为空时
    # （隧道没起来 / 域名没拿到），旧逻辑会生成 add 为空(或异常回退)、
    # 端口 443 + TLS 的废节点 —— 客户端测出来就是 -1 且永远连不上。
    # 这种情况降级为直连节点（IP + 明文 ws 端口），保证至少可用。
    host="$ARGO_DOMAIN"; port="443"; tls="tls"; security="tls"
  else
    host=$(node_host); port="$PORT_VMESS"; tls=""; security="none"
  fi
  local name; name=$(url_encode "${NODE_NAME:-sb-smjm}-vmess")
  local payload
  payload=$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s","tls":"%s","sni":"%s"}' \
    "$name" "$host" "$port" "$UUID" "$host" "$VMESS_PATH" "$tls" "${host}")
  printf 'vmess://%s\n' "$(printf '%s' "$payload" | b64)"
}

# vmess-ws-tls（自有证书/自签）
link_vmess_tls() {
  local host; host=$(node_host)
  local name; name=$(url_encode "${NODE_NAME:-sb-smjm}-vmess-tls")
  local payload
  payload=$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s","tls":"tls","sni":"%s"}' \
    "$name" "$host" "$PORT_VMESS_TLS" "$UUID" "$host" "$VMESS_PATH" "$host")
  printf 'vmess://%s\n' "$(printf '%s' "$payload" | b64)"
}

# hysteria2://password@host:port/?insecure=1&sni=...&alpn=h3#name
link_hysteria2() {
  local host; host=$(bracket_host)
  local name; name=$(url_encode "${NODE_NAME:-sb-smjm}-hysteria2")
  printf 'hysteria2://%s@%s:%s/?insecure=1&sni=%s&alpn=h3#%s\n' \
    "$HY2_PASSWORD" "$host" "$PORT_HY2" "$TLS_SNI" "$name"
}

# tuic://uuid:password@host:port?congestion_control=bbr&alpn=h3&allow_insecure=1&sni=...#name
link_tuic() {
  local host; host=$(bracket_host)
  local name; name=$(url_encode "${NODE_NAME:-sb-smjm}-tuic")
  printf 'tuic://%s:%s@%s:%s?congestion_control=bbr&alpn=h3&allow_insecure=1&sni=%s#%s\n' \
    "$UUID" "$TUIC_PASSWORD" "$host" "$PORT_TUIC" "$TLS_SNI" "$name"
}

# anytls://password@host:port/?insecure=1&sni=...#name
link_anytls() {
  local host; host=$(bracket_host)
  local name; name=$(url_encode "${NODE_NAME:-sb-smjm}-anytls")
  printf 'anytls://%s@%s:%s/?insecure=1&sni=%s#%s\n' \
    "$ANYTLS_PASSWORD" "$host" "$PORT_ANYTLS" "$TLS_SNI" "$name"
}

# 生成全部启用的节点链接，写入 $SB_DIR/nodes.txt（明文）与 $SB_DIR/sub.txt（base64 订阅）
build_subscription() {
  local out=""
  : "${REALITY_SNI:=$REALITY_SNI_DEFAULT}"
  : "${TLS_SNI:=$TLS_SNI_DEFAULT}"
  if [ "${ENABLE_VLESS:-n}" = "y" ]; then
    out="${out}$(link_vless)"
    out="${out}${out:+$'\n'}"
  fi
  if [ "${ENABLE_VMESS:-n}" = "y" ]; then
    out="${out}$(link_vmess)"
    out="${out}${out:+$'\n'}"
  fi
  if [ "${ENABLE_VMESS_TLS:-n}" = "y" ]; then
    out="${out}$(link_vmess_tls)"
    out="${out}${out:+$'\n'}"
  fi
  if [ "${ENABLE_HY2:-n}" = "y" ]; then
    out="${out}$(link_hysteria2)"
    out="${out}${out:+$'\n'}"
  fi
  if [ "${ENABLE_TUIC:-n}" = "y" ]; then
    out="${out}$(link_tuic)"
    out="${out}${out:+$'\n'}"
  fi
  if [ "${ENABLE_ANYTLS:-n}" = "y" ]; then
    out="${out}$(link_anytls)"
    out="${out}${out:+$'\n'}"
  fi

  if [ -z "$out" ]; then
    warn "未启用任何协议，订阅为空"
    return 1
  fi
  printf '%s\n' "$out" > "$SB_DIR/nodes.txt"
  printf '%s\n' "$out" | b64 > "$SB_DIR/sub.txt"
  ok "节点链接与订阅已生成: $SB_DIR/nodes.txt / $SB_DIR/sub.txt"
  return 0
}


# ================= 本地 IP 订阅服务 =================
# 在本机用 python3/busybox 起静态服务托管订阅文件
# 订阅地址: http://<IP>:<端口>/<订阅密码>/sub  （无密码时: http://<IP>:<端口>/sub）

SUB_PID_FILE="${SB_DIR}/subserver.pid"

# 准备 web 根目录，把订阅放进带密码的子目录
sub_ensure_webroot() {
  local webroot="$SB_DIR/web"
  local dir="$webroot"
  [ -n "${SUB_PASSWORD:-}" ] && dir="$webroot/${SUB_PASSWORD}"
  mkdir -p "$dir"
  cp -f "$SB_DIR/sub.txt" "$dir/sub" 2>/dev/null || true
  cp -f "$SB_DIR/sub.txt" "$dir/sub.txt" 2>/dev/null || true
  cp -f "$SB_DIR/nodes.txt" "$dir/nodes.txt" 2>/dev/null || true
  cat > "$webroot/index.html" <<EOF
<html><head><meta charset="utf-8"><title>sb-smjm sub</title></head>
<body><h3>sing-box-smjm 节点订阅</h3>
<p>订阅地址: http://<span id="h">IP</span>:${SUB_PORT:-8199}/$( [ -n "${SUB_PASSWORD:-}" ] && printf '%s/' "${SUB_PASSWORD}" )sub</p>
<script>document.getElementById('h').textContent=location.hostname;</script>
</body></html>
EOF
  return 0
}

sub_stop_server() {
  # systemd 机器上订阅服务由 sb-sub.service 托管，先停 unit（nohup 残留进程随后一并清）
  command -v systemctl >/dev/null 2>&1 && systemctl stop sb-sub >/dev/null 2>&1 || true
  if [ -f "$SUB_PID_FILE" ]; then
    local pid; pid=$(cat "$SUB_PID_FILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null; sleep 0.5; kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$SUB_PID_FILE"
  fi
  pkill -f "http.server ${SUB_PORT:-8199}" 2>/dev/null || true
  pkill -f "httpd -p ${SUB_PORT:-8199}" 2>/dev/null || true
  return 0
}

# 订阅 URL：优先运行时全局 SUB_URL（本会话刚生成过），否则从 state 变量推导。
# 【为什么需要】菜单 2 / --status 是全新进程，SUB_URL 从未被赋值 ——
# 旧版直接显示「订阅地址: 未启动」，哪怕服务明明活着。
sub_url() {
  local host; host=$(bracket_host)
  # 注意密码后必须有「/」再接 sub：webroot 结构是 web/<密码>/sub，
  # 少了这个斜杠（旧版 bug）带密码的订阅地址客户端拉取就是 404
  if [ -n "${SUB_PASSWORD:-}" ]; then
    printf 'http://%s:%s/%s/sub' "$host" "${SUB_PORT:-${SUB_PORT_DEFAULT:-8199}}" "$SUB_PASSWORD"
  else
    printf 'http://%s:%s/sub' "$host" "${SUB_PORT:-${SUB_PORT_DEFAULT:-8199}}"
  fi
}

# 订阅服务是否在跑（pid 文件判据）
sub_is_running() {
  [ -f "$SUB_PID_FILE" ] && kill -0 "$(cat "$SUB_PID_FILE" 2>/dev/null)" 2>/dev/null
}

# sub_start_server：成功返回 0，订阅 URL 写入全局 SUB_URL
sub_start_server() {
  sub_ensure_webroot
  local port="${SUB_PORT:-${SUB_PORT_DEFAULT:-8199}}"
  local webroot="$SB_DIR/web"
  sub_stop_server 2>/dev/null || true
  # systemd 机器交给 sb-sub.service（崩溃自拉起 + 开机自启）；
  # 无 systemd（Serv00 等）或注册失败时降级为 nohup 直跑
  if command -v have_systemd >/dev/null 2>&1 && have_systemd 2>/dev/null \
     && command -v sub_service_install >/dev/null 2>&1 && sub_service_install; then
    SUB_URL=$(sub_url)
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    ( cd "$webroot" && setsid nohup python3 -m http.server "$port" --bind 0.0.0.0 >/dev/null 2>&1 & echo $! > "$SUB_PID_FILE" )
  elif command -v busybox >/dev/null 2>&1; then
    ( setsid nohup busybox httpd -p "$port" -h "$webroot" >/dev/null 2>&1 & echo $! > "$SUB_PID_FILE" )
  else
    warn "本机无 python3/busybox，无法启动订阅服务（订阅文件仍在 $SB_DIR/sub.txt）"
    return 1
  fi
  sleep 1
  SUB_URL=$(sub_url)
  return 0
}

# 打印订阅信息（有 qrencode 时在终端直接显示可扫的二维码）
show_subscription() {
  line
  # SUB_URL 只在「本会话刚启动过服务」时才有值；这里兜底从 state 推导
  local url="${SUB_URL:-$(sub_url)}"
  info "订阅地址: $url"
  info "明文节点: $SB_DIR/nodes.txt"
  if sub_is_running; then
    ok "订阅服务: 运行中（端口 ${SUB_PORT:-${SUB_PORT_DEFAULT:-8199}}）"
  else
    warn "订阅服务未检测到在运行（重跑安装或菜单 4 重启后会自动拉起）"
  fi
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "$url" 2>/dev/null || true
  else
    info "（未安装 qrencode，不显示二维码；apt/dnf install qrencode 可开启，不影响节点使用）"
  fi
  line
  return 0
}
