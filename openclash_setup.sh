#!/bin/sh
# ============================================================
#  OpenClash 通用安装配置脚本
#  适用: OpenWrt / ImmortalWrt / iStoreOS (aarch64)
#  功能: 安装 OpenClash + 内核 + 订阅 + 启动 + 自动选最快节点
# ============================================================
#  用法:
#    sh openclash_setup.sh                 # 交互式输入订阅
#    sh openclash_setup.sh "订阅链接"       # 命令行传订阅
#    OC_VER=0.47.156 sh openclash_setup.sh # 指定版本
# ============================================================

set -eu

# ---------- 颜色 ----------
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; CYAN="\033[0;36m"; NC="\033[0m"
ok()   { printf "%b  [OK] %b%s%b\n" "$GREEN" "$NC" "$1" "$NC"; }
fail() { printf "%b  [FAIL] %b%s%b\n" "$RED" "$NC" "$1" "$NC"; }
info() { printf "%b  [..] %b%s%b\n" "$CYAN" "$NC" "$1" "$NC"; }
warn() { printf "%b  [!] %b%s%b\n" "$YELLOW" "$NC" "$1" "$NC"; }

# ---------- 可配置（通过环境变量/参数覆盖，无硬编码默认）----------
# OpenClash 版本（可通过 OC_VER 环境变量或第一个参数覆盖）
OC_VERSION="${OC_VER:-}"
SUB_URL=""
AUTO_SWITCH="1"

echo "=============================================="
echo "  OpenClash 通用安装配置脚本"
echo "=============================================="
echo ""

# ============================================================
# 1. 解析参数
# ============================================================
# 第一个参数可以是订阅链接 或 版本号
# 优先：命令行第1参数为订阅；OC_VER 环境变量为版本
if [ -n "${1:-}" ]; then
  SUB_URL="$1"
  info "使用命令行提供的订阅链接"
fi

# ============================================================
# 2. 检查环境
# ============================================================
info "检查环境..."
[ "$(id -u)" = "0" ] || { fail "需要 root 权限"; exit 1; }
command -v curl >/dev/null 2>&1 || { fail "需要 curl"; exit 1; }
command -v opkg >/dev/null 2>&1 || { fail "需要 opkg"; exit 1; }
ARCH=$(uname -m)
case "$ARCH" in
  aarch64|arm64) CORE_ARCH="arm64" ;;
  x86_64|amd64) CORE_ARCH="amd64" ;;
  armv7l|arm) CORE_ARCH="armv7" ;;
  *) warn "未知架构 $ARCH，默认按 arm64 处理"; CORE_ARCH="arm64" ;;
esac
info "检测架构: $ARCH (内核 $CORE_ARCH)"
command -v jq >/dev/null 2>&1 || { info "安装 jq..."; opkg install jq >/dev/null 2>&1 || true; }
ok "环境正常"

# ============================================================
# 3. 输入订阅链接（不提供默认，必须输入）
# ============================================================
if [ -z "$SUB_URL" ]; then
  echo ""
  echo "  请粘贴你的 OpenClash 订阅链接："
  echo "  （Clash/Stash/V2ray 等格式，通常以 http:// 或 https:// 开头）"
  printf "%b  订阅链接: %b" "$CYAN" "$NC"
  read USER_SUB
  SUB_URL="$USER_SUB"
fi

# 校验订阅链接
case "$SUB_URL" in
  http://*|https://*) ok "订阅链接格式正常" ;;
  *) fail "订阅链接格式错误，需以 http:// 或 https:// 开头"; exit 1 ;;
esac

# ============================================================
# 4. 询问是否自动测速切换
# ============================================================
if [ -n "${AUTO_SWITCH_ARG:-}" ]; then
  AUTO_SWITCH="$AUTO_SWITCH_ARG"
else
  echo ""
  printf "%b  是否测速并自动切换最快节点？[Y/n] %b" "$YELLOW" "$NC"
  read ANS
  case "$ANS" in
    n|N|no|NO) AUTO_SWITCH="0" ;;
    *) AUTO_SWITCH="1" ;;
  esac
fi
echo ""

# ============================================================
# 5. 确定 OpenClash 版本
# ============================================================
if [ -z "$OC_VERSION" ]; then
  info "未指定版本，从 GitHub 获取最新版..."
  OC_VERSION=$(curl -fsSL "https://api.github.com/repos/vernesong/OpenClash/releases/latest" 2>/dev/null | grep -oE "\"tag_name\": *\"v[0-9.]+\"" | grep -oE "v[0-9.]+" | head -1)
  [ -n "$OC_VERSION" ] || { fail "获取最新版本失败，请手动指定 OC_VER=版本号"; exit 1; }
  info "最新版本: $OC_VERSION"
else
  info "使用指定版本: v$OC_VERSION"
fi
# 去掉可能的 v 前缀
OC_VERSION="${OC_VERSION#v}"

# ============================================================
# 6. 检查是否已安装
# ============================================================
if [ -f /etc/init.d/openclash ] && [ -f /etc/openclash/core/clash_meta ]; then
  ok "OpenClash 已安装，跳过安装"
else
  info "安装依赖 (ruby/unzip/ip-full)..."
  opkg update >/dev/null 2>&1
  for dep in unzip ip-full ruby ruby-yaml; do
    opkg list-installed 2>/dev/null | grep -q "^$dep " || opkg install $dep >/dev/null 2>&1
  done

  info "下载 OpenClash v$OC_VERSION..."
  mkdir -p /tmp/oc-install && cd /tmp/oc-install
  curl -fsSL -o luci-app-openclash.ipk "https://github.com/vernesong/OpenClash/releases/download/v${OC_VERSION}/luci-app-openclash_${OC_VERSION}_all.ipk" 2>/dev/null || \
  curl -fsSL -o luci-app-openclash.ipk "https://cdn.jsdelivr.net/gh/vernesong/OpenClash@package/master/luci-app-openclash_${OC_VERSION}_all.ipk" 2>/dev/null || \
  { fail "下载 OpenClash 失败"; exit 1; }
  opkg install --force-depends luci-app-openclash.ipk >/dev/null 2>&1 || { fail "安装失败"; exit 1; }
  ok "OpenClash 已安装"

  info "下载 clash 内核 ($CORE_ARCH)..."
  mkdir -p /etc/openclash/core
  curl -fsSL -o /tmp/clash_meta.tar.gz "https://cdn.jsdelivr.net/gh/vernesong/OpenClash@core/dev/meta/clash-linux-${CORE_ARCH}.tar.gz" 2>/dev/null || \
  { fail "下载内核失败"; exit 1; }
  tar xzf /tmp/clash_meta.tar.gz -C /etc/openclash/core/ 2>/dev/null
  [ -f /etc/openclash/core/clash ] && mv /etc/openclash/core/clash /etc/openclash/core/clash_meta
  chmod +x /etc/openclash/core/clash_meta 2>/dev/null
  ln -sf /etc/openclash/core/clash_meta /etc/openclash/clash 2>/dev/null
  ok "内核已安装"
fi

# ============================================================
# 7. 拉取订阅
# ============================================================
info "拉取订阅..."
mkdir -p /etc/openclash/config
curl -fsSL -o /etc/openclash/config/config.yaml \
  -H "User-Agent: clash-verge/v2.4.5" \
  "$SUB_URL" 2>/dev/null || { fail "拉取订阅失败，请检查链接是否正确"; exit 1; }
cp /etc/openclash/config/config.yaml /etc/openclash/config.yaml 2>/dev/null
SZ=$(wc -c < /etc/openclash/config/config.yaml 2>/dev/null)
[ "$SZ" -gt 1000 ] || { fail "订阅内容异常（${SZ}字节），请检查订阅链接"; exit 1; }
ok "订阅已拉取 ($SZ 字节)"

# ============================================================
# 8. 配置
# ============================================================
info "配置 OpenClash..."
uci set openclash.config.enable="1"
uci set openclash.config.config_path="/etc/openclash/config/config.yaml"
uci set openclash.config.proxy_mode="rule"
uci set openclash.config.operation_mode="fake-ip"
uci commit openclash
ok "配置完成"

# ============================================================
# 9. 启动
# ============================================================
info "启动 OpenClash..."
for pid in $(pidof clash_meta 2>/dev/null); do kill $pid 2>/dev/null; done
sleep 2
/etc/init.d/openclash enable >/dev/null 2>&1
/etc/init.d/openclash start >/dev/null 2>&1
sleep 12

if /etc/init.d/openclash status 2>&1 | grep -q running; then
  ok "OpenClash 运行中"
else
  info "尝试手动启动..."
  nohup /etc/openclash/clash -d /etc/openclash -f /etc/openclash/config.yaml >/dev/null 2>&1 &
  sleep 5
  netstat -tln 2>/dev/null | grep -q 7890 && ok "手动启动成功" || { fail "启动失败"; exit 1; }
fi

# ============================================================
# 10. 自动测速切换
# ============================================================
SECRET=$(sed -n "s/.*secret: *//p" /etc/openclash/config.yaml 2>/dev/null | head -1 | tr -dc "a-zA-Z0-9")

if [ "$AUTO_SWITCH" = "0" ]; then
  info "跳过自动测速"
elif [ -z "$SECRET" ]; then
  warn "未获取到 secret，跳过自动测速"
elif ! command -v jq >/dev/null 2>&1; then
  warn "缺少 jq，跳过自动测速"
else
  info "自动测速选择最快节点..."
  # 用 jq 按类型过滤，只保留真实代理节点
  curl -s -H "Authorization: Bearer $SECRET" "http://127.0.0.1:9090/proxies" 2>/dev/null | \
    jq -r '.proxies | to_entries[] | select(.value.type == "Vless" or .value.type == "Vmess" or .value.type == "Trojan" or .value.type == "Shadowsocks" or .value.type == "ShadowsocksR" or .value.type == "Hysteria" or .value.type == "Hysteria2" or .value.type == "TUIC" or .value.type == "WireGuard" or .value.type == "Socks" or .value.type == "Http" or .value.type == "Snell") | .key' > /tmp/oc_nodes.txt
  TOTAL=$(wc -l < /tmp/oc_nodes.txt)
  info "检测到 $TOTAL 个节点，测速中..."

  BEST_DELAY=999999
  BEST_NODE=""
  COUNT=0
  while IFS= read -r node; do
    COUNT=$((COUNT+1))
    ENC=$(echo "$node" | jq -rn --arg s "$node" '$s|@uri' 2>/dev/null)
    D=$(curl -s -m 4 -H "Authorization: Bearer $SECRET" "http://127.0.0.1:9090/proxies/$ENC/delay?timeout=3000&url=https%3A%2F%2Fwww.google.com" 2>/dev/null | grep -oE "\"delay\":[0-9]+" | cut -d: -f2)
    if [ -n "$D" ]; then
      printf "    [%3d/%d] %s: %sms\n" "$COUNT" "$TOTAL" "$node" "$D"
      if [ "$D" -lt "$BEST_DELAY" ]; then
        BEST_DELAY=$D
        BEST_NODE="$node"
      fi
    fi
  done < /tmp/oc_nodes.txt
  rm -f /tmp/oc_nodes.txt

  if [ -n "$BEST_NODE" ]; then
    ok "最快节点: $BEST_NODE ($BEST_DELAY ms)"
    # 找到包含最快节点的策略组并切换
    GROUP=$(curl -s -H "Authorization: Bearer $SECRET" "http://127.0.0.1:9090/proxies" 2>/dev/null | jq -r '.proxies | to_entries[] | select(.value.type=="Selector" and (.value.all | index($BEST_NODE))) | .key' 2>/dev/null | head -1)
    if [ -n "$GROUP" ]; then
      GENC=$(echo "$GROUP" | jq -rn --arg s "$GROUP" '$s|@uri')
      curl -s -X PUT -H "Authorization: Bearer $SECRET" -H "Content-Type: application/json" -d "{\"name\":\"$BEST_NODE\"}" "http://127.0.0.1:9090/proxies/$GENC" >/dev/null 2>&1
      ok "已切换策略组 [$GROUP] 到 $BEST_NODE"
    else
      warn "未找到包含该节点的策略组，请手动切换"
    fi
  else
    warn "未找到可用节点"
  fi
fi

# ============================================================
# 11. 最终报告
# ============================================================
echo ""
echo "=============================================="
echo "  OpenClash 配置完成"
echo "=============================================="
SECRET_FINAL=$(sed -n "s/.*secret: *//p" /etc/openclash/config.yaml 2>/dev/null | head -1 | tr -dc "a-zA-Z0-9")
LAN_IP=$(ip -4 addr show br-lan 2>/dev/null | grep -oE "inet [0-9.]+" | head -1 | cut -d" " -f2)
[ -z "$LAN_IP" ] && LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null)
echo "  状态: $(/etc/init.d/openclash status 2>&1)"
echo "  节点数: $(grep -cE "name:" /etc/openclash/config/config.yaml 2>/dev/null)"
echo "  代理端口: 7890 (HTTP) / 7893 (混合)"
echo "  控制台: http://${LAN_IP}:9090 (secret: $SECRET_FINAL)"
echo "  LuCI: /admin/services/openclash"
echo "=============================================="
