#!/bin/sh
# ============================================================
#  OpenClash 一键安装配置脚本
#  适用: MYOS/ImmortalWrt (aarch64)
#  功能: 安装 OpenClash + 内核 + 订阅 + 启动 + 切换最优节点
#  用法: sh openclash_setup.sh
# ============================================================

# ---------- 颜色 ----------
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; CYAN="\033[0;36m"; NC="\033[0m"
ok()   { printf "%b  [OK] %b%s%b\n" "$GREEN" "$NC" "$1" "$NC"; }
fail() { printf "%b  [FAIL] %b%s%b\n" "$RED" "$NC" "$1" "$NC"; }
info() { printf "%b  [..] %b%s%b\n" "$CYAN" "$NC" "$1" "$NC"; }
warn() { printf "%b  [!] %b%s%b\n" "$YELLOW" "$NC" "$1" "$NC"; }

# ---------- 配置（可修改）----------
OC_VERSION="0.47.156"
DEFAULT_SUB="https://a.bbydy.org/api/bby/client/subscribe?token=aae6a0a85203674b697f43c7987160a4"
SUB_URL=""

echo "=============================================="
echo "  OpenClash 一键配置脚本"
echo "=============================================="
echo ""

# ---------- 订阅链接处理（支持三种方式）----------
# 方式1: 命令行参数 sh openclash_setup.sh "订阅链接"
# 方式2: 运行时交互输入
# 方式3: 使用默认订阅
if [ -n "$1" ]; then
  SUB_URL="$1"
  info "使用命令行参数提供的订阅"
elif [ -n "$OPENCLASH_SUB" ]; then
  SUB_URL="$OPENCLASH_SUB"
  info "使用环境变量 OPENCLASH_SUB 提供的订阅"
else
  echo ""
  echo "  请粘贴你的订阅链接（直接回车使用默认订阅）:"
  printf "%b" "$CYAN"
  printf "  订阅链接: "
  printf "%b" "$NC"
  read USER_SUB
  if [ -n "$USER_SUB" ]; then
    SUB_URL="$USER_SUB"
    info "使用你输入的订阅链接"
  else
    SUB_URL="$DEFAULT_SUB"
    info "使用默认订阅链接"
  fi
fi

# 验证订阅链接格式
case "$SUB_URL" in
  http://*|https://*) ok "订阅链接格式正常" ;;
  *) fail "订阅链接格式错误，需以 http:// 或 https:// 开头"; exit 1 ;;
esac

# 询问是否自动切换最优节点
echo ""
printf "%b  是否测速并自动切换最快节点？[Y/n] %b" "$YELLOW" "$NC"
read AUTO_SWITCH
case "$AUTO_SWITCH" in
  n|N|no|NO) AUTO_SWITCH="0" ;;
  *) AUTO_SWITCH="1" ;;
esac
echo ""

# ============================================================
# 1. 检查环境
# ============================================================
info "检查环境..."
[ "$(id -u)" = "0" ] || { fail "需要 root 权限"; exit 1; }
command -v curl >/dev/null 2>&1 || { fail "需要 curl"; exit 1; }
command -v opkg >/dev/null 2>&1 || { fail "需要 opkg"; exit 1; }
command -v jq >/dev/null 2>&1 || { info "安装 jq"; opkg install jq >/dev/null 2>&1; }
ok "环境正常"

# ============================================================
# 2. 检查是否已安装
# ============================================================
if [ -f /etc/init.d/openclash ] && [ -f /etc/openclash/core/clash_meta ]; then
  ok "OpenClash 已安装，跳过安装步骤"
  SKIP_INSTALL=1
else
  SKIP_INSTALL=0
fi

if [ "$SKIP_INSTALL" = "0" ]; then
  # ============================================================
  # 3. 安装依赖
  # ============================================================
  info "安装依赖 (ruby/unzip/ip-full)..."
  opkg update >/dev/null 2>&1
  for dep in unzip ip-full ruby ruby-yaml; do
    opkg list-installed 2>/dev/null | grep -q "^$dep " || opkg install $dep >/dev/null 2>&1
  done
  ok "依赖就绪"

  # ============================================================
  # 4. 下载并安装 OpenClash
  # ============================================================
  info "下载 OpenClash v$OC_VERSION..."
  mkdir -p /tmp/oc-install && cd /tmp/oc-install
  curl -fsSL -o luci-app-openclash.ipk "https://github.com/vernesong/OpenClash/releases/download/v${OC_VERSION}/luci-app-openclash_${OC_VERSION}_all.ipk" 2>/dev/null || \
  curl -fsSL -o luci-app-openclash.ipk "https://cdn.jsdelivr.net/gh/vernesong/OpenClash@package/master/luci-app-openclash_${OC_VERSION}_all.ipk" 2>/dev/null || \
  { fail "下载 OpenClash 失败"; exit 1; }
  info "安装 OpenClash..."
  opkg install --force-depends luci-app-openclash.ipk >/dev/null 2>&1 || { fail "安装失败"; exit 1; }
  ok "OpenClash 已安装"

  # ============================================================
  # 5. 下载并安装内核
  # ============================================================
  info "下载 clash_meta 内核..."
  mkdir -p /etc/openclash/core
  curl -fsSL -o /tmp/clash_meta.tar.gz "https://cdn.jsdelivr.net/gh/vernesong/OpenClash@core/dev/meta/clash-linux-arm64.tar.gz" 2>/dev/null || \
  { fail "下载内核失败"; exit 1; }
  tar xzf /tmp/clash_meta.tar.gz -C /etc/openclash/core/ 2>/dev/null
  # 重命名（解压出来可能是 clash）
  [ -f /etc/openclash/core/clash ] && mv /etc/openclash/core/clash /etc/openclash/core/clash_meta
  chmod +x /etc/openclash/core/clash_meta 2>/dev/null
  # 符号链接（init 脚本期望 /etc/openclash/clash）
  ln -sf /etc/openclash/core/clash_meta /etc/openclash/clash 2>/dev/null
  ok "内核已安装"
fi

# ============================================================
# 6. 拉取订阅（关键：需要正确 User-Agent）
# ============================================================
info "拉取订阅..."
mkdir -p /etc/openclash/config
curl -fsSL -o /etc/openclash/config/config.yaml \
  -H "User-Agent: clash-verge/v2.4.5" \
  "$SUB_URL" 2>/dev/null || { fail "拉取订阅失败"; exit 1; }
# 同时复制到根位置（兼容）
cp /etc/openclash/config/config.yaml /etc/openclash/config.yaml 2>/dev/null
CONFIG_SIZE=$(wc -c < /etc/openclash/config/config.yaml)
[ "$CONFIG_SIZE" -gt 1000 ] || { fail "订阅内容异常（${CONFIG_SIZE}字节）"; exit 1; }
ok "订阅已拉取 (${CONFIG_SIZE} 字节)"

# ============================================================
# 7. 配置 uci
# ============================================================
info "配置 OpenClash..."
uci set openclash.config.enable="1"
uci set openclash.config.config_path="/etc/openclash/config/config.yaml"
uci set openclash.config.proxy_mode="rule"
uci set openclash.config.operation_mode="fake-ip"
uci commit openclash
ok "配置完成"

# ============================================================
# 8. 启动
# ============================================================
info "启动 OpenClash..."
# 清理可能残留的 clash 进程
for pid in $(pidof clash_meta); do kill $pid 2>/dev/null; done
sleep 2
/etc/init.d/openclash enable >/dev/null 2>&1
/etc/init.d/openclash start >/dev/null 2>&1
sleep 12

# ============================================================
# 9. 验证
# ============================================================
info "验证服务..."
if /etc/init.d/openclash status 2>&1 | grep -q running; then
  ok "OpenClash 运行中"
else
  # 如果 init 没起来，尝试手动启动
  info "init 启动失败，尝试手动启动..."
  nohup /etc/openclash/clash -d /etc/openclash -f /etc/openclash/config.yaml >/dev/null 2>&1 &
  sleep 5
  if netstat -tln 2>/dev/null | grep -q 7890; then
    ok "手动启动成功（端口 7890 监听）"
  else
    fail "启动失败，检查日志: cat /tmp/openclash.log"; exit 1;
  fi
fi

# ============================================================
# 10. 切换最优节点（自动测速）
# ============================================================
SECRET=$(sed -n 's/.*secret: *//p' /etc/openclash/config.yaml 2>/dev/null | head -1 | tr -dc 'a-zA-Z0-9')

if [ "$AUTO_SWITCH" = "0" ]; then
  info "已跳过自动切换节点"
elif [ -z "$SECRET" ]; then
  warn "未获取到 secret，跳过节点切换"
elif ! command -v jq >/dev/null 2>&1; then
  warn "缺少 jq，跳过自动测速"
else
  info "测速选择最快节点（Google 延迟）..."
  curl -s -H "Authorization: Bearer $SECRET" "http://127.0.0.1:9090/proxies" 2>/dev/null | \
    grep -oE '"name":"[^"]*"' | sed 's/"name":"//;s/"//' | \
    grep -vE "剩余流量|套餐到期|无法使用|自动选择|延迟最低|宝贝云|距离|邀请|TG群|直连地址|只有" > /tmp/oc_nodes.txt

  TOTAL=$(wc -l < /tmp/oc_nodes.txt)
  info "检测到 $TOTAL 个节点，测速中..."

  BEST_DELAY=999999
  BEST_NODE=""
  COUNT=0
  while IFS= read -r node; do
    COUNT=$((COUNT+1))
    ENC=$(echo "$node" | jq -rn --arg s "$node" '$s|@uri' 2>/dev/null)
    D=$(curl -s -m 4 -H "Authorization: Bearer $SECRET" "http://127.0.0.1:9090/proxies/$ENC/delay?timeout=3000&url=https%3A%2F%2Fwww.google.com" 2>/dev/null | grep -oE '"delay":[0-9]+' | cut -d: -f2)
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
    curl -s -X PUT -H "Authorization: Bearer $SECRET" -H "Content-Type: application/json" \
      -d "{\"name\":\"$BEST_NODE\"}" \
      "http://127.0.0.1:9090/proxies/%E5%AE%9D%E8%B4%9D%E4%BA%91" >/dev/null 2>&1
    ok "已切换到 $BEST_NODE"
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
SECRET_FINAL=$(sed -n 's/.*secret: *//p' /etc/openclash/config.yaml 2>/dev/null | head -1 | tr -dc 'a-zA-Z0-9')
echo "  状态: $(/etc/init.d/openclash status 2>&1)"
echo "  节点数: $(grep -cE "name:" /etc/openclash/config/config.yaml 2>/dev/null)"
echo "  代理端口: 7890 (HTTP) / 7893 (混合)"
echo "  控制台: http://192.168.66.1:9090 (secret: $SECRET_FINAL)"
echo "  LuCI: /admin/services/openclash"
echo "=============================================="
