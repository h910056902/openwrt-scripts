#!/bin/sh
# ============================================================
#  一键安装脚本：Docker + 路由狗(RouterDog) + LuCI Docker管理
#  适用设备：MYOS/ImmortalWrt (aarch64) 路由器
#  用法：sh install_routerdog_docker.sh
# ============================================================

set -e

# ---------- 颜色输出（用 printf 兼容 busybox）----------
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; NC="\033[0m"
ok()  { printf "%b[✓]%b %s\n" "$GREEN" "$NC" "$1"; }
warn(){ printf "%b[!]%b %s\n" "$YELLOW" "$NC" "$1"; }
err() { printf "%b[✗]%b %s\n" "$RED" "$NC" "$1"; exit 1; }
info(){ printf "%b[→]%b %s\n" "$GREEN" "$NC" "$1"; }

# ---------- 基础检查 ----------
[ "$(id -u)" = "0" ] || err "请以 root 运行"
uname -m | grep -q aarch64 || warn "非 aarch64 架构，脚本可能不适用"

SDCARD="/mnt/sdcard"
DOCKER_ROOT="$SDCARD/docker"
PKG_DIR="$SDCARD/pkgs"

# ---------- 1. SD 卡分区与挂载 ----------
info "步骤 1/7: 检查 SD 卡空间"
if ! mount | grep -q " $SDCARD "; then
  info "未挂载 $SDCARD，检测分区..."
  if [ ! -b /dev/mmcblk0p7 ]; then
    warn "创建 p7 分区 (占用未使用空间)..."
    P6_END=$(fdisk -l /dev/mmcblk0 2>/dev/null | awk "/mmcblk0p6/{print \$3}")
    [ -n "$P6_END" ] || err "无法读取分区表"
    printf "n\n7\n%s\n\nw\n" "$((P6_END+1))" | fdisk /dev/mmcblk0 >/dev/null 2>&1
    sleep 3
    [ -b /dev/mmcblk0p7 ] || err "分区创建失败"
    ok "分区 /dev/mmcblk0p7 已创建"
    mkfs.f2fs -f -l sdcard /dev/mmcblk0p7 >/dev/null 2>&1
    ok "已格式化 f2fs"
  fi
  mkdir -p $SDCARD
  mount -t f2fs /dev/mmcblk0p7 $SDCARD 2>/dev/null || err "挂载失败"
  ok "已挂载到 $SDCARD"
  cat >> /etc/config/fstab <<EOF2

config mount
	option target '$SDCARD'
	option device '/dev/mmcblk0p7'
	option fstype 'f2fs'
	option enabled '1'
EOF2
  /etc/init.d/fstab enable >/dev/null 2>&1
  ok "已配置开机自动挂载"
else
  ok "$SDCARD 已挂载"
fi
mkdir -p $DOCKER_ROOT

# ---------- 2. 安装 Docker 到 SD 卡 ----------
info "步骤 2/7: 安装 Docker 到 SD 卡"
grep -q "dest sdcard" /etc/opkg.conf || echo "dest sdcard $SDCARD" >> /etc/opkg.conf

for k in kmod-ipt-nat kmod-ipt-nat6 kmod-nf-ipvs kmod-veth; do
  opkg list-installed | grep -q "^$k " || opkg install $k >/dev/null 2>&1
done

opkg -d sdcard --force-depends install docker dockerd containerd runc tini libseccomp ca-certificates iptables-mod-extra 2>&1 | grep -vE "Failed to open|pkg_get_installed_files" | tail -3 || true
ok "Docker 组件已装到 $SDCARD"

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
ok "Docker 二进制已链接"

# ---------- 3. 配置 Docker ----------
info "步骤 3/7: 配置 Docker"
uci set dockerd.globals.data_root="$DOCKER_ROOT"
uci set dockerd.globals.iptables='0'
uci commit dockerd

if [ -n "$(uci get openclash.@authentication[0].username 2>/dev/null)" ]; then
  OC_U=$(uci get openclash.@authentication[0].username)
  OC_P=$(uci get openclash.@authentication[0].password)
  uci set dockerd.proxies='proxies'
  uci set dockerd.proxies.http_proxy="http://$OC_U:$OC_P@127.0.0.1:7890"
  uci set dockerd.proxies.https_proxy="http://$OC_U:$OC_P@127.0.0.1:7890"
  uci set dockerd.proxies.no_proxy='localhost,127.0.0.1'
  uci commit dockerd
  ok "已配置代理 (OpenClash 认证)"
fi

/etc/init.d/dockerd enable >/dev/null 2>&1
/etc/init.d/dockerd start 2>/dev/null || true
sleep 8
# 清理残留：只清理可能卡住的 socket/pid，不杀进程
if [ ! -S /var/run/docker.sock ]; then
  for p in $(pidof dockerd) $(pidof containerd); do kill -9 $p 2>/dev/null; done; sleep 2
  rm -f /var/run/docker.pid /var/run/docker.sock 2>/dev/null
  rm -rf /var/run/docker /var/run/containerd 2>/dev/null
  /etc/init.d/dockerd start 2>/dev/null || true
  sleep 10
fi
VER=$(docker info --format "{{.ServerVersion}}" 2>/dev/null)
if [ -n "$VER" ]; then
  ok "Docker 运行中 (v$VER)"
else
  warn "Docker 启动失败，请手动检查"
fi
docker pull hello-world >/dev/null 2>&1 && ok "Docker 拉取镜像测试通过" || warn "拉取测试失败(检查代理)"

# ---------- 4. 添加 iStore 源 ----------
info "步骤 4/7: 添加 iStore 源"
grep -q "is_meta" /etc/opkg/customfeeds.conf 2>/dev/null || cat >> /etc/opkg/customfeeds.conf <<'EOF3'
src/gz is_meta https://istore.istoreos.com/repo/all/meta
src/gz is_store https://istore.istoreos.com/repo/all/store
src/gz is_nas_luci https://istore.istoreos.com/repo/all/nas_luci
src/gz is_nas https://istore.istoreos.com/repo/aarch64_cortex-a53/nas
EOF3
opkg update >/dev/null 2>&1
ok "iStore 源已添加"

# ---------- 5. 安装路由狗 ----------
info "步骤 5/7: 安装路由狗"
mkdir -p $PKG_DIR
cd $PKG_DIR
curl -s -o app-meta-routerdog.ipk "https://istore.istoreos.com/repo/all/meta/app-meta-routerdog_1.4.10-r2_all.ipk"
curl -s -o luci-app-routerdog.ipk "https://istore.istoreos.com/repo/all/nas_luci/luci-app-routerdog_1.4.10_all.ipk"
curl -s -o routergo.ipk "https://istore.istoreos.com/repo/aarch64_cortex-a53/nas/routergo_0.14.10_aarch64_cortex-a53.ipk"

rm -rf /tmp/rg && mkdir -p /tmp/rg && tar xzf routergo.ipk -C /tmp/rg
tar xzf /tmp/rg/data.tar.gz -C $SDCARD 2>/dev/null
[ -f $SDCARD/usr/sbin/routergo ] && ln -sf $SDCARD/usr/sbin/routergo /usr/sbin/routergo
ln -sf $SDCARD/usr/sbin/routergo /usr/bin/routergo 2>/dev/null
[ -f $SDCARD/etc/config/routergo ] && ln -sf $SDCARD/etc/config/routergo /etc/config/routergo
[ -f $SDCARD/etc/init.d/routergo ] && ln -sf $SDCARD/etc/init.d/routergo /etc/init.d/routergo

rm -rf /tmp/la && mkdir -p /tmp/la && tar xzf luci-app-routerdog.ipk -C /tmp/la
rm -rf $SDCARD/routerdog-app && mkdir -p $SDCARD/routerdog-app
tar xzf /tmp/la/data.tar.gz -C $SDCARD/routerdog-app
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

/etc/init.d/routergo enable >/dev/null 2>&1
/etc/init.d/routergo start 2>/dev/null || true
sleep 3
if /etc/init.d/routergo status 2>/dev/null | grep -q running; then
  ok "routergo 运行中"
else
  warn "routergo 启动异常"
fi
ok "路由狗安装完成"

# ---------- 6. 安装 LuCI Docker 管理器 ----------
info "步骤 6/7: 安装 LuCI Docker 管理器"
opkg -d sdcard install luci-app-dockerman luci-i18n-dockerman-zh-cn luci-lib-docker docker-compose 2>&1 | grep -vE "Failed to open|pkg_get_installed_files" | tail -3 || true

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

# ---------- 7. 完成 ----------
info "步骤 7/7: 完成"
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
echo "=============================================="