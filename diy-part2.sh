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

# ===== 补充：不在官方 feed / small-package 中的三个插件（按用户清单要求） =====
# luci-app-temp-status：gSpotx2f 上游，取 lkiuyu 的适配版
git clone --depth 1 https://github.com/lkiuyu/luci-app-temp-status package/luci-app-temp-status || true
# luci-app-modeminfo：4IceG 上游，依赖 comgt（feed 内已有）
git clone --depth 1 https://github.com/4IceG/luci-app-modeminfo package/luci-app-modeminfo || true
# luci-app-atinout + atinout 命令行工具：仓库根目录下含两个包，整体克隆
git clone --depth 1 https://github.com/4IceG/luci-app-atinout package/atinout-src || true

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
