# ============================================================
# argo.sh - Cloudflare Argo 隧道：临时隧道 / 固定 Token 隧道
# 依赖：CF_BIN SB_DIR PORT_VMESS；写入全局 ARGO_DOMAIN / ARGO_MODE
# ============================================================

ARGO_LOG="${ARGO_LOG:-$SB_DIR/argo.log}"
ARGO_PID_FILE="${ARGO_PID_FILE:-$SB_DIR/argo.pid}"
ARGO_BOOT_FILE="${ARGO_BOOT_FILE:-$SB_DIR/argo_boot.sh}"

# 取 argo.log 里最新的临时隧道域名（输出裸域名，取不到则为空）
# 【关键】trycloudflare 临时域名每次启动都会重新随机分配，且无法固定；
# 所以任何时候都不能只信 state.env 里存下来的旧值，必须回来重新读日志。
argo_domain_from_log() {
  grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$ARGO_LOG" 2>/dev/null \
    | tail -n1 | sed 's#^https://##'
}

# 已在运行的 argo 进程 PID（无则空）
argo_pid() {
  if [ -f "$ARGO_PID_FILE" ]; then
    local pid; pid=$(cat "$ARGO_PID_FILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      printf '%s' "$pid"; return 0
    fi
    rm -f "$ARGO_PID_FILE" 2>/dev/null
  fi
  pgrep -f "cloudflared.*tunnel" 2>/dev/null | head -n1
  return 0
}

argo_stop() {
  local pid; pid=$(argo_pid)
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null; sleep 0.5; kill -9 "$pid" 2>/dev/null || true
    ok "Argo 隧道已停止"
  fi
  rm -f "$ARGO_PID_FILE" 2>/dev/null
  return 0
}

# argo_run_temp：临时隧道（trycloudflare 域名）
# 从日志里提取 https://xxx.trycloudflare.com
argo_run_temp() {
  local local_url="http://127.0.0.1:${PORT_VMESS}"
  argo_stop 2>/dev/null || true
  info "启动 Argo 临时隧道（隧道域名获取中，约 5-10 秒）..."
  rm -f "$ARGO_LOG"
  # setsid 并非处处存在（部分精简系统/容器没有），缺了就退化为 nohup
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup "$CF_BIN" tunnel --url "$local_url" --no-autoupdate --edge-ip-version auto \
      > "$ARGO_LOG" 2>&1 &
  else
    nohup "$CF_BIN" tunnel --url "$local_url" --no-autoupdate --edge-ip-version auto \
      > "$ARGO_LOG" 2>&1 &
  fi
  echo $! > "$ARGO_PID_FILE"
  disown 2>/dev/null || true

  # 轮询日志拿域名
  local i domain=""
  for i in $(seq 1 20); do
    sleep 1
    domain=$(argo_domain_from_log)
    [ -n "$domain" ] && break
  done
  if [ -z "$domain" ]; then
    err "未能从日志获取 Argo 临时域名，请查看: $ARGO_LOG"
    tail -n 15 "$ARGO_LOG" 2>/dev/null || true
    return 1
  fi
  ARGO_DOMAIN="$domain"
  ARGO_MODE="temp"
  ok "Argo 临时隧道域名: $ARGO_DOMAIN"
  return 0
}

# argo_run_token：固定 Token 隧道
# 用户需在 Cloudflare 侧创建隧道并拿到 Token，域名解析由用户在 CF 后台配置
argo_run_token() {
  local token="${1:-$ARGO_TOKEN}"
  if [ -z "$token" ]; then
    err "未提供 Argo 隧道 Token"
    return 1
  fi
  argo_stop 2>/dev/null || true
  info "启动 Argo 固定 Token 隧道..."
  rm -f "$ARGO_LOG"
  setsid nohup "$CF_BIN" tunnel --no-autoupdate run --token "$token" \
    > "$ARGO_LOG" 2>&1 &
  echo $! > "$ARGO_PID_FILE"
  disown 2>/dev/null || true
  sleep 3
  if ! kill -0 "$(cat "$ARGO_PID_FILE" 2>/dev/null)" 2>/dev/null; then
    err "Argo 隧道启动失败，请查看: $ARGO_LOG"
    tail -n 15 "$ARGO_LOG" 2>/dev/null || true
    return 1
  fi
  ARGO_MODE="token"
  ok "Argo 固定隧道已运行（请在 CF 后台把域名指向 127.0.0.1:${PORT_VMESS} 的服务）"
  return 0
}

# ============================================================
# 临时隧道域名保活
# 背景：trycloudflare 临时域名每次启动都会换，而节点订阅里写的是「当时那个域名」。
# 隧道一旦重启（systemd Restart=always / 崩溃 / 重启机器），订阅就指向一个已经
# 失效的域名 —— 表现就是只有 VMess-WS(Argo) 这条线连不上，其它协议照常可用。
# 下面几个函数负责把「当前真实域名」重新同步回 state.env 与订阅文件。
# ============================================================

# 把日志里的真实域名同步进 state.env 并重建订阅
# 返回 0 = 域名有变化且已同步；1 = 无需同步（非临时模式 / 拿不到域名 / 域名没变）
argo_sync_domain() {
  [ "${ARGO_MODE:-none}" = "temp" ] || return 1
  local new old
  new=$(argo_domain_from_log)
  [ -n "$new" ] || return 1
  old="${ARGO_DOMAIN:-}"
  [ "$new" != "$old" ] || return 1
  ARGO_DOMAIN="$new"
  save_state 2>/dev/null || true
  build_subscription >/dev/null 2>&1 || true
  sub_ensure_webroot >/dev/null 2>&1 || true
  ok "Argo 域名已更新: ${old:-（空）} -> $new（订阅已重建）"
  return 0
}

# argo_run_temp_fg：前台托管临时隧道（systemd 用）
# 起隧道 -> 等域名 -> 同步订阅 -> wait 住，隧道退出时返回，由 systemd 拉起再来一轮，
# 因此每次重开隧道都会顺手把新域名写回订阅。
argo_run_temp_fg() {
  local local_url="http://127.0.0.1:${PORT_VMESS}"
  argo_stop 2>/dev/null || true
  rm -f "$ARGO_LOG"
  info "启动 Argo 临时隧道（前台托管）..."
  "$CF_BIN" tunnel --url "$local_url" --no-autoupdate --edge-ip-version auto \
    >> "$ARGO_LOG" 2>&1 &
  local pid=$!
  echo "$pid" > "$ARGO_PID_FILE"

  local i domain=""
  for i in $(seq 1 20); do
    sleep 1
    domain=$(argo_domain_from_log)
    [ -n "$domain" ] && break
  done
  if [ -n "$domain" ]; then
    ARGO_MODE="temp"
    if [ "$domain" != "${ARGO_DOMAIN:-}" ]; then
      ARGO_DOMAIN="$domain"
      save_state 2>/dev/null || true
      build_subscription >/dev/null 2>&1 || true
      sub_ensure_webroot >/dev/null 2>&1 || true
      ok "Argo 临时隧道域名: $ARGO_DOMAIN（订阅已重建）"
    else
      ok "Argo 临时隧道域名未变: $ARGO_DOMAIN"
    fi
  else
    warn "未能获取 Argo 临时域名，见 $ARGO_LOG"
  fi
  wait "$pid"
}



# argo_heal：一键自愈 —— 无论卡在哪一步都拉回正轨
#   1) 自我更新到 GitHub 最新版脚本（老副本可能还没有这些自愈逻辑）
#   2) argo_guard：隧道没跑/假死 → 拉起或重启，拿到新域名并重建订阅
#   3) 兜底：上面两步后日志里仍无域名 → 强制重启一次隧道
#   4) 确保开机自启 + 保活已注册（防止旧安装漏注册导致没人兜底）
#   5) sing-box 在跑就重启一次（让 config 与订阅严格一致）
argo_heal() {
  need_root
  line; info "开始自愈（Argo 隧道 + 订阅）"; line
  local self="$0"
  if [ -f "$self" ] && command -v curl >/dev/null 2>&1 && [ -n "${SCRIPT_URL:-}" ]; then
    if curl -fsSL --max-time 60 -o "$SB_DIR/sb.sh.new" "$SCRIPT_URL" 2>/dev/null; then
      mv -f "$SB_DIR/sb.sh.new" "$SB_DIR/sb.sh" 2>/dev/null && chmod 0755 "$SB_DIR/sb.sh" 2>/dev/null
      ok "脚本副本已更新到最新版"
    fi
  fi
  load_state 2>/dev/null || true
  # 与 argo_off 同理：heal 也可能被单独执行（bash sb.sh --heal），
  # 重建订阅前先补齐 IP4/IP6，避免 set -u 下 unbound variable
  detect_ip 2>/dev/null || true
  if [ "${ARGO_MODE:-none}" = "none" ]; then
    warn "本机未启用 Argo 隧道（ARGO_MODE=none），无需修复 Argo"
  else
    argo_guard || warn "argo_guard 未成功，尝试强制重启隧道 ..."
    if [ "${ARGO_MODE:-none}" = "temp" ] && [ -z "$(argo_domain_from_log)" ]; then
      warn "仍拿不到隧道域名，强制重启隧道 ..."
      argo_run_temp || warn "强制重启仍失败，请把 $ARGO_LOG 末尾内容发给我排查"
    fi
  fi
  # 保活注册兜底（不覆盖已有配置，只补漏）
  if [ "${ARGO_MODE:-none}" != "none" ]; then
    argo_enable_boot >/dev/null 2>&1 || true
  fi
  if sb_is_running 2>/dev/null; then
    sb_restart
    ok "sing-box 已重启"
  fi
  if [ "${ARGO_MODE:-none}" != "none" ]; then
    if [ -n "$(argo_domain_from_log)" ]; then
      ok "自愈完成：隧道域名 = $(argo_domain_from_log)，订阅已重建，客户端刷新一次订阅即可"
    else
      warn "自愈结束但未取到隧道域名（Argo 线暂不可用，其余节点不受影响）"
    fi
  else
    ok "自愈完成"
  fi
  return 0
}

# argo_off：彻底关闭 Argo（停隧道、撤自启/保活），VMess 改回公网直连
# 场景：临时隧道域名不可用 / 不需要 CDN 应急线，让 VMess 直接监听公网
# 与 argo_heal 的区别：heal 修隧道；off 是把 Argo 拆掉、恢复「无 Argo」的直连形态
argo_off() {
  need_root
  line; info "关闭 Argo：VMess 将改为公网直连监听"; line
  load_state 2>/dev/null || true
  # set -u 下 build_subscription 的 node_host() 会读 IP4/IP6；--direct 单独运行时
  # 安装流程没跑过，必须先探测公网 IP，否则报 "IP4: unbound variable" 且订阅重建失败
  detect_ip 2>/dev/null || true
  # ① 撤开机自启 + 保活（systemd unit / cron 两条腿都拆干净）
  if have_systemd; then
    systemctl disable --now argo-smjm >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/argo-smjm.service
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  if command -v crontab >/dev/null 2>&1; then
    crontab -l 2>/dev/null | grep -v "# sb-smjm argo" | crontab - 2>/dev/null || true
  fi
  # ② 停隧道进程
  argo_stop
  # ③ 状态切换：无 Argo、VMess 公网监听（与安装时选 n 的形态一致）
  ARGO_MODE=none
  VMESS_LISTEN="::"
  save_state
  # ④ 重建 sing-box 配置 + 订阅，重启生效（heal 不重建配置，所以必须在这里做）
  build_config
  build_subscription
  # web/ 是 HTTP 订阅服务的根目录：build_subscription 只写 $SB_DIR 下的源文件，
  # 不刷新 web/ —— 漏了这一步，客户端拉订阅拿到的还是旧地址/旧域名
  sub_ensure_webroot >/dev/null 2>&1 || true
  sb_restart
  ok "已关闭 Argo：VMess 公网监听 [::]:${PORT_VMESS:-8080}（ws 路径 ${VMESS_PATH:-未设置}）"
  ok "客户端刷新一次订阅，VMess 节点地址即变为 服务器IP:${PORT_VMESS:-8080}"
  return 0
}



# argo_write_boot_script：生成 $ARGO_BOOT_FILE（开机自启 / 保活入口）
# 【为什么需要】boot.sh 与 crontab 都在调用 $SB_DIR/argo_boot.sh，但项目里
# 从来没有生成过它 —— 无 systemd 的机器上 Argo 的开机自启实际是空转。
argo_write_boot_script() {
  local self
  if ! self=$(sb_self_persist); then
    warn "无法把脚本持久化到 $SB_DIR/sb.sh，跳过 argo_boot.sh 生成"
    return 1
  fi
  cat > "$ARGO_BOOT_FILE" <<EOF
#!/usr/bin/env bash
# sb-smjm: Argo 开机自启 / 域名保活（由 sb.sh 自动生成，请勿手改）
#   无参数        确保隧道在跑；临时隧道换域名时自动重建订阅（cron @reboot / 每 5 分钟）
#   --foreground  前台托管隧道（systemd 用，隧道每次重启都会刷新域名与订阅）
SB_DIR="${SB_DIR}"
exec bash "${self}" --argo-guard "\$@"
EOF
  chmod 0755 "$ARGO_BOOT_FILE" 2>/dev/null || true
  ok "Argo 保活脚本已生成: $ARGO_BOOT_FILE"
  return 0
}

# argo_guard [--foreground]：Argo 保活入口（argo_boot.sh / cron 调用）
# 隧道没跑就拉起；临时隧道换了域名就把新域名同步回 state.env 与订阅文件
argo_guard() {
  local fg="${1:-}"
  load_state 2>/dev/null || true
  # cron/新进程里 IP4 未初始化：下面所有重建订阅的分支都依赖它，
  # 不探测的话非 VMess 节点会被写成 127.0.0.1（和 AWS 内网 IP 同族的废节点问题）
  detect_ip 2>/dev/null || true
  case "${ARGO_MODE:-none}" in
    none) return 0 ;;
  esac
  if [ "$fg" = "--foreground" ]; then
    if [ "$ARGO_MODE" = "temp" ]; then
      argo_run_temp_fg
      return $?
    fi
    argo_stop 2>/dev/null || true
    "$CF_BIN" tunnel --no-autoupdate run --token "${ARGO_TOKEN:-}"
    return $?
  fi
  if [ -z "$(argo_pid)" ]; then
    info "Argo 隧道未运行，正在拉起 ..."
    if [ "$ARGO_MODE" = "temp" ]; then
      argo_run_temp >/dev/null 2>&1 || { err "Argo 临时隧道拉起失败"; return 1; }
      save_state 2>/dev/null || true
      build_subscription >/dev/null 2>&1 || true
      sub_ensure_webroot >/dev/null 2>&1 || true
      ok "Argo 临时隧道已拉起: ${ARGO_DOMAIN:-未知}（订阅已重建）"
    else
      argo_run_token "${ARGO_TOKEN:-}" >/dev/null 2>&1 || { err "Argo 固定隧道拉起失败"; return 1; }
    fi
    return 0
  fi
  # 进程还活着，但临时隧道日志里始终没有域名 → 多半是假死
  # （cloudflared 卡在连边缘/注册失败，不退出也不写域名）。
  # 日志 2 分钟内有新动静说明可能正在重连，先不动它；否则直接重启换新域名。
  if [ "$ARGO_MODE" = "temp" ] && [ -z "$(argo_domain_from_log)" ]; then
    local fresh=0
    [ -f "$ARGO_LOG" ] && [ -n "$(find "$ARGO_LOG" -mmin -2 2>/dev/null)" ] && fresh=1
    if [ "$fresh" = 0 ]; then
      info "Argo 隧道疑似假死（进程在但拿不到域名），正在重启 ..."
      argo_run_temp >/dev/null 2>&1 || { err "Argo 临时隧道重启失败"; return 1; }
      save_state 2>/dev/null || true
      build_subscription >/dev/null 2>&1 || true
      sub_ensure_webroot >/dev/null 2>&1 || true
      ok "Argo 临时隧道已重启: ${ARGO_DOMAIN:-未知}（订阅已重建）"
    fi
    return 0
  fi
  argo_sync_domain >/dev/null 2>&1 || true
  return 0
}


# Argo 开机自启 + 域名保活（有 systemd 用 unit，否则用 cron）
argo_enable_boot() {
  [ "${ARGO_MODE:-none}" != "none" ] || return 0
  argo_write_boot_script >/dev/null 2>&1 || true
  if have_systemd; then
    if [ "${ARGO_MODE:-none}" = "temp" ]; then
      # 交给 argo_boot.sh 托管：隧道每次重启都会重新取域名并重建订阅
      cat > /etc/systemd/system/argo-smjm.service <<EOF
[Unit]
Description=cloudflared temp tunnel guardian (sb-smjm)
After=network.target

[Service]
Type=simple
ExecStart=$ARGO_BOOT_FILE --foreground
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload >/dev/null 2>&1 || true
      systemctl enable --now argo-smjm >/dev/null 2>&1 || true
      ok "Argo 临时隧道已设为开机自启 (systemd，含域名保活)"
    elif [ "${ARGO_MODE:-none}" = "token" ]; then
      cat > /etc/systemd/system/argo-smjm.service <<EOF
[Unit]
Description=cloudflared token tunnel (sb-smjm)
After=network.target

[Service]
Type=simple
ExecStart=$CF_BIN tunnel --no-autoupdate run --token ${ARGO_TOKEN}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload >/dev/null 2>&1 || true
      systemctl enable --now argo-smjm >/dev/null 2>&1 || true
      ok "Argo 固定隧道已设为开机自启 (systemd)"
    fi
    return 0
  fi
  if command -v crontab >/dev/null 2>&1; then
    # @reboot 拉起隧道；每 5 分钟兜底检查（隧道挂了就拉起，临时隧道换域名就重建订阅）
    ( crontab -l 2>/dev/null | grep -v "# sb-smjm argo"
      echo "@reboot $ARGO_BOOT_FILE # sb-smjm argo"
      echo "*/5 * * * * $ARGO_BOOT_FILE # sb-smjm argo" ) | crontab - 2>/dev/null \
      && ok "Argo 已设置开机自启与保活 (crontab @reboot + 每 5 分钟)"
  else
    warn "无 systemd/cron，Argo 无保活，请自行配置守护进程"
  fi
  return 0
}
