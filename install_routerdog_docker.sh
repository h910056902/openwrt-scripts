#!/bin/sh
# ============================================================
#  路由器 Docker + NAS 工具箱
#  适用: MYOS/ImmortalWrt (aarch64)
#  用法: sh -c "$(curl -fsSL URL)"
# ============================================================

RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; BLUE="\033[1;34m"; CYAN="\033[0;36m"; WHITE="\033[1;37m"; MAGENTA="\033[0;35m"; NC="\033[0m"
BOLD="\033[1m"; DIM="\033[2m"
ok()   { printf "%b  ✓ %b%s%b\n" "$GREEN" "$NC" "$1" "$NC"; }
fail() { printf "%b  ✗ %b%s%b\n" "$RED" "$NC" "$1" "$NC"; }
skip() { printf "%b  - %b%s%b\n" "$YELLOW" "$NC" "$1" "$NC"; }
info() { printf "%b  i %b%s%b\n" "$BLUE" "$NC" "$1" "$NC"; }
warn() { printf "%b  ! %b%s%b\n" "$YELLOW" "$NC" "$1" "$NC"; }
menu() { printf "  %b[%b%s%b]%b %s\n" "$CYAN" "$BOLD" "$1" "$NC" "$CYAN" "$2"; }
sep()  { printf "%b──────────────────────────────%b\n" "$DIM" "$NC"; }
section(){ printf "\n%b▶ %b%b%s%b\n" "$CYAN" "$BOLD" "$WHITE" "$1" "$NC"; sep; }
cmd_exists() { command -v "$1" >/dev/null 2>&1; }
pause() { printf "\n%b  按回车键返回菜单...%b" "$DIM" "$NC"; read PAUSE; }

SDCARD="/mnt/sdcard"; DOCKER_ROOT="$SDCARD/docker"; PKG_DIR="$SDCARD/pkgs"
AUTH="Authorization: Bearer 5rcYEBgQ"
OC_BASE="http://127.0.0.1:9090"
AI_URLS="https://chatgpt.com https://claude.ai https://gemini.google.com"

docker_installed() { [ -x /usr/bin/docker ] && docker --version >/dev/null 2>&1; }
routergo_installed() { [ -x /usr/sbin/routergo ] && [ -f /usr/lib/lua/luci/controller/routerdog.lua ]; }
dockerman_installed() { [ -f /usr/lib/lua/luci/controller/dockerman.lua ]; }

# ========== 功能1: 全自动安装 ==========
full_install() {
  section "全自动安装: Docker + 路由狗 + Docker管理器"
  # --- 1. SD卡 ---
  section "SD 卡空间"
  if mount | grep -q "on $SDCARD type"; then
    ok "SD 卡已挂载"
  else
    info "创建分区并挂载..."
    if [ ! -b /dev/mmcblk0p7 ]; then
      P6_END=$(fdisk -l /dev/mmcblk0 2>/dev/null | awk "/mmcblk0p6/{print \$3}")
      [ -n "$P6_END" ] || { fail "分区表读取失败"; return; }
      printf "n\n7\n%s\n\nw\n" "$((P6_END+1))" | fdisk /dev/mmcblk0 >/dev/null 2>&1
      sleep 3; [ -b /dev/mmcblk0p7 ] || { fail "分区失败"; return; }
      mkfs.f2fs -f -l sdcard /dev/mmcblk0p7 >/dev/null 2>&1
    fi
    mkdir -p $SDCARD; mount -t f2fs /dev/mmcblk0p7 $SDCARD 2>/dev/null || { fail "挂载失败"; return; }
    cat >> /etc/config/fstab <<EOF2

config mount
	option target '$SDCARD'
	option device '/dev/mmcblk0p7'
	option fstype 'f2fs'
	option enabled '1'
EOF2
    /etc/init.d/fstab enable >/dev/null 2>&1
    ok "SD 卡已挂载并配置自启"
  fi
  mkdir -p $DOCKER_ROOT

  # --- 2. Docker ---
  section "Docker 安装"
  if docker_installed; then
    ok "Docker 已存在"
  else
    info "安装内核模块..."
    for k in kmod-ipt-nat kmod-ipt-nat6 kmod-nf-ipvs kmod-veth; do
      opkg list-installed | grep -q "^$k " || opkg install $k >/dev/null 2>&1
    done
    info "安装 Docker 组件..."
    opkg -d sdcard install docker dockerd containerd runc tini libseccomp ca-certificates iptables-mod-extra 2>&1 | grep -qE "Configuring" && ok "组件已装" || warn "部分需确认"
    for b in docker dockerd containerd containerd-shim containerd-shim-runc-v1 containerd-shim-runc-v2 docker-init docker-proxy tini; do
      [ -f $SDCARD/usr/bin/$b ] && ln -sf $SDCARD/usr/bin/$b /usr/bin/$b 2>/dev/null
      [ -f $SDCARD/usr/sbin/$b ] && ln -sf $SDCARD/usr/sbin/$b /usr/sbin/$b 2>/dev/null
    done
    [ -f $SDCARD/usr/sbin/runc ] && ln -sf $SDCARD/usr/sbin/runc /usr/bin/runc 2>/dev/null
    [ -f $SDCARD/etc/init.d/dockerd ] && ln -sf $SDCARD/etc/init.d/dockerd /etc/init.d/dockerd
    [ -f $SDCARD/etc/config/dockerd ] && { rm -f /etc/config/dockerd; cp $SDCARD/etc/config/dockerd /etc/config/dockerd; }
    ok "Docker 已安装"
  fi
  docker_configure

  # --- 3. iStore 源 ---
  section "iStore 源"
  if grep -q "is_meta" /etc/opkg/customfeeds.conf 2>/dev/null; then
    ok "iStore 源已存在"
  else
    cat >> /etc/opkg/customfeeds.conf <<'EOF3'
src/gz is_meta https://istore.istoreos.com/repo/all/meta
src/gz is_store https://istore.istoreos.com/repo/all/store
src/gz is_nas_luci https://istore.istoreos.com/repo/all/nas_luci
src/gz is_nas https://istore.istoreos.com/repo/aarch64_cortex-a53/nas
EOF3
    opkg update >/dev/null 2>&1
    ok "iStore 源已添加"
  fi

  # --- 4. 路由狗 ---
  section "路由狗"
  if routergo_installed; then
    ok "路由狗已存在"
  else
    mkdir -p $PKG_DIR; cd $PKG_DIR
    curl -fsSL -o routergo.ipk "https://istore.istoreos.com/repo/aarch64_cortex-a53/nas/routergo_0.14.10_aarch64_cortex-a53.ipk" 2>/dev/null
    curl -fsSL -o luci-app-routerdog.ipk "https://istore.istoreos.com/repo/all/nas_luci/luci-app-routerdog_1.4.10_all.ipk" 2>/dev/null
    rm -rf /tmp/rg && mkdir -p /tmp/rg && tar xzf routergo.ipk -C /tmp/rg
    tar xzf /tmp/rg/data.tar.gz -C $SDCARD 2>/dev/null
    [ -f $SDCARD/usr/sbin/routergo ] && ln -sf $SDCARD/usr/sbin/routergo /usr/sbin/routergo
    [ -f $SDCARD/etc/config/routergo ] && ln -sf $SDCARD/etc/config/routergo /etc/config/routergo
    [ -f $SDCARD/etc/init.d/routergo ] && ln -sf $SDCARD/etc/init.d/routergo /etc/init.d/routergo
    rm -rf /tmp/la && mkdir -p /tmp/la && tar xzf luci-app-routerdog.ipk -C /tmp/la
    rm -rf $SDCARD/routerdog-app && mkdir -p $SDCARD/routerdog-app
    tar xzf /tmp/la/data.tar.gz -C $SDCARD/routerdog-app 2>/dev/null
    [ -f $SDCARD/routerdog-app/usr/lib/lua/luci/controller/routerdog.lua ] && ln -sf $SDCARD/routerdog-app/usr/lib/lua/luci/controller/routerdog.lua /usr/lib/lua/luci/controller/routerdog.lua
    [ -f $SDCARD/routerdog-app/usr/share/luci/menu.d/luci-app-routerdog.json ] && ln -sf $SDCARD/routerdog-app/usr/share/luci/menu.d/luci-app-routerdog.json /usr/share/luci/menu.d/luci-app-routerdog.json
    [ -d $SDCARD/routerdog-app/www/luci-static/routerdog ] && ln -sf $SDCARD/routerdog-app/www/luci-static/routerdog /www/luci-static/routerdog
    ok "路由狗已安装"
  fi
  /etc/init.d/routergo enable >/dev/null 2>&1; /etc/init.d/routergo start 2>/dev/null || true; sleep 2

  # --- 5. Docker 管理器 ---
  section "Docker 管理器"
  if dockerman_installed; then
    ok "Docker 管理器已存在"
  else
    opkg -d sdcard install luci-app-dockerman luci-i18n-dockerman-zh-cn luci-lib-docker docker-compose 2>&1 | grep -qE "Configuring" && ok "组件已装" || warn "需确认"
    ln -sf $SDCARD/usr/lib/lua/luci/controller/dockerman.lua /usr/lib/lua/luci/controller/dockerman.lua 2>/dev/null
    ln -sf $SDCARD/usr/lib/lua/luci/model/cbi/dockerman /usr/lib/lua/luci/model/cbi/dockerman 2>/dev/null
    ln -sf $SDCARD/usr/lib/lua/luci/view/dockerman /usr/lib/lua/luci/view/dockerman 2>/dev/null
    ln -sf $SDCARD/www/luci-static/resources/dockerman /www/luci-static/resources/dockerman 2>/dev/null
    mkdir -p /usr/lib/docker/cli-plugins
    [ -f $SDCARD/usr/lib/docker/cli-plugins/docker-compose ] && ln -sf $SDCARD/usr/lib/docker/cli-plugins/docker-compose /usr/lib/docker/cli-plugins/docker-compose
    ok "Docker 管理器已安装"
  fi
  info "清理 LuCI 缓存..."
  rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null
  /etc/init.d/uhttpd restart >/dev/null 2>&1; sleep 2
  echo ""
  ok "✅ 全自动安装完成!"
  health_report
  pause
}

# ========== docker_configure: Docker 配置 ==========
docker_configure() {
  section "Docker 配置"
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
  [ -n "$VER" ] && ok "Docker 运行中 v$VER" || fail "Docker 启动失败"
}

# ========== 功能2: 单独安装 ==========
single_install() {
  echo ""
  echo "  ┌──────────────────────────────┐"
  echo "  │   单独安装组件              │"
  echo "  └──────────────────────────────┘"
  menu "1" "安装/配置 Docker";
  menu "2" "安装 路由狗 (RouterDog)";
  menu "3" "安装 Docker 管理器 (dockerman)";
  menu "4" "只配置 Docker 代理";
  menu "0" "返回主菜单";
  printf "%b\n 请选择: %b" "$CYAN" "$NC"; read SI_CHOICE
  case "$SI_CHOICE" in
    1)
      if docker_installed; then ok "Docker 已存在"; else
        info "安装 Docker..."; opkg -d sdcard install docker dockerd containerd runc tini libseccomp ca-certificates iptables-mod-extra 2>&1 | grep -qE "Configuring" && ok "已装" || warn "需确认"
        for b in docker dockerd containerd containerd-shim containerd-shim-runc-v1 containerd-shim-runc-v2 docker-init docker-proxy tini; do
          [ -f $SDCARD/usr/bin/$b ] && ln -sf $SDCARD/usr/bin/$b /usr/bin/$b 2>/dev/null
          [ -f $SDCARD/usr/sbin/$b ] && ln -sf $SDCARD/usr/sbin/$b /usr/sbin/$b 2>/dev/null;
        done; fi
      docker_configure;;
    2)
      if routergo_installed; then ok "路由狗已存在"; else
        mkdir -p $PKG_DIR; cd $PKG_DIR
        curl -fsSL -o routergo.ipk "https://istore.istoreos.com/repo/aarch64_cortex-a53/nas/routergo_0.14.10_aarch64_cortex-a53.ipk" 2>/dev/null
        curl -fsSL -o luci-app-routerdog.ipk "https://istore.istoreos.com/repo/all/nas_luci/luci-app-routerdog_1.4.10_all.ipk" 2>/dev/null
        rm -rf /tmp/rg && mkdir -p /tmp/rg && tar xzf routergo.ipk -C /tmp/rg
        tar xzf /tmp/rg/data.tar.gz -C $SDCARD 2>/dev/null
        [ -f $SDCARD/usr/sbin/routergo ] && ln -sf $SDCARD/usr/sbin/routergo /usr/sbin/routergo
        [ -f $SDCARD/etc/config/routergo ] && ln -sf $SDCARD/etc/config/routergo /etc/config/routergo
        [ -f $SDCARD/etc/init.d/routergo ] && ln -sf $SDCARD/etc/init.d/routergo /etc/init.d/routergo
        rm -rf /tmp/la && mkdir -p /tmp/la && tar xzf luci-app-routerdog.ipk -C /tmp/la
        rm -rf $SDCARD/routerdog-app && mkdir -p $SDCARD/routerdog-app
        tar xzf /tmp/la/data.tar.gz -C $SDCARD/routerdog-app 2>/dev/null
        [ -f $SDCARD/routerdog-app/usr/lib/lua/luci/controller/routerdog.lua ] && ln -sf $SDCARD/routerdog-app/usr/lib/lua/luci/controller/routerdog.lua /usr/lib/lua/luci/controller/routerdog.lua
        [ -f $SDCARD/routerdog-app/usr/share/luci/menu.d/luci-app-routerdog.json ] && ln -sf $SDCARD/routerdog-app/usr/share/luci/menu.d/luci-app-routerdog.json /usr/share/luci/menu.d/luci-app-routerdog.json
        [ -d $SDCARD/routerdog-app/www/luci-static/routerdog ] && ln -sf $SDCARD/routerdog-app/www/luci-static/routerdog /www/luci-static/routerdog
        fi
      /etc/init.d/routergo enable >/dev/null 2>&1; /etc/init.d/routergo start 2>/dev/null || true; sleep 2
      ok "路由狗安装完成";;
    3)
      if dockerman_installed; then ok "Docker 管理器已存在"; else
        opkg -d sdcard install luci-app-dockerman luci-i18n-dockerman-zh-cn luci-lib-docker docker-compose 2>&1 | grep -qE "Configuring" && ok "已装" || warn "需确认"
        ln -sf $SDCARD/usr/lib/lua/luci/controller/dockerman.lua /usr/lib/lua/luci/controller/dockerman.lua 2>/dev/null
        ln -sf $SDCARD/usr/lib/lua/luci/model/cbi/dockerman /usr/lib/lua/luci/model/cbi/dockerman 2>/dev/null
        ln -sf $SDCARD/usr/lib/lua/luci/view/dockerman /usr/lib/lua/luci/view/dockerman 2>/dev/null
        ln -sf $SDCARD/www/luci-static/resources/dockerman /www/luci-static/resources/dockerman 2>/dev/null
        fi
      info "完成";;
    4) docker_configure;;
    0) :;;
    *) warn "无效选择";;
  esac
  pause
}

# ========== 功能3: OpenClash AI 节点优化 ==========
ai_node_optimize() {
  section "OpenClash AI 节点优化"
  if ! command -v jq >/dev/null 2>&1; then
    fail "需要 jq 支持，请先安装"; pause; return;
  fi
  echo "  AI 测速目标: ChatGPT + Claude + Gemini"

  # 订阅配置
  echo "  ┌──────────────────────────────┐"
  echo "  │   订阅链接配置              │"
  echo "  └──────────────────────────────┘"
  menu "1" "更换/设置订阅链接";
  menu "2" "保留当前订阅，直接测速";
  menu "0" "返回";
  printf "%b\n  请选择: %b" "$CYAN" "$NC"; read SUB_CHOICE
  case "$SUB_CHOICE" in
    1)
      printf "  请输入订阅链接: "
      read NEW_SUB
      if [ -n "$NEW_SUB" ]; then
        uci set openclash.@subscribe[0].address="$NEW_SUB"
        uci set openclash.@config_subscribe[0].address="$NEW_SUB"
        uci commit openclash
        ok "已更换订阅链接(请在 OpenClash 界面点击[更新订阅]拉取节点)"
      fi;;
    0) pause; return;;
    *) :;;
  esac

  # 测速
  echo ""
  CUR_NODE=$(curl -s -H "$AUTH" $OC_BASE/proxies 2>/dev/null | jq -r ".proxies[\"宝贝云\"].now" 2>/dev/null)
  [ -n "$CUR_NODE" ] && echo "  当前节点: $CUR_NODE"
  echo "  正在获取节点列表..."
  curl -s -H "$AUTH" $OC_BASE/proxies | jq -r '.proxies | to_entries[] | select(.value.type == "Vless" or .value.type == "Vmess" or .value.type == "Trojan" or .value.type == "Shadowsocks" or .value.type == "Hysteria" or .value.type == "Hysteria2" or .value.type == "TUIC") | .key' > /tmp/ai_nodes_raw.txt 2>/dev/null
  grep -vE "剩余流量|距离下次重置|套餐到期|无法使用|直连地址|邀请好友|TG群|只有新加坡|更换客户端" /tmp/ai_nodes_raw.txt > /tmp/ai_nodes.txt 2>/dev/null
  TOTAL=$(wc -l < /tmp/ai_nodes.txt 2>/dev/null)
  echo "  检测到 $TOTAL 个真实节点，开始测速(约 2-3 分钟)..."
  echo ""
  BEST_SUM=999999; BEST_NODE=""; COUNT=0
  while IFS= read -r node; do
    [ -z "$node" ] && continue; COUNT=$((COUNT+1))
    ENC=$(echo "$node" | jq -rn --arg s "$node" '$s | @uri')
    SUM=0; OK=0
    for url in $AI_URLS; do
      UENC=$(echo "$url" | jq -rn --arg s "$url" '$s | @uri')
      R=$(curl -s -m 5 -H "$AUTH" "$OC_BASE/proxies/$ENC/delay?timeout=4000&url=$UENC" 2>/dev/null)
      D=$(echo "$R" | jq -r '.delay // "FAIL"' 2>/dev/null)
      if [ "$D" != "FAIL" ] && [ -n "$D" ]; then SUM=$((SUM+D)); OK=$((OK+1)); fi
    done
    if [ "$OK" -gt 0 ]; then
      AVG=$((SUM/OK))
      printf "    [%-3d/%-3d] %-32s %4d ms\n" "$COUNT" "$TOTAL" "$node" "$AVG"
      if [ "$AVG" -lt "$BEST_SUM" ]; then BEST_SUM=$AVG; BEST_NODE="$node"; fi
    fi
  done < /tmp/ai_nodes.txt
  echo ""
  if [ -n "$BEST_NODE" ]; then
    echo "  🏆 AI 最快节点: $BEST_NODE (平均 ${BEST_SUM}ms)"
    printf "%b  是否切换到最快节点？[Y/n] %b" "$YELLOW" "$NC"; read SW_CHOICE
    case "$SW_CHOICE" in
      n|N) echo "  保留当前节点";;
      *)
        GENC=$(echo "宝贝云" | jq -rn --arg s "宝贝云" '$s | @uri')
        curl -s -X PUT -H "$AUTH" -H "Content-Type: application/json" --data-binary "{\"name\":\"$BEST_NODE\"}" "$OC_BASE/proxies/$GENC" >/dev/null 2>&1; sleep 2
        NEW=$(curl -s -H "$AUTH" $OC_BASE/proxies | jq -r ".proxies[\"宝贝云\"].now")
        [ -n "$NEW" ] && ok "已切换: $NEW" || warn "切换需确认";;
    esac
  else
    fail "未找到可用节点，请检查 OpenClash 是否运行"
  fi
  rm -f /tmp/ai_nodes.txt /tmp/ai_nodes_raw.txt
  pause
}

# ========== 功能4: 健康检查 ==========
health_report() {
  section "系统健康检查"
  # Docker
  if docker_installed; then VER=$(docker info --format "{{.ServerVersion}}" 2>/dev/null); [ -n "$VER" ] && ok "Docker 引擎     v$VER" || fail "Docker 引擎    未启动"; else fail "Docker 引擎    未安装"; fi
  NC=$(docker ps -q 2>/dev/null | wc -l); [ "$NC" -gt 0 ] 2>/dev/null && ok "运行容器      $NC 个" || info "运行容器      0 个"
  # 路由狗
  routergo_installed && ok "路由狗        已安装" || fail "路由狗        未安装"
  /etc/init.d/routergo status 2>/dev/null | grep -q running && ok "routergo 服务 运行中" || warn "routergo 服务 未运行"
  # dockerman
  dockerman_installed && ok "Docker管理器  已安装" || fail "Docker管理器  未安装"
  # OpenClash
  if curl -s -H "$AUTH" $OC_BASE/version >/dev/null 2>&1; then
    CUR=$(curl -s -H "$AUTH" $OC_BASE/proxies 2>/dev/null | jq -r ".proxies[\"宝贝云\"].now" 2>/dev/null)
    ok "OpenClash      运行中 (节点: $CUR)"
  else
    warn "OpenClash      未运行"
  fi
  # 网络
  NG=$(curl -s -o /dev/null -w "%{http_code}" -m 8 -x http://Clash:H1p9uybR@127.0.0.1:7890 https://www.google.com/generate_204 2>/dev/null)
  [ "$NG" = "204" ] && ok "网络          Google 可达" || warn "网络          Google 不可达"
  # 存储
  mount | grep -q "on $SDCARD type" && ok "存储          SD 卡正常 $SDCARD" || warn "存储          未挂载"
}

# ========== 功能5: 卸载/清理 ==========
uninstall_clean() {
  echo ""
  echo "  ┌──────────────────────────────┐"
  echo "  │   卸载 / 清理               │"
  echo "  └──────────────────────────────┘"
  menu "1" "卸载 Docker(保留数据)";
  menu "2" "卸载路由狗";
  menu "3" "清理 Docker 缓存/无用镜像";
  menu "4" "查看磁盘空间";
  menu "0" "返回主菜单";
  printf "%b\n  请选择: %b" "$CYAN" "$NC"; read UC_CHOICE
  case "$UC_CHOICE" in
    1)
      printf "%b  确认卸载 Docker？数据将保留在 $DOCKER_ROOT [y/N] %b" "$RED" "$NC"; read CONFIRM
      case "$CONFIRM" in
        y|Y)
          /etc/init.d/dockerd stop 2>/dev/null; sleep 2
          for p in $(pidof dockerd) $(pidof containerd); do kill -9 $p 2>/dev/null; done
          rm -f /usr/bin/docker /usr/bin/dockerd /usr/bin/containerd* /usr/bin/runc
          rm -rf /etc/init.d/dockerd /etc/config/dockerd
          ok "Docker 已卸载 (数据保留在 $DOCKER_ROOT)";;
        *) echo "  已取消";;
      esac;;
    2)
      printf "%b  确认卸载路由狗？[y/N] %b" "$RED" "$NC"; read C2
      case "$C2" in
        y|Y)
          /etc/init.d/routergo stop 2>/dev/null
          rm -f /usr/sbin/routergo /usr/bin/routergo /etc/init.d/routergo /etc/config/routergo
          rm -f /usr/share/luci/menu.d/luci-app-routerdog.json
          ok "路由狗已卸载";;
        *) echo "  已取消";;
      esac;;
    3)
      if docker_installed; then
        docker system prune -f 2>&1 | tail -2
        ok "清理完成"
      else
        warn "Docker 未安装"
      fi;;
    4) echo ""; df -h | grep -E "overlay|sdcard|Filesystem";;
    0) :;;
    *) warn "无效选择";;
  esac
  pause
}

# ========== 主菜单 ==========
main_menu() {
  clear 2>/dev/null
  printf "%b" "$CYAN"
  echo "╔══════════════════════════════════════════╗"
  echo "║   路由器 Docker + NAS 工具箱             ║"
  echo "║       OpenWrt / ImmortalWrt              ║"
  echo "╚══════════════════════════════════════════╝"
  printf "%b" "$NC"
  echo ""
  echo "  系统信息:"
  info "架构: $(uname -m)"
  MEM_KB=$(free | awk '/Mem:/{print $7}'); MEM_MB=$((MEM_KB/1024)); info "内存: ${MEM_MB} MB 可用"
  [ -n "$(docker --version 2>/dev/null)" ] && info "Docker: 已安装" || info "Docker: 未安装"
  echo ""
  echo "  ┌──────────────────────────────┐"
  echo "  │   请选择功能                  │"
  echo "  └──────────────────────────────┘"
  menu "1" "全自动安装 (Docker + 路由狗 + 管理器)";
  menu "2" "单独安装某个组件";
  menu "3" "OpenClash AI 节点优化 (订阅/测速/切换)";
  menu "4" "系统健康检查";
  menu "5" "卸载 / 清理";
  menu "0" "退出";
  echo ""
  printf "%b  请输入选项 [0-5]: %b" "$CYAN" "$NC"; read MAIN_CHOICE
  echo ""
  case "$MAIN_CHOICE" in
    1) full_install;;
    2) single_install;;
    3) ai_node_optimize;;
    4) health_report; pause;;
    5) uninstall_clean;;
    0) echo "  再见！"; exit 0;;
    *) warn "无效选项，请重新输入"; sleep 1; main_menu;;
  esac
  # 循环回到主菜单
  sleep 1; main_menu
}

# 启动
main_menu