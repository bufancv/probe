#!/usr/bin/env bash
# bufancv.com 生产探针 — 无缓存端到端链路检查。
#
# 用法: ./probe.sh          退出码 0=全绿, 1=有失败
#
# 设计要点:
# - 「回源穿透」探针请求一个必然不存在的随机路径:CDN 无法命中缓存,必须回源。
#   期望 404 = DNS→CDN边缘→TLS→源站 nginx→上游 整条链路通;502/超时 = 回源断。
#   (2026-07-13 事故:nginx catchall 拒掉 CDN 空 SNI 回源握手,CDN 缓存把故障
#   藏了 18 小时——常规「命中缓存」的拨测全绿,只有这种探针能当场发现。)
# - 每个探针自带重试(共 RETRIES 次,间隔 RETRY_GAP 秒),吸收跨境网络抖动。
# - 不 fail-fast:全部跑完统一汇总,一次告警看到全貌。
set -uo pipefail

TIMEOUT=${TIMEOUT:-20}
RETRIES=${RETRIES:-3}
RETRY_GAP=${RETRY_GAP:-15}
UA='BufanProbe/1.0 (+https://github.com/bufancv)'

PASSED=()
FAILED=()

# http_probe <名称> <期望状态码正则> <url> [响应体必含正则]
http_probe() {
  local name=$1 expect=$2 url=$3 body_re=${4:-}
  local attempt code secs body out
  for attempt in $(seq 1 "$RETRIES"); do
    body=$(mktemp)
    out=$(curl -sS -A "$UA" -o "$body" --max-time "$TIMEOUT" -w '%{http_code} %{time_total}' "$url" 2>/dev/null) || out='000 -'
    code=${out%% *}
    secs=$(printf '%.2f' "${out##* }" 2>/dev/null || echo '-')
    if [[ "$code" =~ ^($expect)$ ]]; then
      if [[ -n "$body_re" ]] && ! grep -q "$body_re" "$body"; then
        rm -f "$body"
        if (( attempt < RETRIES )); then sleep "$RETRY_GAP"; continue; fi
        FAILED+=("$name → HTTP $code 但响应体缺少期望内容 ($url)")
        return 1
      fi
      rm -f "$body"
      PASSED+=("$name → HTTP $code, ${secs}s")
      return 0
    fi
    rm -f "$body"
    if (( attempt < RETRIES )); then sleep "$RETRY_GAP"; fi
  done
  FAILED+=("$name → HTTP $code, 期望 $expect ($url)")
  return 1
}

# cert_probe <名称> <host> <最少剩余天数>
cert_probe() {
  local name=$1 host=$2 min_days=$3
  local end epoch_end days
  end=$(echo | timeout "$TIMEOUT" openssl s_client -servername "$host" -connect "$host:443" 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  if [[ -z "$end" ]]; then
    FAILED+=("$name → 无法读取证书 ($host:443)")
    return 1
  fi
  epoch_end=$(date -d "$end" +%s)
  days=$(( (epoch_end - $(date +%s)) / 86400 ))
  local end_cn
  end_cn=$(TZ=Asia/Shanghai date -d "$end" '+%F')
  if (( days < min_days )); then
    FAILED+=("$name → 证书仅剩 $days 天,${end_cn} 到期 (<${min_days}d, $host)")
    return 1
  fi
  PASSED+=("$name → 剩 ${days} 天,${end_cn} 到期")
  return 0
}

# 随机路径保证每次运行都击穿缓存
UNIQ="bufan-probe-$(date +%s)-$RANDOM"

http_probe 'web 首页'                 '200'     'https://bufancv.com/' '不繁简历'
http_probe 'api 存活 (/api/me 匿名)'   '401|200' 'https://bufancv.com/api/me'
http_probe 'assets CDN 回源穿透'       '404'     "https://assets.bufancv.com/_nuxt/${UNIQ}.js"
http_probe 'cdn(OSS)回源穿透'          '404|403' "https://cdn.bufancv.com/${UNIQ}"
cert_probe 'cert bufancv.com'         'bufancv.com'        14
cert_probe 'cert assets.bufancv.com'  'assets.bufancv.com' 14
cert_probe 'cert cdn.bufancv.com'     'cdn.bufancv.com'    14

echo "==== bufancv probe $(TZ=Asia/Shanghai date '+%F %T CST') ===="
if (( ${#PASSED[@]} )); then
  for p in "${PASSED[@]}"; do echo "✅ $p"; done
fi
if (( ${#FAILED[@]} )); then
  for f in "${FAILED[@]}"; do echo "❌ $f"; done
  exit 1
fi
echo '全部通过'
