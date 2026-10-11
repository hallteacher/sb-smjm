# ============================================================
# config.sh - sing-box 服务端配置生成（五协议）+ 自签证书 + reality 密钥对
# 依赖外部变量：SB_DIR ARCH IPSTACK，以及主脚本的协议开关与参数
# ============================================================

# 节点默认 SNI（ reality 偷的站 / 自签证书 CN）
REALITY_SNI_DEFAULT="www.yahoo.com"
TLS_SNI_DEFAULT="www.bing.com"

# 生成 reality 密钥对（写 REALITY_PRIVATE / REALITY_PUBLIC 两个全局变量）
gen_reality_keypair() {
  local out
  if [ -x "$SB_BIN" ]; then
    out=$("$SB_BIN" generate reality-keypair 2>/dev/null)
    REALITY_PRIVATE=$(printf '%s\n' "$out" | awk -F': ' '/PrivateKey/{print $2}')
    REALITY_PUBLIC=$(printf '%s\n' "$out" | awk -F': ' '/PublicKey/{print $2}')
  fi
  # 兜底：openssl x25519
  if [ -z "$REALITY_PRIVATE" ] || [ -z "$REALITY_PUBLIC" ]; then
    if command -v openssl >/dev/null 2>&1; then
      local tmp; tmp=$(mktemp -d)
      openssl genpkey -algorithm x25519 -out "$tmp/k.pem" >/dev/null 2>&1
      REALITY_PRIVATE=$(openssl pkey -in "$tmp/k.pem" -outform DER 2>/dev/null | tail -c 32 | od -An -tx1 | tr -d ' \n')
      openssl pkey -in "$tmp/k.pem" -pubout -outform DER 2>/dev/null >/dev/null
      REALITY_PUBLIC=$(openssl pkey -in "$tmp/k.pem" -pubout -outform DER 2>/dev/null | tail -c 32 | od -An -tx1 | tr -d ' \n')
      rm -rf "$tmp"
    fi
  fi
  if [ -z "$REALITY_PRIVATE" ] || [ -z "$REALITY_PUBLIC" ]; then
    die "无法生成 reality 密钥对（需要 sing-box 或 openssl）"
  fi
  return 0
}

# 生成自签证书（供 hysteria2 / tuic / anytls / vmess-ws-tls 使用）
gen_selfsigned_cert() {
  local cn="${1:-$TLS_SNI_DEFAULT}"
  command -v openssl >/dev/null 2>&1 || die "生成自签证书需要 openssl"
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -subj "/CN=${cn}" \
    -addext "subjectAltName=DNS:${cn}" \
    -keyout "$SB_DIR/key.pem" -out "$SB_DIR/cert.pem" >/dev/null 2>&1 \
    || die "openssl 生成自签证书失败"
  chmod 0644 "$SB_DIR/cert.pem"
  chmod 0600 "$SB_DIR/key.pem"
  ok "自签证书已生成 (CN=${cn})"
  return 0
}

# ============================================================
# 各协议 inbound 片段。每个函数输出一个 JSON 对象（不含前后逗号）。
# 参数通过全局变量传入：UUID / 端口 / 密码 / 路径 / SNI 等
# ============================================================

# --- VLESS-Reality-Vision ---
# 变量：PORT_VLESS REALITY_SNI REALITY_PRIVATE REALITY_SHORT
inbound_vless() {
  cat <<EOF
{
      "type": "vless",
      "tag": "vless-reality-vision",
      "listen": "::",
      "listen_port": ${PORT_VLESS},
      "users": [
        {
          "name": "${UUID}",
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${REALITY_SNI}",
            "server_port": 443
          },
          "private_key": "${REALITY_PRIVATE}",
          "short_id": [
            "${REALITY_SHORT}"
          ],
          "max_time_difference": "1m"
        }
      },
      "multiplex": {
        "enabled": true,
        "padding": true
      }
    }
EOF
}

# --- VMess-WS（明文，供 Argo / CDN 回源；无 Argo 时直接监听公网）---
# 变量：PORT_VMESS VMESS_PATH UUID VMESS_LISTEN
inbound_vmess_ws() {
  cat <<EOF
{
      "type": "vmess",
      "tag": "vmess-ws",
      "listen": "${VMESS_LISTEN:-127.0.0.1}",
      "listen_port": ${PORT_VMESS},
      "users": [
        {
          "name": "${UUID}",
          "uuid": "${UUID}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "${VMESS_PATH}"
      }
    }
EOF
}

# --- VMess-WS-TLS（自有证书；无域名时用自签 + 客户端 insecure）---
# 变量：PORT_VMESS_TLS VMESS_PATH TLS_SNI
inbound_vmess_ws_tls() {
  cat <<EOF
{
      "type": "vmess",
      "tag": "vmess-ws-tls",
      "listen": "::",
      "listen_port": ${PORT_VMESS_TLS},
      "users": [
        {
          "name": "${UUID}",
          "uuid": "${UUID}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${TLS_SNI}",
        "certificate_path": "${SB_DIR}/cert.pem",
        "key_path": "${SB_DIR}/key.pem"
      },
      "transport": {
        "type": "ws",
        "path": "${VMESS_PATH}"
      }
    }
EOF
}

# --- Hysteria2 ---
# 变量：PORT_HY2 HY2_PASSWORD
inbound_hysteria2() {
  cat <<EOF
{
      "type": "hysteria2",
      "tag": "hysteria2-in",
      "listen": "::",
      "listen_port": ${PORT_HY2},
      "users": [
        {
          "name": "${UUID}",
          "password": "${HY2_PASSWORD}"
        }
      ],
      "ignore_client_bandwidth": true,
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "${SB_DIR}/cert.pem",
        "key_path": "${SB_DIR}/key.pem"
      }
    }
EOF
}

# --- TUIC v5 ---
# 变量：PORT_TUIC TUIC_PASSWORD
inbound_tuic() {
  cat <<EOF
{
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": ${PORT_TUIC},
      "users": [
        {
          "name": "${UUID}",
          "uuid": "${UUID}",
          "password": "${TUIC_PASSWORD}"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "${SB_DIR}/cert.pem",
        "key_path": "${SB_DIR}/key.pem"
      }
    }
EOF
}

# --- AnyTLS（sing-box >= 1.12）---
# 变量：PORT_ANYTLS ANYTLS_PASSWORD
inbound_anytls() {
  cat <<EOF
{
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": ${PORT_ANYTLS},
      "users": [
        {
          "name": "${UUID}",
          "password": "${ANYTLS_PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": [
          "h2",
          "http/1.1"
        ],
        "certificate_path": "${SB_DIR}/cert.pem",
        "key_path": "${SB_DIR}/key.pem"
      }
    }
EOF
}

# ============================================================
# 组装完整 config.json
# 用法：build_config，读取全局协议开关
#   ENABLE_VLESS / ENABLE_VMESS / ENABLE_VMESS_TLS
#   ENABLE_HY2 / ENABLE_TUIC / ENABLE_ANYTLS
# 输出写入 $SB_DIR/config.json
# ============================================================
build_config() {
  local fragments=() f
  # 兜底：首次安装时 state.env 不存在，主脚本可能尚未初始化 SNI（set -u 下会报 unbound）
  : "${REALITY_SNI:=$REALITY_SNI_DEFAULT}"
  : "${TLS_SNI:=$TLS_SNI_DEFAULT}"
  [ "${ENABLE_VLESS:-n}"     = "y" ] && fragments+=("$(inbound_vless)")
  [ "${ENABLE_VMESS:-n}"     = "y" ] && fragments+=("$(inbound_vmess_ws)")
  [ "${ENABLE_VMESS_TLS:-n}" = "y" ] && fragments+=("$(inbound_vmess_ws_tls)")
  [ "${ENABLE_HY2:-n}"       = "y" ] && fragments+=("$(inbound_hysteria2)")
  [ "${ENABLE_TUIC:-n}"      = "y" ] && fragments+=("$(inbound_tuic)")
  [ "${ENABLE_ANYTLS:-n}"    = "y" ] && fragments+=("$(inbound_anytls)")

  if [ ${#fragments[@]} -eq 0 ]; then
    die "没有启用任何协议，无法生成配置"
  fi

  # 用换行+逗号连接各片段
  local inbounds="" i
  for ((i = 0; i < ${#fragments[@]}; i++)); do
    if [ "$i" -gt 0 ]; then inbounds="${inbounds}
,
"; fi
    inbounds="${inbounds}${fragments[$i]}"
  done

  cat > "$SB_DIR/config.json" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
${inbounds}
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
  ok "配置已生成: $SB_DIR/config.json （启用协议: ${#fragments[@]} 个）"
  return 0
}
