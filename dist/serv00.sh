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
# ============================================================
# common.sh - 通用函数：彩色输出、交互输入、系统/架构检测、包安装、随机数
# 注意：本文件由 build.sh 内联进主脚本，不要单独执行
# ============================================================

# ---------- 彩色输出 ----------
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
  C_RESET=$(tput sgr0); C_RED=$(tput setaf 1); C_GREEN=$(tput setaf 2)
  C_YELLOW=$(tput setaf 3); C_BLUE=$(tput setaf 6)
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

info()  { printf '%s[INFO]%s %s\n'  "$C_BLUE"   "$C_RESET" "$*"; }
ok()    { printf '%s[ OK ]%s %s\n'  "$C_GREEN"  "$C_RESET" "$*"; }
warn()  { printf '%s[WARN]%s %s\n'  "$C_YELLOW" "$C_RESET" "$*"; }
err()   { printf '%s[FAIL]%s %s\n'  "$C_RED"    "$C_RESET" "$*" >&2; }
die()   { err "$*"; exit 1; }
line()  { printf '%s======================================%s\n' "$C_BLUE" "$C_RESET"; }

# ---------- 品牌横幅（数码解码）----------
# 注：中文为全角字符、宽度因终端而异，故右边框不闭合，避免错位
brand_banner() {
  printf '%s  ╔══════════════════════════════════════════╗%s\n' "$C_GREEN" "$C_RESET"
  printf '%s  ║%s  %s★ 数 码 解 码 DECODING ★%s%s   用科技打开新世界%s\n' \
    "$C_GREEN" "$C_RESET" "$C_YELLOW" "$C_RESET" "$C_BLUE" "$C_RESET"
  printf '%s  ╚══════════════════════════════════════════╝%s\n' "$C_GREEN" "$C_RESET"
}

# ---------- 关于本脚本（频道 / 博客 / 群组）----------
show_about() {
  line
  printf '%s           感谢使用 sb-smjm%s\n' "$C_GREEN" "$C_RESET"
  printf '  %s更多教程与更新，欢迎关注:%s\n' "$C_YELLOW" "$C_RESET"
  line
  printf '  %s博客%s      https://smjmblog.blogspot.com/\n' "$C_BLUE" "$C_RESET"
  printf '  %sYouTube%s   https://www.youtube.com/@DECODING-w7d\n' "$C_BLUE" "$C_RESET"
  printf '  %sTelegram%s  https://t.me/+tVg48WK48tlkNGVl\n' "$C_BLUE" "$C_RESET"
  line
}


# ---------- 交互输入（兼容 printf 管道喂入，末行可无换行）----------
# read_line 变量名：读一行进变量，EOF 时若已有内容仍当作成功
read_line() {
  local var="$1" rc
  IFS= read -r "$var"
  rc=$?
  [ $rc -ne 0 ] && [ -z "${!var:-}" ] && return "$rc"
  return 0
}

# read_input "提示语" "默认值" 变量名
# 返回码：读到内容（含末行无换行）返回 0；EOF 且什么都没读到返回非 0（供菜单退出判断）
read_input() {
  local prompt="$1" default="$2" var="$3" val="" rc
  printf '%s* %s [%s]:%s ' "$C_YELLOW$prompt" "$C_RESET$default" "" "$C_RESET" >&2
  rc=0; read_line val || rc=$?
  [ -z "$val" ] && val="$default"
  printf -v "$var" '%s' "$val"
  return "$rc"
}

# confirm "提示语" [y|n] 变量名
confirm() {
  local prompt="$1" default="${2:-y}" var="$3" val="" hint
  if [ "$default" = "y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  printf '%s* %s %s:%s ' "$C_YELLOW$prompt" "$C_RESET$hint" "" "$C_RESET" >&2
  read_line val || true
  val="${val:-$default}"
  case "$val" in
    y|Y|yes|YES|Yes) val="y" ;;
    *) val="n" ;;
  esac
  printf -v "$var" '%s' "$val"
  return 0
}

# menu_select 变量名 "选项1" "选项2" ...（输出带序号菜单，读入序号）
menu_select() {
  local var="$1"; shift
  local i=1 choice
  for opt in "$@"; do
    printf '  %s%d)%s %s\n' "$C_GREEN" "$i" "$C_RESET" "$opt"
    i=$((i + 1))
  done
  printf '%s请输入序号 [1-%d]:%s ' "$C_YELLOW" "$((i - 1))" "$C_RESET" >&2
  read_line choice || true
  printf -v "$var" '%s' "$choice"
  return 0
}

# ---------- 权限 ----------
need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "该操作需要 root 权限，请使用 sudo 运行或以 root 登录"
    exit 1
  fi
}


# ---------- 系统 / 架构 / IP 栈检测 ----------
detect_os() {
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1090
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-}"
  else
    OS_ID="unknown"; OS_VERSION=""
  fi
  case "$OS_ID" in
    ubuntu|debian)      PKG_MGR="apt" ;;
    alpine)             PKG_MGR="apk" ;;
    centos|rhel|fedora|rocky|almalinux|amzn|ol) PKG_MGR="dnf_yum" ;;
    *)                  PKG_MGR="" ;;
  esac
  [ "$OS_ID" = "unknown" ] && warn "未能识别发行版(/etc/os-release 缺失)，部分功能可能受限"
  return 0
}

# detect_arch：失败返回非 0。ARCH 使用 sing-box/cloudflared 的命名
detect_arch() {
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

# cloudflared 的包名（armv7 叫 arm）
cf_arch() {
  [ "$ARCH" = "armv7" ] && printf 'arm' || printf '%s' "$ARCH"
}

# ---------- IP 工具：私网判定 + 公网探测 ----------
# is_private_ip：是否私网/保留地址（空值也算无效）。
# 【为什么需要】云主机（AWS/GCP/阿里云等）网卡上只有 VPC 内网 IP，公网 IP 是宿主侧
# 1:1 NAT 映射、从不出现在网卡上 —— 内网 IP 一旦写进节点链接，客户端测延迟必然全线 -1
# （AWS 实测：整机 5 个协议的地址全是内网 172.26.x.x）。
is_private_ip() {
  local ip="${1:-}" rest
  [ -z "$ip" ] && return 0
  case "$ip" in
    *:*)  # IPv6：链路本地 fe80::/10、唯一本地 fc00::/7、回环
      case "$ip" in
        fe80:*|fc*|fd*|::1) return 0 ;;
      esac
      return 1 ;;
  esac
  case "$ip" in
    [!0-9.]*|*[^0-9.]) return 0 ;;   # 不是裸 IPv4（HTML 报错页等）一律当无效
  esac
  case "${ip%%.*}" in
    0|10|127) return 0 ;;                                                      # 0/8 10/8 127/8
    100) rest="${ip#*.}"; rest="${rest%%.*}"                                    # 100.64/10 CGNAT
         [ "$rest" -ge 64 ] 2>/dev/null && [ "$rest" -le 127 ] 2>/dev/null && return 0 ;;
    169) case "$ip" in 169.254.*) return 0 ;; esac ;;                          # 链路本地（含 AWS 元数据）
    172) rest="${ip#*.}"; rest="${rest%%.*}"                                    # 172.16/12
         [ "$rest" -ge 16 ] 2>/dev/null && [ "$rest" -le 31 ] 2>/dev/null && return 0 ;;
    192) case "${ip#*.}" in 168.*) return 0 ;; esac ;;                         # 192.168/16
  esac
  return 1
}

# fetch_public_ip 4|6：探测本机公网地址（输出裸 IP；失败返回非 0）。
# 顺序：AWS IMDSv2 元数据（云主机上最准，就是本实例绑定的公网 IP/EIP）→ 公共 IP 接口
# （多备几个，个别被墙/故障也能中一个）。所有请求带短超时，断网/非云环境自动快速跳过。
fetch_public_ip() {
  local fam="${1:-4}" tok u ip
  # SB_NO_NETWORK=1：跳过一切外部探测（自动化测试 / 离线机房用，避免逐个等超时）
  [ "${SB_NO_NETWORK:-0}" = "1" ] && return 1
  command -v curl >/dev/null 2>&1 || return 1
  if [ "$fam" = "4" ]; then
    tok=$(curl -fsS -m 2 -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
          http://169.254.169.254/latest/api/token 2>/dev/null) || tok=""
    if [ -n "$tok" ]; then
      ip=$(curl -fsS -m 2 -H "X-aws-ec2-metadata-token: $tok" \
           http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null | tr -d '[:space:]') || ip=""
      if [ -n "$ip" ] && printf '%s' "$ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
         && ! is_private_ip "$ip"; then
        printf '%s' "$ip"; return 0
      fi
    fi
    for u in https://api.ipify.org https://ifconfig.me https://ip.sb; do
      ip=$(curl -4 -fsS -m 3 "$u" 2>/dev/null | tr -d '[:space:]') || ip=""
      if [ -n "$ip" ] && printf '%s' "$ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
         && ! is_private_ip "$ip"; then
        printf '%s' "$ip"; return 0
      fi
    done
  else
    for u in https://api64.ipify.org https://ifconfig.co https://ip.sb; do
      ip=$(curl -6 -fsS -m 3 "$u" 2>/dev/null | tr -d '[:space:]') || ip=""
      if [ -n "$ip" ] && printf '%s' "$ip" | grep -qE '^[0-9a-fA-F:]+$' \
         && printf '%s' "$ip" | grep -q ':' && ! is_private_ip "$ip"; then
        printf '%s' "$ip"; return 0
      fi
    done
  fi
  return 1
}

detect_ip() {
  IP4=""; IP6=""
  # ① 先问公网（元数据 / 公共接口）：云主机网卡上只有内网 IP，只读网卡会把
  #    172.x / 10.x 写进全部节点链接 —— AWS 上实测就是这么全线 -1 的
  IP4=$(fetch_public_ip 4 2>/dev/null) || IP4=""
  IP6=$(fetch_public_ip 6 2>/dev/null) || IP6=""
  # ② 兜底才读网卡（裸金属 / 内网直连场景），拿到私网地址会 WARN 提示
  if [ -z "$IP4" ] && command -v ip >/dev/null 2>&1; then
    IP4=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)
  fi
  if [ -z "$IP6" ] && command -v ip >/dev/null 2>&1; then
    IP6=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6 /{print $2}' | cut -d/ -f1 | grep -v '^fe80' | grep -v '^fd' | head -n1)
  fi
  if [ -z "$IP4" ] && command -v hostname >/dev/null 2>&1; then
    IP4=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  if [ -n "$IP4" ] && is_private_ip "$IP4"; then
    warn "探测到的 IPv4 $IP4 是内网地址（云主机需公网 IP），请在安装时手动填写「节点地址」"
  fi
  if [ -n "$IP4" ] && [ -n "$IP6" ]; then IPSTACK="dual"
  elif [ -n "$IP4" ]; then IPSTACK="v4"
  elif [ -n "$IP6" ]; then IPSTACK="v6"
  else IPSTACK="none"; warn "未检测到公网 IP，节点地址需手动填写"; fi
  return 0
}

# ---------- 包安装 ----------
# install_packages 包名...：已装跳过，未装按发行版安装
install_packages() {
  local pkgs=("$@") missing=() p
  for p in "${pkgs[@]}"; do
    command -v "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if [ ${#missing[@]} -eq 0 ]; then
    info "依赖已就绪: ${pkgs[*]}"
    return 0
  fi
  info "安装缺失依赖: ${missing[*]}"
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y >/dev/null 2>&1 || apt-get update -y >/dev/null 2>&1
      apt-get install -y "${missing[@]}" >/dev/null 2>&1
      ;;
    apk)
      apk update >/dev/null 2>&1
      apk add --no-cache "${missing[@]}" >/dev/null 2>&1
      ;;
    dnf_yum)
      if command -v dnf >/dev/null 2>&1; then
        dnf install -y "${missing[@]}" >/dev/null 2>&1
      else
        yum install -y "${missing[@]}" >/dev/null 2>&1
      fi
      ;;
    *)
      err "无可用包管理器，请手动安装: ${missing[*]}"
      return 1
      ;;
  esac
  for p in "${missing[@]}"; do
    command -v "$p" >/dev/null 2>&1 || { err "依赖安装失败: $p"; return 1; }
  done
  ok "依赖安装完成"
  return 0
}

# ---------- 随机数 / 编码 ----------
rand_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import uuid; print(uuid.uuid4())'
  elif command -v python >/dev/null 2>&1; then
    python -c 'import uuid; print(uuid.uuid4())'
  else
    die "无法生成 UUID，请安装 uuidgen 或 python3"
  fi
}

# rand_hex 字节数
rand_hex() {
  local n="${1:-8}"
  if [ -r /dev/urandom ]; then
    head -c "$n" /dev/urandom | od -An -tx1 | tr -d ' \n'
  elif command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$n"
  else
    die "无法生成随机数，需要 /dev/urandom 或 openssl"
  fi
}

# rand_password 长度（默认 16，去掉易混字符 0/O/1/l）
rand_password() {
  local n="${1:-16}" chars='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789'
  local i out="" c
  for ((i = 0; i < n; i++)); do
    c="${chars:$((RANDOM % ${#chars})):1}"
    out="${out}${c}"
  done
  printf '%s' "$out"
}

# b64：单行 base64（兼容 GNU -w0 与 busybox）
b64() {
  if printf '' | base64 -w0 >/dev/null 2>&1; then
    base64 -w0
  else
    base64 | tr -d '\n'
  fi
}

# url_encode "字符串"（优先 python3，兜底纯 bash）
url_encode() {
  local str="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$str"
    return
  fi
  if command -v python >/dev/null 2>&1; then
    python -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$str"
    return
  fi
  local i c hex out=""
  for ((i = 0; i < ${#str}; i++)); do
    c="${str:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"; out="${out}${hex}" ;;
    esac
  done
  printf '%s' "$out"
}


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
