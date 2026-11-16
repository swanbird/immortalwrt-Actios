#!/bin/bash
# DIY脚本
# https://github.com/P3TERX/Actions-OpenWrt
# 文件名: diy-part2.sh
# 功能说明: OpenWrt DIY脚本第2部分（更新feeds之后）
# 版权: (c) 2019-2024 P3TERX <https://p3terx.com>
# 基于 MIT 开源协议，详见 /LICENSE

# 修改默认IP地址
#sed -i 's/192.168.1.1/192.168.100.1/g' package/base-files/files/bin/config_generate


# 修改默认主题为 argon（路径不存在时跳过，不中断编译）
sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile 2>/dev/null || true

# 启用 IPv4 策略路由（直接写入内核 platform config，绕过 make defconfig 的依赖检查）
# CONFIG_KERNEL_IP_ADVANCED_ROUTER 在 OpenWrt Config.in 中无对应 wrapper，必须用此方式
#for cfg in target/linux/msm89xx/config-*; do
#  grep -q 'CONFIG_IP_ADVANCED_ROUTER' "$cfg" || echo 'CONFIG_IP_ADVANCED_ROUTER=y' >> "$cfg"
#  grep -q 'CONFIG_IP_MULTIPLE_TABLES' "$cfg" || echo 'CONFIG_IP_MULTIPLE_TABLES=y' >> "$cfg"
#done


# 临时添加的插件
# git clone https://github.com/lkiuyu/luci-app-cpu-perf package/luci-app-cpu-perf
# git clone https://github.com/lkiuyu/luci-app-cpu-status package/luci-app-cpu-status
# git clone https://github.com/gSpotx2f/luci-app-cpu-status-mini package/luci-app-cpu-status-mini
# git clone https://github.com/lkiuyu/luci-app-temp-status package/luci-app-temp-status
# git clone https://github.com/lkiuyu/DbusSmsForwardCPlus package/DbusSmsForwardCPlus

# ===== 补充：不在官方 feed / small-package 中的两个插件（按用户清单要求） =====
# luci-app-temp-status：gSpotx2f 上游，取 lkiuyu 的适配版
git clone --depth 1 https://github.com/lkiuyu/luci-app-temp-status package/luci-app-temp-status || true
# luci-app-atinout + atinout 命令行工具：仓库根目录下含两个包，整体克隆
git clone --depth 1 https://github.com/4IceG/luci-app-atinout package/atinout-src || true

# 注：luci-app-modeminfo（4IceG）已撤出固件，原因：
#   其 Makefile 声明 DEPENDS:=+modeminfo，但上游从未提供可用的 modeminfo CLI 包；
#   补第三方 CLI 又与前端包 root/ 自带的 /usr/bin/modeminfo 文件冲突（opkg 致命错）。
#   风险大于收益（设备上已有 3ginfo-lite / modemband 覆盖同类功能），不再编译。

# ===== wcn36xx：修复 AP 模式下广播/组播帧无法被终端解密 =====
# 现象：AP 模式下所有无线终端收不到网关发出的广播/组播（ARP、mDNS 全灭），
#       单播双向正常。原因是驱动把组密钥注册成 RX_ONLY，且组播帧交给固件时
#       用的是单播 DPU 描述符/签名，固件没有可用于发送的 GTK。
# 处理：① 组密钥方向改为 TX_RX；② 组播帧改用 CONFIG_BSS_RSP 返回的 GTK
#       描述符与签名；③ 顺带打印 GTK 签名，便于用 debug_mask 验证。
mkdir -p target/linux/msm89xx/patches-6.12
cat > target/linux/msm89xx/patches-6.12/999-wcn36xx-gtk-group-tx.patch <<'WCN36XX_PATCH_EOF'
--- a/drivers/net/wireless/ath/wcn36xx/txrx.c
+++ b/drivers/net/wireless/ath/wcn36xx/txrx.c
@@ -554,8 +554,17 @@
 	} else {
 		__vif_priv = get_vif_by_addr(wcn, hdr->addr2);
 		bd->sta_index = __vif_priv->self_sta_index;
-		bd->dpu_desc_idx = __vif_priv->self_dpu_desc_index;
-		bd->dpu_sign = __vif_priv->self_ucast_dpu_sign;
+		if (bcast && __vif_priv->bcast_dpu_sign) {
+			/* Group addressed frames are protected with the GTK,
+			 * which the firmware keeps in its own DPU descriptor
+			 * with its own signature.
+			 */
+			bd->dpu_desc_idx = __vif_priv->bcast_dpu_desc_index;
+			bd->dpu_sign = __vif_priv->bcast_dpu_sign;
+		} else {
+			bd->dpu_desc_idx = __vif_priv->self_dpu_desc_index;
+			bd->dpu_sign = __vif_priv->self_ucast_dpu_sign;
+		}
 	}
 
 	if (is_data_qos) {
--- a/drivers/net/wireless/ath/wcn36xx/smd.c
+++ b/drivers/net/wireless/ath/wcn36xx/smd.c
@@ -1861,11 +1861,13 @@
 	wcn36xx_dbg(WCN36XX_DBG_HAL,
 		    "hal config bss rsp status %d bss_idx %d dpu_desc_index %d"
 		    " sta_idx %d self_idx %d bcast_idx %d mac %pM"
-		    " power %d ucast_dpu_signature %d\n",
+		    " power %d ucast_dpu_signature %d"
+		    " bcast_dpu_desc %d bcast_dpu_signature %d\n",
 		    params->status, params->bss_index, params->dpu_desc_index,
 		    params->bss_sta_index, params->bss_self_sta_index,
 		    params->bss_bcast_sta_idx, params->mac,
-		    params->tx_mgmt_power, params->ucast_dpu_signature);
+		    params->tx_mgmt_power, params->ucast_dpu_signature,
+		    params->bcast_dpu_desc_indx, params->bcast_dpu_signature);
 
 	vif_priv->bss_index = params->bss_index;
 
@@ -1876,6 +1878,8 @@
 	}
 
 	vif_priv->self_ucast_dpu_sign = params->ucast_dpu_signature;
+	vif_priv->bcast_dpu_desc_index = params->bcast_dpu_desc_indx;
+	vif_priv->bcast_dpu_sign = params->bcast_dpu_signature;
 
 	return 0;
 }
@@ -2130,7 +2134,13 @@
 	msg_body.num_keys = 1;
 	msg_body.keys[0].id = keyidx;
 	msg_body.keys[0].unicast = 0;
-	msg_body.keys[0].direction = WCN36XX_HAL_RX_ONLY;
+	/* The group key protects both directions: an AP encrypts group
+	 * addressed traffic with it, and every peer both decrypts with it and
+	 * encrypts its own group addressed frames with it. Marking it RX only
+	 * leaves the firmware without a TX key for broadcast/multicast, so the
+	 * frames leave the AP in a form no station can decode.
+	 */
+	msg_body.keys[0].direction = WCN36XX_HAL_TX_RX;
 	msg_body.keys[0].pae_role = 0;
 	msg_body.keys[0].length = keylen;
 	memcpy(msg_body.keys[0].key, key, keylen);
--- a/drivers/net/wireless/ath/wcn36xx/wcn36xx.h
+++ b/drivers/net/wireless/ath/wcn36xx/wcn36xx.h
@@ -139,6 +139,13 @@
 	u8 self_sta_index;
 	u8 self_dpu_desc_index;
 	u8 self_ucast_dpu_sign;
+	/* Returned from WCN36XX_HAL_CONFIG_BSS_RSP: DPU descriptor index and
+	 * signature of the group (GTK) key. Group addressed frames have to be
+	 * handed to the firmware with these, otherwise they get encrypted with
+	 * the pairwise key and no peer is able to decrypt them.
+	 */
+	u8 bcast_dpu_desc_index;
+	u8 bcast_dpu_sign;
 
 #if IS_ENABLED(CONFIG_IPV6)
 	/* IPv6 addresses for WoWLAN */
WCN36XX_PATCH_EOF
echo "[diy] wcn36xx GTK patch: $(wc -l < target/linux/msm89xx/patches-6.12/999-wcn36xx-gtk-group-tx.patch) lines"

# ===== 补回 libffi 包（上游漂移修复） =====
# 现象：编译到 glib2 时中断
#   Package glib2-gobject is missing dependencies for the following libraries: libffi.so.8
# 原因：锁定的核心源码树（24.10 时期）里没有 package/libs/libffi，而 feeds 中的
#       glib2 仍声明 DEPENDS:=... +libffi，于是 libffi 永远不会被编译进来。
# 处理：从 immortalwrt master 稀疏检出该包补入源码树。
if [ ! -d package/libs/libffi ]; then
	echo "[diy] 补入 libffi 包（glib2 依赖）"
	rm -rf /tmp/iw-src
	if git clone --depth 1 --filter=blob:none --sparse \
		https://github.com/immortalwrt/immortalwrt /tmp/iw-src >/dev/null 2>&1; then
		( cd /tmp/iw-src && git sparse-checkout set package/libs/libffi ) >/dev/null 2>&1
		if [ -d /tmp/iw-src/package/libs/libffi ]; then
			mkdir -p package/libs
			cp -r /tmp/iw-src/package/libs/libffi package/libs/
			echo "[diy] libffi 已就位，共 $(find package/libs/libffi -type f | wc -l) 个文件"
		else
			echo "[diy] 警告：稀疏检出未得到 libffi 目录"
		fi
	else
		echo "[diy] 警告：克隆 immortalwrt 失败，glib2 可能仍会编译失败"
	fi
	rm -rf /tmp/iw-src
fi

# ===== 可执行位修复 =====
# files/ 下的脚本通过 GitHub API 推送时执行位会丢失（一律 100644），
# 而 uci-defaults 需要可执行才会被 /etc/init.d/boot 执行。
if [ -d files/etc/uci-defaults ]; then
	chmod +x files/etc/uci-defaults/* 2>/dev/null
	echo "[diy] uci-defaults 可执行位已修复: $(ls files/etc/uci-defaults 2>/dev/null | tr '\n' ' ')"
fi
if [ -d files/usr/bin ]; then
	chmod +x files/usr/bin/ha-* 2>/dev/null
fi

# ===== 第三方包下载哈希修正：speedtest-web =====
# 现象：构建在 download 与 compile 两处各中断一次，报
#   Hash mismatch for file speedtest-web-1.1.5.tar.zst:
#   expected 63dad14c..., got aff79406...
# 原因：该包用 git 协议（PKG_SOURCE_PROTO:=git）从 ZeaKyX/speedtest-go
# 取固定 commit，其 PKG_MIRROR_HASH 是旧构建环境执行
#   git archive（应用 .gitattributes 规则）+ zstd --ultra -20
# 之后算出的 sha256。上游仓库已发生重定向，.gitattributes 的变化会改变
# archive 的输出内容，于是同一 commit 也算不出同一个哈希。
# 处理：改为官方支持的 skip。include/download.mk 中有放行分支：
#   [ "$file_hash" = "$(MIRROR_HASH)" ] || [ "$(MIRROR_HASH)" = "skip" ]
# 源码内容仍由 PKG_SOURCE_VERSION 固定的 commit 保证（内容寻址），
# 不影响可验证性。
for _mk in feeds/smpackage/speedtest-web/Makefile \
           package/feeds/smpackage/speedtest-web/Makefile; do
	[ -f "$_mk" ] || continue
	sed -i 's/^PKG_MIRROR_HASH:=.*/PKG_MIRROR_HASH:=skip/' "$_mk"
	echo "[diy] speedtest-web 哈希校验已跳过: $(grep '^PKG_MIRROR_HASH' "$_mk" | head -1)"
done

# ===== speedtest-web 的 upx 压缩禁用（双保险） =====
# 现象：compile 阶段 Error 127
#   /mnt/openwrt/staging_dir/host/bin/upx --lzma --best ...
#   bash: /mnt/openwrt/staging_dir/host/bin/upx: No such file or directory
# 原因：SPEEDTEST_WEB_COMPRESS_UPX 默认 y，构建机没有 upx host 工具。
# 处理：把 upx 调用替换为 /bin/true（无操作），配置里同时显式关闭该符号。
for _mk in feeds/smpackage/speedtest-web/Makefile \
           package/feeds/smpackage/speedtest-web/Makefile; do
	[ -f "$_mk" ] || continue
	sed -i 's|/bin/upx --lzma --best|/bin/true|' "$_mk"
	echo "[diy] speedtest-web upx 压缩已禁用: $(grep -c '/bin/true' "$_mk") 处"
done
