#!/bin/sh
# ============================================================
#  一键安装脚本：Docker + 路由狗(RouterDog) + LuCI Docker管理
#  适用设备：MYOS/ImmortalWrt (aarch64) 路由器
#  用法：sh -c "$(curl -fsSL URL)"
# ============================================================

# ---------- 颜色输出（printf 兼容 busybox）----------
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; BLUE="\033[1;34m"; NC="\033[0m"
ok()   { printf "%b[✓]%b %s\n" "$GREEN" "$NC" "$1"; }
warn() { printf "%b[!]%b %s\n" "$YELLOW" "$NC" "$1"; }
err()  { printf "%b[✗]%b %s\n" "$RED" "$NC" "$1"; exit 1; }
info() { printf "%b[→]%b %s\n" "$GREEN" "$NC" "$1"; }
step() { printf "%b[步骤]%b %s\n" "$BLUE" "$NC" "$1"; }

# ---------- 基础检查 ----------
[ "$(id -u)" = "0" ] || err "请以 root 运行"
uname -m | grep -q aarch64 || warn "非 aarch64 架构，脚本可能不适用"

SDCARD="/mnt/sdcard"
DOCKER_ROOT="$SDCARD/docker"
PKG_DIR="$SDCARD/pkgs"

# ---------- 工具函数：检查命令是否存在 ----------
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# ---------- 工具函数：检查是否已安装 ----------
# 返回 0=已装, 1=未装
docker_installed() {
  [ -x /usr/bin/docker ] && docker --version >/dev/null 2>&1
}
routergo_installed() {
  [ -x /usr/sbin/routergo ] && [ -f /usr/lib/lua/luci/controller/routerdog.lua ]
}
dockerman_installed() {
  [ -f /usr/lib/lua/luci/controller/dockerman.lua ];
}

# ============================================================
#  步骤 1/7: SD 卡分区与挂载
# ============================================================
step "步骤 1/7: 检查 SD 卡空间"
if mount | grep -q "on $SDCARD type"; then
  SD_SIZE=$(df -h $SDCARD | awk "NR==2{print \$2}")
  ok "$SDCARD 已挂载 (容量 $SD_SIZE)"
else
  info "检测到 $SDCARD 未挂载，开始分区..."
  if [ ! -b /dev/mmcblk0p7 ]; then
    warn "未发现 p7 分区，将在 SD 卡未使用空间创建..."
    P6_END=$(fdisk -l /dev/mmcblk0 2>/dev/null | awk "/mmcblk0p6/{print \$3}")
    if [ -z "$P6_END" ]; then
      err "无法读取分区表，请检查磁盘状态"
    fi
    info "创建 p7 分区..."
    printf "n\n7\n%s\n\nw\n" "$((P6_END+1))" | fdisk /dev/mmcblk0 >/dev/null 2>&1
    sleep 3
    [ -b /dev/mmcblk0p7 ] || err "分区创建失败，请手动 fdisk /dev/mmcblk0 检查"
    ok "分区 /dev/mmcblk0p7 已创建"
    info "格式化 f2fs..."
    mkfs.f2fs -f -l sdcard /dev/mmcblk0p7 >/dev/null 2>&1 || err "格式化失败"
    ok "已格式化 f2fs"
  fi
  mkdir -p $SDCARD
  mount -t f2fs /dev/mmcblk0p7 $SDCARD 2>/dev/null || err "挂载失败，请手动执行: mount -t f2fs /dev/mmcblk0p7 $SDCARD"
  ok "已挂载到 $SDCARD"
  info "写入开机自动挂载配置..."
  cat >> /etc/config/fstab <<EOF2

config mount
	option target '$SDCARD'
	option device '/dev/mmcblk0p7'
	option fstype 'f2fs'
	option enabled '1'
EOF2
  /etc/init.d/fstab enable >/dev/null 2>&1
  ok "已配置开机自动挂载"
fi
mkdir -p $DOCKER_ROOT

# ============================================================
#  步骤 2/7: 安装 Docker 到 SD 卡
# ============================================================
step "步骤 2/7: 安装 Docker"
if docker_installed; then
  ok "Docker 已安装 ($(docker --version 2>&1 | head -1))，跳过安装"
else
  info "开始安装 Docker（首次安装约需 2-5 分钟）..."
  grep -q "dest sdcard" /etc/opkg.conf || echo "dest sdcard $SDCARD" >> /etc/opkg.conf

  info "安装内核模块依赖..."
  for k in kmod-ipt-nat kmod-ipt-nat6 kmod-nf-ipvs kmod-veth; do
    if opkg list-installed | grep -q "^$k "; then
      info "  ✓ $k 已安装"
    else
      opkg install $k >/dev/null 2>&1 && ok "  ✓ $k 安装成功" || warn "  ⚠ $k 安装失败（可能已内置）"
    fi
  done

  info "下载并安装 Docker 组件..."
  if opkg -d sdcard --force-depends install docker dockerd containerd runc tini libseccomp ca-certificates iptables-mod-extra 2>&1 | grep -vE "Failed to open|pkg_get_installed_files" | grep -q "installed\|Configuring"; then
    ok "Docker 组件安装完成"
  else
    warn "部分组件可能未完全安装，继续尝试..."
  fi

  info "链接二进制到系统路径..."
  for b in docker dockerd containerd containerd-shim containerd-shim-runc-v1 containerd-shim-runc-v2 docker-init docker-proxy tini; do
    [ -f $SDCARD/usr/bin/$b ] && ln -sf $SDCARD/usr/bin/$b /usr/bin/$b 2>/dev/null
    [ -f $SDCARD/usr/sbin/$b ] && ln -sf $SDCARD/usr/sbin/$b /usr/sbin/$b 2>/dev/null
  done
  [ -f $SDCARD/usr/sbin/runc ] && ln -sf $SDCARD/usr/sbin/runc /usr/bin/runc 2>/dev/null
  for lib in $SDCARD/usr/lib/libseccomp* $SDCARD/usr/lib/libc.so*; do
    [ -f "$lib" ] && ln -sf "$lib" /usr/lib/ 2>/dev/null
  done
  [ -f $SDCARD/etc/init.d/dockerd ] && ln -sf $SDCARD/etc/init.d/dockerd /etc/init.d/dockerd
  [ -f $SDCARD/etc/config/dockerd ] && {
    rm -f /etc/config/dockerd
    cp $SDCARD/etc/config/dockerd /etc/config/dockerd
  }
  ok "Docker 二进制链接完成"
fi

# ============================================================
#  步骤 3/7: 配置 Docker
# ============================================================
step "步骤 3/7: 配置 Docker"
info "设置数据目录到 SD 卡..."
uci set dockerd.globals.data_root="$DOCKER_ROOT"
uci set dockerd.globals.iptables='0'
uci commit dockerd

# 检测 OpenClash 认证并配置代理
if [ -n "$(uci get openclash.@authentication[0].username 2>/dev/null)" ]; then
  OC_U=$(uci get openclash.@authentication[0].username)
  OC_P=$(uci get openclash.@authentication[0].password)
  uci set dockerd.proxies="proxies"
  uci set dockerd.proxies.http_proxy="http://$OC_U:$OC_P@127.0.0.1:7890"
  uci set dockerd.proxies.https_proxy="http://$OC_U:$OC_P@127.0.0.1:7890"
  uci set dockerd.proxies.no_proxy='localhost,127.0.0.1'
  uci commit dockerd
  ok "已配置代理 (OpenClash: $OC_U)"
else
  warn "未检测到 OpenClash 认证，Docker 拉镜像可能失败"
  warn "如有需要，稍后可手动配置代理"
fi

info "启动 Docker 服务..."
/etc/init.d/dockerd enable >/dev/null 2>&1
/etc/init.d/dockerd start 2>/dev/null || true
sleep 8

# 只在 socket 异常时才清理（避免误杀）
if [ ! -S /var/run/docker.sock ]; then
  warn "Docker socket 未创建，尝试清理并重启..."
  for p in $(pidof dockerd) $(pidof containerd); do kill -9 $p 2>/dev/null; done; sleep 2
  rm -f /var/run/docker.pid /var/run/docker.sock 2>/dev/null
  rm -rf /var/run/docker /var/run/containerd 2>/dev/null
  /etc/init.d/dockerd start 2>/dev/null || true
  sleep 10
fi

# 验证 Docker 运行状态
VER=$(docker info --format "{{.ServerVersion}}" 2>/dev/null)
if [ -n "$VER" ]; then
  ok "Docker 运行中 (v$VER)"
  info "测试拉取镜像..."
  if docker pull hello-world >/dev/null 2>&1; then
    ok "Docker 镜像拉取测试通过"
  else
    warn "镜像拉取失败，请检查代理配置（OpenClash 是否运行、节点是否可用）"
  fi
else
  err "Docker 启动失败！请手动检查:"
  echo "   1. 查看日志: logread | grep dockerd"
  echo "   2. 手动启动: /etc/init.d/dockerd start"
  echo "   3. 检查数据目录: ls -la $DOCKER_ROOT"
fi

# ============================================================
#  步骤 4/7: 添加 iStore 源
# ============================================================
step "步骤 4/7: 添加 iStore 源"
if grep -q "is_meta" /etc/opkg/customfeeds.conf 2>/dev/null; then
  ok "iStore 源已存在，跳过"
else
  info "添加 iStore 官方源..."
  cat >> /etc/opkg/customfeeds.conf <<'EOF3'
src/gz is_meta https://istore.istoreos.com/repo/all/meta
src/gz is_store https://istore.istoreos.com/repo/all/store
src/gz is_nas_luci https://istore.istoreos.com/repo/all/nas_luci
src/gz is_nas https://istore.istoreos.com/repo/aarch64_cortex-a53/nas
EOF3
  opkg update >/dev/null 2>&1
  ok "iStore 源已添加"
fi

# ============================================================
#  步骤 5/7: 安装路由狗
# ============================================================
step "步骤 5/7: 安装路由狗"
if routergo_installed; then
  ok "路由狗已安装，跳过安装"
else
  info "下载路由狗安装包..."
  mkdir -p $PKG_DIR
  cd $PKG_DIR
  curl -s -o app-meta-routerdog.ipk "https://istore.istoreos.com/repo/all/meta/app-meta-routerdog_1.4.10-r2_all.ipk" || warn "app-meta 下载失败"
  curl -s -o luci-app-routerdog.ipk "https://istore.istoreos.com/repo/all/nas_luci/luci-app-routerdog_1.4.10_all.ipk" || warn "luci-app 下载失败"
  curl -s -o routergo.ipk "https://istore.istoreos.com/repo/aarch64_cortex-a53/nas/routergo_0.14.10_aarch64_cortex-a53.ipk" || warn "routergo 下载失败"

  info "解压安装 routergo..."
  rm -rf /tmp/rg && mkdir -p /tmp/rg && tar xzf routergo.ipk -C /tmp/rg 2>/dev/null
  tar xzf /tmp/rg/data.tar.gz -C $SDCARD 2>/dev/null
  [ -f $SDCARD/usr/sbin/routergo ] && ln -sf $SDCARD/usr/sbin/routergo /usr/sbin/routergo
  ln -sf $SDCARD/usr/sbin/routergo /usr/bin/routergo 2>/dev/null
  [ -f $SDCARD/etc/config/routergo ] && ln -sf $SDCARD/etc/config/routergo /etc/config/routergo
  [ -f $SDCARD/etc/init.d/routergo ] && ln -sf $SDCARD/etc/init.d/routergo /etc/init.d/routergo

  info "解压安装 luci-app..."
  rm -rf /tmp/la && mkdir -p /tmp/la && tar xzf luci-app-routerdog.ipk -C /tmp/la 2>/dev/null
  rm -rf $SDCARD/routerdog-app && mkdir -p $SDCARD/routerdog-app
  tar xzf /tmp/la/data.tar.gz -C $SDCARD/routerdog-app 2>/dev/null
  [ -f $SDCARD/routerdog-app/etc/config/routerdog ] && ln -sf $SDCARD/routerdog-app/etc/config/routerdog /etc/config/routerdog
  [ -f $SDCARD/routerdog-app/etc/uci-defaults/50_luci-routerdog ] && {
    mkdir -p /etc/uci-defaults
    ln -sf $SDCARD/routerdog-app/etc/uci-defaults/50_luci-routerdog /etc/uci-defaults/50_luci-routerdog
    sh /etc/uci-defaults/50_luci-routerdog 2>/dev/null || true
  }
  [ -f $SDCARD/routerdog-app/usr/lib/lua/luci/controller/routerdog.lua ] && ln -sf $SDCARD/routerdog-app/usr/lib/lua/luci/controller/routerdog.lua /usr/lib/lua/luci/controller/routerdog.lua
  [ -f $SDCARD/routerdog-app/usr/lib/lua/luci/controller/routergo_backend.lua ] && ln -sf $SDCARD/routerdog-app/usr/lib/lua/luci/controller/routergo_backend.lua /usr/lib/lua/luci/controller/routergo_backend.lua
  [ -d $SDCARD/routerdog-app/usr/lib/lua/luci/view/routerdog ] && ln -sf $SDCARD/routerdog-app/usr/lib/lua/luci/view/routerdog /usr/lib/lua/luci/view/routerdog
  [ -f $SDCARD/routerdog-app/usr/share/luci/menu.d/luci-app-routerdog.json ] && ln -sf $SDCARD/routerdog-app/usr/share/luci/menu.d/luci-app-routerdog.json /usr/share/luci/menu.d/luci-app-routerdog.json
  [ -d $SDCARD/routerdog-app/www/luci-static/routerdog ] && ln -sf $SDCARD/routerdog-app/www/luci-static/routerdog /www/luci-static/routerdog
  ok "路由狗安装完成"
fi

# 启动/确认 routergo 服务
info "确认 routergo 服务状态..."
/etc/init.d/routergo enable >/dev/null 2>&1
/etc/init.d/routergo start 2>/dev/null || true
sleep 3
if /etc/init.d/routergo status 2>/dev/null | grep -q running; then
  ok "routergo 运行中"
else
  warn "routergo 启动异常，请检查: logread | grep routergo"
fi

# ============================================================
#  步骤 6/7: 安装 LuCI Docker 管理器
# ============================================================
step "步骤 6/7: 安装 LuCI Docker 管理器"
if dockerman_installed; then
  ok "LuCI Docker 管理器已安装，跳过"
else
  info "安装 dockerman..."
  opkg -d sdcard install luci-app-dockerman luci-i18n-dockerman-zh-cn luci-lib-docker docker-compose 2>&1 | grep -vE "Failed to open|pkg_get_installed_files" | tail -3 || true

  info "链接 dockerman 文件..."
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
  ok "LuCI Docker 管理器已安装"
fi

# ============================================================
#  步骤 7/7: 完成
# ============================================================
step "步骤 7/7: 完成"
info "清理 LuCI 缓存..."
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null
/etc/init.d/uhttpd restart >/dev/null 2>&1
sleep 3

echo ""
echo "=============================================="
echo "  ✅ 安装完成！"
echo "=============================================="
echo ""
echo "  访问入口："
echo "    http://192.168.66.1       → 路由狗 NAS 界面(登录后)"
echo "    LuCI 菜单 → Docker         → Docker 管理器"
echo "    LuCI 菜单 → RouterDog      → 路由狗"
echo ""
echo "  Docker 数据目录: $DOCKER_ROOT (SD 卡)"
echo ""
echo "  已安装组件状态:"
echo "    Docker:   $(docker_installed && echo 已安装 || echo 未安装)"
echo "    路由狗:   $(routergo_installed && echo 已安装 || echo 未安装)"
echo "    Dockerman: $(dockerman_installed && echo 已安装 || echo 未安装)"
echo "=============================================="