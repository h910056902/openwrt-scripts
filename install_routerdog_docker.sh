#!/bin/sh
# ============================================================
#  路由器 Docker + NAS 一键配置工具
#  适用: MYOS/ImmortalWrt (aarch64)
# ============================================================

# ---------- 颜色 ----------
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; BLUE="\033[1;34m"; CYAN="\033[0;36m"; WHITE="\033[1;37m"; NC="\033[0m"
BOLD="\033[1m"; DIM="\033[2m"

ok()   { printf "%b  ✓ %b%s%b\n" "$GREEN" "$NC" "$1" "$NC"; }
fail() { printf "%b  ✗ %b%s%b\n" "$RED" "$NC" "$1" "$NC"; }
skip() { printf "%b  - %b%s%b\n" "$YELLOW" "$NC" "$1" "$NC"; }
info() { printf "%b  i %b%s%b\n" "$BLUE" "$NC" "$1" "$NC"; }
warn() { printf "%b  ! %b%s%b\n" "$YELLOW" "$NC" "$1" "$NC"; }

sep()    { printf "%b──────────────────────────────%b\n" "$DIM" "$NC"; }
section(){ printf "\n%b▶ %b%b%s%b\n" "$CYAN" "$BOLD" "$WHITE" "$1" "$NC"; sep; }
cmd_exists() { command -v "$1" >/dev/null 2>&1; }
docker_installed() { [ -x /usr/bin/docker ] && docker --version >/dev/null 2>&1; }
routergo_installed() { [ -x /usr/sbin/routergo ] && [ -f /usr/lib/lua/luci/controller/routerdog.lua ]; }
dockerman_installed() { [ -f /usr/lib/lua/luci/controller/dockerman.lua ]; }
# ============================================================
#  OpenClash AI 节点优化函数
# ============================================================
ai_node_optimize() {
  AUTH="Authorization: Bearer 5rcYEBgQ"
  BASE="http://127.0.0.1:9090"
  GROUP="宝贝云"
  AI_URLS="https://chatgpt.com https://claude.ai https://gemini.google.com"

  echo ""
  echo "=== 订阅链接配置 ==="
  CUR_SUB=$(uci get openclash.@subscribe[0].address 2>/dev/null)
  if [ -n "$CUR_SUB" ] && [ "$CUR_SUB" != "uci: Invalid" ]; then
    echo "  当前订阅: ${CUR_SUB:0:50}..."
    printf "%b  是否更换新订阅链接？[y/N] %b" "$YELLOW" "$NC"
    read CHG_SUB
    case "$CHG_SUB" in
      y|Y)
        printf "  请输入新订阅链接: "
        read NEW_SUB
        if [ -n "$NEW_SUB" ]; then
          uci set openclash.@subscribe[0].address="$NEW_SUB"
          uci set openclash.@config_subscribe[0].address="$NEW_SUB"
          uci commit openclash
          echo "  ✅ 已更换订阅链接（请在 OpenClash 界面点击更新订阅）"
        fi
        ;;
      *)
        echo "  保留当前订阅";;
    esac
  else
    printf "  未检测到订阅，是否输入新订阅链接？[y/N]: "
    read CHG_SUB2
    case "$CHG_SUB2" in
      y|Y)
        printf "  请输入订阅链接: "
        read NEW_SUB2
        if [ -n "$NEW_SUB2" ]; then
          uci set openclash.@subscribe[0].address="$NEW_SUB2"
          uci commit openclash
          echo "  ✅ 已设置订阅链接"
        fi
        ;;
      *)
        echo "  跳过订阅配置";;
    esac
  fi

  echo ""
  echo "=== 测速并切换最快 AI 节点 ==="
  if ! command -v jq >/dev/null 2>&1; then
    echo "  需要 jq 支持，跳过测速"
    return 1
  fi
  CUR_NODE=$(curl -s -H "$AUTH" $BASE/proxies 2>/dev/null | jq -r ".proxies[\"$GROUP\"].now" 2>/dev/null)
  [ -n "$CUR_NODE" ] && echo "  当前节点: $CUR_NODE"
  echo "  测速目标: ChatGPT + Claude + Gemini"
  echo ""

  curl -s -H "$AUTH" $BASE/proxies | jq -r '.proxies | to_entries[] | select(.value.type == "Vless" or .value.type == "Vmess" or .value.type == "Trojan" or .value.type == "Shadowsocks" or .value.type == "Hysteria" or .value.type == "Hysteria2" or .value.type == "TUIC") | .key' > /tmp/ai_nodes_raw.txt 2>/dev/null
  grep -vE "剩余流量|距离下次重置|套餐到期|无法使用|直连地址|邀请好友|TG群|只有新加坡|更换客户端" /tmp/ai_nodes_raw.txt > /tmp/ai_nodes.txt 2>/dev/null
  TOTAL=$(wc -l < /tmp/ai_nodes.txt 2>/dev/null)
  echo "  检测到 $TOTAL 个真实节点，开始测速（约 2-3 分钟）..."
  echo ""

  BEST_SUM=999999
  BEST_NODE=""
  COUNT=0
  while IFS= read -r node; do
    [ -z "$node" ] && continue
    COUNT=$((COUNT+1))
    ENC=$(echo "$node" | jq -rn --arg s "$node" '$s | @uri')
    SUM=0; FAIL=0; OK=0
    for url in $AI_URLS; do
      UENC=$(echo "$url" | jq -rn --arg s "$url" '$s | @uri')
      R=$(curl -s -m 5 -H "$AUTH" "$BASE/proxies/$ENC/delay?timeout=4000&url=$UENC" 2>/dev/null)
      D=$(echo "$R" | jq -r '.delay // "FAIL"' 2>/dev/null)
      if [ "$D" = "FAIL" ] || [ -z "$D" ]; then
        FAIL=$((FAIL+1))
      else
        SUM=$((SUM+D)); OK=$((OK+1))
      fi
    done
    if [ "$OK" -gt 0 ]; then
      AVG=$((SUM/OK))
      printf "    [%-3d/%-3d] %-32s %4d ms\n" "$COUNT" "$TOTAL" "$node" "$AVG"
      if [ "$AVG" -lt "$BEST_SUM" ]; then
        BEST_SUM=$AVG; BEST_NODE="$node"
      fi
    fi
  done < /tmp/ai_nodes.txt

  echo ""
  if [ -n "$BEST_NODE" ]; then
    echo "  🏆 AI 最快节点: $BEST_NODE (平均 ${BEST_SUM}ms)"
    echo "  自动切换 $GROUP -> $BEST_NODE ..."
    GENC=$(echo "$GROUP" | jq -rn --arg s "$GROUP" '$s | @uri')
    curl -s -X PUT -H "$AUTH" -H "Content-Type: application/json" --data-binary "{\"name\":\"$BEST_NODE\"}" "$BASE/proxies/$GENC" >/dev/null 2>&1
    sleep 2
    NEW_NODE=$(curl -s -H "$AUTH" $BASE/proxies | jq -r ".proxies[\"$GROUP\"].now")
    [ -n "$NEW_NODE" ] && echo "  ✅ 已切换: $NEW_NODE" || echo "  ⚠️ 切换需确认"
  else
    echo "  ❌ 未找到可用节点，请检查 OpenClash 是否运行"
  fi
  rm -f /tmp/ai_nodes.txt /tmp/ai_nodes_raw.txt
}

SDCARD="/mnt/sdcard"; DOCKER_ROOT="$SDCARD/docker"; PKG_DIR="$SDCARD/pkgs"

# =================== 启动横幅 ===================
clear 2>/dev/null
printf "%b" "$CYAN"
echo "╔══════════════════════════════════════════╗"
echo "║  路由器 Docker + 路由狗 一键配置工具     ║"
echo "║       OpenWrt / ImmortalWrt              ║"
echo "╚══════════════════════════════════════════╝"
printf "%b" "$NC"
echo ""
info "系统: $(awk -F= "/DISTRIB_DESCRIPTION/{print $2}" /etc/openwrt_release 2>/dev/null | tr -d \"\")"
info "架构: $(uname -m)"
info "内存: $(free -m | awk "/Mem:/{print $7}") MB 可用"
mount | grep -q "on $SDCARD type" && info "存储: $SDCARD 可用 ($(df -h $SDCARD | awk "NR==2{print $4}"))" || warn "存储: 未挂载"
[ -n "$(docker --version 2>/dev/null)" ] && info "Docker: 已安装" || info "Docker: 未安装"
echo ""
printf "%b  开始执行配置？[Y/n] %b" "$YELLOW" "$NC"
read GOV
case "$GOV" in
 n|N) echo "已取消。"; exit 0;;
 *) echo "";;
esac

section "1/7 SD 卡空间"
if mount | grep -q "on $SDCARD type"; then
  ok "SD 卡已挂载, $(df -h $SDCARD | awk "NR==2{print $4}") 可用"
else
  if [ ! -b /dev/mmcblk0p7 ]; then
    info "创建 p7 分区..."
    P6_END=$(fdisk -l /dev/mmcblk0 2>/dev/null | awk "/mmcblk0p6/{print $3}")
    [ -n "$P6_END" ] || { fail "分区表读取失败"; exit 1; }
    printf "n\n7\n%s\n\nw\n" "$((P6_END+1))" | fdisk /dev/mmcblk0 >/dev/null 2>&1
    sleep 3; [ -b /dev/mmcblk0p7 ] || { fail "分区创建失败"; exit 1; }
    mkfs.f2fs -f -l sdcard /dev/mmcblk0p7 >/dev/null 2>&1 && ok "已格式化 f2fs"
  fi
  mkdir -p $SDCARD
  mount -t f2fs /dev/mmcblk0p7 $SDCARD 2>/dev/null || { fail "挂载失败"; exit 1; }
  cat >> /etc/config/fstab <<EOF2

config mount
	option target '$SDCARD'
	option device '/dev/mmcblk0p7'
	option fstype 'f2fs'
	option enabled '1'
EOF2
  /etc/init.d/fstab enable >/dev/null 2>&1
  ok "已挂载并配置自启"
fi
mkdir -p $DOCKER_ROOT

section "2/7 Docker 安装"
if docker_installed; then
  ok "Docker 已存在"
else
  for k in kmod-ipt-nat kmod-ipt-nat6 kmod-nf-ipvs kmod-veth; do
    opkg list-installed | grep -q "^$k " && skip "$k" || { opkg install $k >/dev/null 2>&1 && ok "$k" || skip "$k skipped"; }
  done
  info "安装 Docker 组件..."
  opkg -d sdcard install docker dockerd containerd runc tini libseccomp ca-certificates iptables-mod-extra 2>&1 | grep -qE "Configuring" && ok "组件已装" || warn "需确认"
  for b in docker dockerd containerd containerd-shim containerd-shim-runc-v1 containerd-shim-runc-v2 docker-init docker-proxy tini; do
    [ -f $SDCARD/usr/bin/$b ] && ln -sf $SDCARD/usr/bin/$b /usr/bin/$b 2>/dev/null
    [ -f $SDCARD/usr/sbin/$b ] && ln -sf $SDCARD/usr/sbin/$b /usr/sbin/$b 2>/dev/null
  done
  [ -f $SDCARD/usr/sbin/runc ] && ln -sf $SDCARD/usr/sbin/runc /usr/bin/runc 2>/dev/null
  [ -f $SDCARD/etc/init.d/dockerd ] && ln -sf $SDCARD/etc/init.d/dockerd /etc/init.d/dockerd
  [ -f $SDCARD/etc/config/dockerd ] && { rm -f /etc/config/dockerd; cp $SDCARD/etc/config/dockerd /etc/config/dockerd; }
  ok "Docker 已安装"
fi

section "3/7 Docker 配置"
uci set dockerd.globals.data_root="$DOCKER_ROOT"; uci set dockerd.globals.iptables="0"; uci commit dockerd
ok "数据目录 → $DOCKER_ROOT"
if [ -n "$(uci get openclash.@authentication[0].username 2>/dev/null)" ]; then
  OC_U=$(uci get openclash.@authentication[0].username); OC_P=$(uci get openclash.@authentication[0].password)
  uci set dockerd.proxies="proxies"
  uci set dockerd.proxies.http_proxy="http://$OC_U:$OC_P@127.0.0.1:7890"
  uci set dockerd.proxies.https_proxy="http://$OC_U:$OC_P@127.0.0.1:7890"
  uci set dockerd.proxies.no_proxy="localhost,127.0.0.1"; uci commit dockerd
  ok "代理已配置 ($OC_U)"
else
  skip "未检测到 OpenClash 代理"
fi
/etc/init.d/dockerd enable >/dev/null 2>&1; /etc/init.d/dockerd start 2>/dev/null || true; sleep 8
if [ ! -S /var/run/docker.sock ]; then
  for p in $(pidof dockerd) $(pidof containerd); do kill -9 $p 2>/dev/null; done; sleep 2
  rm -f /var/run/docker.pid /var/run/docker.sock; rm -rf /var/run/docker /var/run/containerd
  /etc/init.d/dockerd start 2>/dev/null || true; sleep 10
fi
VER=$(docker info --format "{{.ServerVersion}}" 2>/dev/null)
[ -n "$VER" ] && ok "Docker 运行中 v$VER" || fail "Docker 启动失败: logread | grep dockerd"

section "4/7 iStore 源"
if grep -q "is_meta" /etc/opkg/customfeeds.conf 2>/dev/null; then
  ok "iStore 源已存在"
else
  cat >> /etc/opkg/customfeeds.conf <<'EOF3'
src/gz is_meta https://istore.istoreos.com/repo/all/meta
src/gz is_store https://istore.istoreos.com/repo/all/store
src/gz is_nas_luci https://istore.istoreos.com/repo/all/nas_luci
src/gz is_nas https://istore.istoreos.com/repo/aarch64_cortex-a53/nas
EOF3
  opkg update >/dev/null 2>&1 && ok "iStore 源已添加" || warn "源更新失败"
fi

section "5/7 路由狗"
if routergo_installed; then
  ok "路由狗已存在"
else
  mkdir -p $PKG_DIR; cd $PKG_DIR
  curl -fsSL -o routergo.ipk "https://istore.istoreos.com/repo/aarch64_cortex-a53/nas/routergo_0.14.10_aarch64_cortex-a53.ipk"
  curl -fsSL -o luci-app-routerdog.ipk "https://istore.istoreos.com/repo/all/nas_luci/luci-app-routerdog_1.4.10_all.ipk"
  rm -rf /tmp/rg && mkdir -p /tmp/rg && tar xzf routergo.ipk -C /tmp/rg
  tar xzf /tmp/rg/data.tar.gz -C $SDCARD 2>/dev/null
  [ -f $SDCARD/usr/sbin/routergo ] && ln -sf $SDCARD/usr/sbin/routergo /usr/sbin/routergo
  ln -sf $SDCARD/usr/sbin/routergo /usr/bin/routergo 2>/dev/null
  [ -f $SDCARD/etc/config/routergo ] && ln -sf $SDCARD/etc/config/routergo /etc/config/routergo
  [ -f $SDCARD/etc/init.d/routergo ] && ln -sf $SDCARD/etc/init.d/routergo /etc/init.d/routergo
  rm -rf /tmp/la && mkdir -p /tmp/la && tar xzf luci-app-routerdog.ipk -C /tmp/la
  rm -rf $SDCARD/routerdog-app && mkdir -p $SDCARD/routerdog-app
  tar xzf /tmp/la/data.tar.gz -C $SDCARD/routerdog-app 2>/dev/null
  [ -f $SDCARD/routerdog-app/usr/lib/lua/luci/controller/routerdog.lua ] && ln -sf $SDCARD/routerdog-app/usr/lib/lua/luci/controller/routerdog.lua /usr/lib/lua/luci/controller/routerdog.lua
  [ -f $SDCARD/routerdog-app/usr/lib/lua/luci/controller/routergo_backend.lua ] && ln -sf $SDCARD/routerdog-app/usr/lib/lua/luci/controller/routergo_backend.lua /usr/lib/lua/luci/controller/routergo_backend.lua
  [ -d $SDCARD/routerdog-app/usr/lib/lua/luci/view/routerdog ] && ln -sf $SDCARD/routerdog-app/usr/lib/lua/luci/view/routerdog /usr/lib/lua/luci/view/routerdog
  [ -f $SDCARD/routerdog-app/usr/share/luci/menu.d/luci-app-routerdog.json ] && ln -sf $SDCARD/routerdog-app/usr/share/luci/menu.d/luci-app-routerdog.json /usr/share/luci/menu.d/luci-app-routerdog.json
  [ -d $SDCARD/routerdog-app/www/luci-static/routerdog ] && ln -sf $SDCARD/routerdog-app/www/luci-static/routerdog /www/luci-static/routerdog
  ok "路由狗已安装"
fi
/etc/init.d/routergo enable >/dev/null 2>&1; /etc/init.d/routergo start 2>/dev/null || true; sleep 3
/etc/init.d/routergo status 2>/dev/null | grep -q running && ok "routergo 运行中" || warn "routergo 需确认"

section "6/7 Docker 管理器"
if dockerman_installed; then
  ok "Docker 管理器已存在"
else
  opkg -d sdcard install luci-app-dockerman luci-i18n-dockerman-zh-cn luci-lib-docker docker-compose 2>&1 | grep -qE "Configuring" && ok "组件已装" || warn "需确认"
  ln -sf $SDCARD/usr/lib/lua/luci/controller/dockerman.lua /usr/lib/lua/luci/controller/dockerman.lua 2>/dev/null
  ln -sf $SDCARD/usr/lib/lua/luci/model/cbi/dockerman /usr/lib/lua/luci/model/cbi/dockerman 2>/dev/null
  ln -sf $SDCARD/usr/lib/lua/luci/model/docker.lua /usr/lib/lua/luci/model/docker.lua 2>/dev/null
  ln -sf $SDCARD/usr/lib/lua/luci/docker.lua /usr/lib/lua/luci/docker.lua 2>/dev/null
  ln -sf $SDCARD/usr/lib/lua/luci/view/dockerman /usr/lib/lua/luci/view/dockerman 2>/dev/null
  ln -sf $SDCARD/www/luci-static/resources/dockerman /www/luci-static/resources/dockerman 2>/dev/null
  ln -sf $SDCARD/usr/share/rpcd/acl.d/luci-app-dockerman.json /usr/share/rpcd/acl.d/luci-app-dockerman.json 2>/dev/null
  ln -sf $SDCARD/usr/lib/lua/luci/i18n/dockerman.zh-cn.lmo /usr/lib/lua/luci/i18n/dockerman.zh-cn.lmo 2>/dev/null
  mkdir -p /usr/lib/docker/cli-plugins
  [ -f $SDCARD/usr/lib/docker/cli-plugins/docker-compose ] && ln -sf $SDCARD/usr/lib/docker/cli-plugins/docker-compose /usr/lib/docker/cli-plugins/docker-compose
  ok "Docker 管理器已安装"
fi

section "7/7 完成收尾"
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null
/etc/init.d/uhttpd restart >/dev/null 2>&1; sleep 3

printf "%b╔══════════════════════════════════════════╗%b\n" "$CYAN" "$NC"
echo "║      ✅ 配置完成 · 健康检查报告          ║"
printf "%b╚══════════════════════════════════════════╝%b\n" "$CYAN" "$NC"
echo ""
[ -n "$(docker info --format "{{.ServerVersion}}" 2>/dev/null)" ] && ok "Docker 引擎   运行中" || fail "Docker 引擎   异常"
routergo_installed && ok "路由狗        已安装" || fail "路由狗        未安装"
/etc/init.d/routergo status 2>/dev/null | grep -q running && ok "routergo 服务 运行中" || warn "routergo 服务 未运行"
dockerman_installed && ok "Docker 管理器 已安装" || fail "Docker 管理器 未安装"
NET2="$(curl -s -o /dev/null -w "%{http_code}" -m 8 -x http://Clash:H1p9uybR@127.0.0.1:7890 https://www.google.com/generate_204 2>/dev/null)"
[ "$NET2" = "204" ] && ok "网络         Google 可达" || warn "网络         Google 不可达"
mount | grep -q "on $SDCARD type" && ok "存储         SD 卡正常" || warn "存储         未挂载"

echo ""
echo "  → 路由狗界面: http://192.168.66.1  (登录后)"
echo "  → Docker管理: LuCI 菜单 → Docker"
echo "  → 数据目录:   $DOCKER_ROOT"
echo ""
echo "  部署应用: docker run -d --name 名称 镜像"
echo ""echo ""
echo "=============================================="
echo "  OpenClash AI 节点优化器（可选）"
echo "  功能: 测速节点对 AI 网站延迟，自动切换最快节点"
echo "=============================================="
echo ""
printf "%b  是否运行节点优化器？[y/N] %b" "$YELLOW" "$NC"
read RUN_AI
case "$RUN_AI" in
  y|Y|yes|YES)
    echo "▶ 运行 OpenClash AI 节点优化器..."
    ai_node_optimize
    ;;
  *)
    echo "跳过节点优化。"
    ;;
esac
echo ""