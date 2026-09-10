#!/usr/bin/env bash
# 上线探活。CI 用的就是这个脚本，你提 PR 之前自己跑一遍，判定和 CI 完全一致。
#
#   ./scripts/check-deploy.sh https://your-app.example.com
#   ./scripts/check-deploy.sh submissions/E2/yourname/DEPLOY.md   # 从 DEPLOY.md 的 URL: 行读地址（CI 走这条）
#
# 判定：地址必须是公网地址，且在预算时间内返回 2xx / 3xx。
# 退出码：0 通过 · 1 探不通 · 2 地址缺失或不合法。
set -uo pipefail

arg="${1:-}"
budget="${2:-300}"        # 最多等多少秒（默认 5 分钟，容忍免费实例冷启动）
per_try_timeout=30

if [[ -z "$arg" ]]; then
  echo "usage: $0 <url | path/to/DEPLOY.md> [budget_sec]" >&2
  exit 2
fi

# ---------- 取地址 ----------
url=""
if [[ -f "$arg" ]]; then
  # 去掉 BOM（Windows 记事本 / PowerShell 重定向会写），再找第一条 URL 行。
  # 容忍：全角冒号、行首列表符号、**加粗**、markdown 链接、行尾中文注释。
  line=$(sed $'1s/^\xef\xbb\xbf//' "$arg" \
         | grep -m1 -iE '^[[:space:]]*([-*][[:space:]]*)?(\*\*)?[[:space:]]*url[[:space:]]*(\*\*)?[[:space:]]*(:|：)')
  if [[ -z "$line" ]]; then
    echo "❌ ${arg} 里没有 URL 行。第一行请写成：URL: https://你的线上地址" >&2
    exit 2
  fi
  url=$(printf '%s\n' "$line" | grep -oE 'https?://[A-Za-z0-9._~:/?#@!$&*+=%-]+' | head -1)
  while [[ "$url" == *. ]]; do url="${url%.}"; done
  if [[ -z "$url" ]]; then
    echo "❌ 找到了 URL 行，但里面没有合法地址：" >&2
    echo "   ${line}" >&2
    echo "   正确写法：URL: https://你的线上地址（裸地址，别加尖括号或 markdown 链接）" >&2
    exit 2
  fi
  echo "· 从 ${arg} 读到：${url}" >&2
else
  url="$arg"
fi

if [[ ! "$url" =~ ^https?://[^[:space:]]+$ ]]; then
  echo "❌ 地址必须以 http:// 或 https:// 开头，且不含空格：${url}" >&2
  exit 2
fi

# ---------- 公网地址校验 ----------
# 只有你自己能打开的地址（本机 / 内网 / CGNAT）一律拒绝——包括十进制、十六进制、
# 省略写法这些等价形式，它们同样指向本机。
is_private_ip() {
  local ip="$1"
  case "$ip" in
    127.*|10.*|192.168.*|169.254.*|0.*|255.255.255.255) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
    ::1|::|::ffff:*|fc??:*|fd??:*|fe8?:*|fe9?:*|fea?:*|feb?:*) return 0 ;;
  esac
  return 1
}

hostport="${url#*://}"; hostport="${hostport%%/*}"; hostport="${hostport%%\?*}"; hostport="${hostport##*@}"
if [[ "$hostport" == \[* ]]; then
  host="${hostport#\[}"; host="${host%%\]*}"          # IPv6 字面量
else
  host="${hostport%%:*}"
fi
host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')

reject() { echo "❌ ${host} 不是公网地址——我们打不开它（$1）" >&2; exit 2; }

[[ -z "$host" ]] && reject "地址里没有主机名"
case "$host" in
  localhost|*.localhost|*.local|ip6-localhost|ip6-loopback) reject "本机地址" ;;
esac
# 纯数字 / 0x 开头 / 带前导零的写法都是 127.0.0.1 的等价形式，直接拒
if [[ "$host" =~ ^[0-9]+$ || "$host" =~ ^0[xX] ]]; then
  reject "请用域名或标准点分 IP"
fi
if [[ "$host" =~ ^[0-9.]+$ ]]; then
  if [[ ! "$host" =~ ^([1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$ ]]; then
    reject "IP 写法不合法（别用前导零 / 省略写法）"
  fi
  is_private_ip "$host" && reject "内网 / 本机网段"
fi
if [[ "$host" == *:* ]]; then
  is_private_ip "$host" && reject "IPv6 本机 / 内网地址"
fi
if [[ "$url" == http://* ]]; then
  echo "⚠️  用的是 http://（没有 TLS）。能过，但线上服务建议上 https。" >&2
fi

# ---------- 探活 ----------
# 按「总预算」重试，不按次数：有的平台冷启动期间会秒回 502，按次数重试会几秒内耗光。
# 不跟随重定向：3xx 本身就算活着，跟过去反而可能落到登录页或内网地址。
start=$SECONDS
delay=10
attempt=0
while :; do
  attempt=$((attempt + 1))
  out=$(curl -sS -o /dev/null --max-time "$per_try_timeout" \
        -w '%{http_code} %{remote_ip} %{time_total}' "$url" 2>&1)
  rc=$?
  code="${out%% *}"
  rest="${out#* }"; remote_ip="${rest%% *}"
  if [[ $rc -eq 0 && "$code" =~ ^[23][0-9][0-9]$ ]]; then
    if is_private_ip "$remote_ip"; then
      echo "❌ ${url} 解析到内网地址 ${remote_ip}——我们打不开它" >&2
      exit 2
    fi
    echo "✅ ${url} → HTTP ${code}（第 ${attempt} 次尝试，等了 $((SECONDS - start)) 秒）"
    exit 0
  fi
  echo "· 第 ${attempt} 次：${out}" >&2
  elapsed=$((SECONDS - start))
  remaining=$((budget - elapsed))
  [[ $remaining -le 5 ]] && break
  [[ $delay -gt $remaining ]] && delay=$remaining
  sleep "$delay"
  delay=$((delay * 2)); [[ $delay -gt 60 ]] && delay=60
done

echo "❌ ${url} 在 ${budget} 秒内没有返回 2xx/3xx（试了 ${attempt} 次）——判定为未上线 / 不可用" >&2
exit 1
