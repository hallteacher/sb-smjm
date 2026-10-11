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

