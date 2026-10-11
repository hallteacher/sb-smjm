#!/usr/bin/env bash
# ============================================================
# build.sh - 把 lib/*.sh 内联进 sb.sh / serv00.sh，输出单文件到 dist/
# 发布时只需 dist/sb.sh，保证 `bash <(curl -Ls .../sb.sh)` 一行可用
# 同时把 CRLF 统一成 LF（Windows 编辑器会写 CRLF，bash 对 CRLF 敏感）
# ============================================================
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p dist

# to_lf 文件：CRLF -> LF（无 sed 时用纯 bash 兜底）
to_lf() {
  local f="$1" tmp
  if command -v sed >/dev/null 2>&1; then
    sed -i 's/\r$//' "$f"
    return 0
  fi
  tmp=$(mktemp)
  while IFS= read -r _l || [ -n "$_l" ]; do printf '%s\n' "${_l%$'\r'}" >> "$tmp"; done < "$f"
  mv "$tmp" "$f"
}

# inline 主脚本 输出文件 模块...
# 用 @BEGIN LIBS@ / @END LIBS@ 标记区间替换为各模块内容
inline() {
  local main="$1" out="$2"; shift 2
  local libs=("$@")
  {
    # 标记之前的所有内容（含 @BEGIN LIBS@ 行本身）
    sed -n '1,/# @BEGIN LIBS@$/p' "$main"
    # 各模块内容（去掉 shebang）
    for m in "${libs[@]}"; do
      grep -v '^#!/usr/bin/env bash$' "$m"
      echo ""
    done
    # 标记之后的所有内容（含 @END LIBS@ 行本身到文件尾）
    sed -n '/# @END LIBS@$/,$p' "$main"
  } > "$out"
  to_lf "$out"
  chmod 0755 "$out"
}

echo "[build] 内联 sb.sh -> dist/sb.sh"
# 先统一行尾为 LF，否则 CRLF 会让 @BEGIN/@END 标记匹配失败
for f in sb.sh serv00.sh lib/*.sh build.sh tests/*.sh; do
  [ -f "$f" ] && to_lf "$f"
done
inline sb.sh dist/sb.sh lib/common.sh lib/install.sh lib/config.sh lib/argo.sh lib/subscription.sh

echo "[build] 内联 serv00.sh -> dist/serv00.sh"
inline serv00.sh dist/serv00.sh lib/common.sh lib/config.sh lib/subscription.sh

# 语法检查
bash -n sb.sh && echo "[build] sb.sh 语法 OK" || { echo "[build] sb.sh 语法错误"; exit 1; }
bash -n dist/sb.sh && echo "[build] dist/sb.sh 语法 OK" || { echo "[build] dist/sb.sh 语法错误"; exit 1; }
bash -n serv00.sh && echo "[build] serv00.sh 语法 OK" || { echo "[build] serv00.sh 语法错误"; exit 1; }
bash -n dist/serv00.sh && echo "[build] dist/serv00.sh 语法 OK" || { echo "[build] dist/serv00.sh 语法错误"; exit 1; }

echo "[build] 完成："
ls -la dist/ 2>/dev/null || true

