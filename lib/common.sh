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

