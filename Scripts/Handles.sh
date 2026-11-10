#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

FEEDS_PATH="./feeds"
PACKAGE_PATH="./package"

#修补命令统一入口：FIX <名称> <守卫目录> <命令...>
#守卫目录不存在时直接跳过，保证在 bash -e 下不中断
FIX() {
	local NAME=$1
	local GUARD=$2
	shift 2

	[ -d "$GUARD" ] || return 0

	echo " "
	if "$@"; then
		echo "$NAME has been fixed!"
	else
		echo "$NAME fix failed; continuing!"
	fi
}

#修改argon主题字体和颜色
FIX "theme-argon" "$PACKAGE_PATH/luci-theme-argon" sed -i \
	"s/primary '.*'/primary '#31a1a1'/g; s/'0.2'/'0.5'/g; s/'none'/'bing'/g; s/'600'/'normal'/g" \
	"$PACKAGE_PATH/luci-theme-argon/luci-app-argon-config/root/etc/config/argon"

#修改aurora菜单式样
FIX "theme-aurora" "$PACKAGE_PATH/luci-app-aurora-config" find \
	"$PACKAGE_PATH/luci-app-aurora-config/root/usr/share/aurora/" -type f -name '*.template' -exec sed -i \
	"s/nav_type '.*'/nav_type 'dropdown'/g; s/struct_radius_base '.*'/struct_radius_base '0.125rem'/g" {} +

#修改vantage进度条标签字体（anothaDev/luci-theme-vantage#52）
FIX "theme-vantage" "$PACKAGE_PATH/luci-theme-vantage" sed -i \
	-e '/^\/\* progress bars: thin track/,$ { /^\.cbi-progressbar::before {/,/^}/ { s/^[[:space:]]*font: 500 var(--fs-micro)\/1\.2 var(--mono);/\tfont: inherit; line-height: normal;/; } }' \
	"$PACKAGE_PATH/luci-theme-vantage/luci-theme-vantage/htdocs/luci-static/vantage/vantage.css"

#修改mini-diskmanager菜单位置
FIX "mini-diskmanager" "$PACKAGE_PATH/luci-app-mini-diskmanager" sed -i "s/services/system/g" \
	"$PACKAGE_PATH/luci-app-mini-diskmanager/luci-app-mini-diskmanager/root/usr/share/luci/menu.d/luci-app-mini-diskmanager.json"

#修改natmapt菜单位置
FIX "natmapt" "$PACKAGE_PATH/luci-app-natmapt" sed -i "s/network/services/g" \
	"$PACKAGE_PATH/luci-app-natmapt/root/usr/share/luci/menu.d/luci-app-natmap.json"

# ZN-M2 纯有线基底专属裁剪与数据面适配（CWD 为 ./wrt/）
if [[ "${WRT_CONFIG:-}" == "ZN-M2-WIFI-NO" ]]; then
	echo " "
	echo "Applying ZN-M2-WIFI-NO datapath & package trims..."

	# 1) 关闭 firewall4 默认 flow offloading（避免绕过 honk TC 钩子；保留 fullcone=1）
	F4_PATCH="./package/network/config/firewall4/patches/002-default-enable-fullcone.patch"
	if [ -f "$F4_PATCH" ]; then
		sed -i -E '/^\+[[:space:]]*option[[:space:]]+flow_offloading(_hw)?[[:space:]]+1$/ s/1$/0/' "$F4_PATCH"
		if grep -qE '^\+[[:space:]]*option[[:space:]]+flow_offloading(_hw)?[[:space:]]+1$' "$F4_PATCH"; then
			echo "!! ZN-M2-WIFI-NO: flow_offloading still enabled in $F4_PATCH" >&2
			exit 1
		fi
		echo "firewall4 patch: flow_offloading / flow_offloading_hw -> 0"
	else
		echo "!! ZN-M2-WIFI-NO: $F4_PATCH not found" >&2
		exit 1
	fi

	RT_JSON="./package/emortal/luci-app-router-tool/root/usr/share/router-tool/auto.json"
	if [ -f "$RT_JSON" ]; then
		sed -i 's/"flow_offloading": "1"/"flow_offloading": "0"/g; s/"flow_offloading_hw": "1"/"flow_offloading_hw": "0"/g' "$RT_JSON"
		echo "router-tool auto.json: offload defaults -> 0"
	fi

	for d in ./build_dir/target-*/firewall4-*; do
		[ -d "$d" ] || continue
		rm -rf "$d"
	done

	# 按完整词从 Makefile / target.mk 包列表中摘除指定包，并保持赋值符与续行符完整
	strip_make_pkgs() {
		local FILE=$1
		local VAR_RE=$2
		local PKG_RE=$3
		[ -f "$FILE" ] || return 0
		awk -v var_re="$VAR_RE" -v pkg_re="$PKG_RE" '
		BEGIN { in_var = 0 }
		{
			line = $0
			has_cont = (line ~ /\\[ \t]*$/)
			body = line
			trail = ""
			if (has_cont) {
				sub(/[ \t]*\\[ \t]*$/, "", body)
				trail = " \\"
			}
			is_assign = 0
			lhs = ""
			rhs = body
			if (!in_var && match(body, "^[ \t]*" var_re "[ \t]*([:+?]?=)")) {
				is_assign = 1
				lhs = substr(body, 1, RLENGTH)
				rhs = substr(body, RLENGTH + 1)
			}
			if (is_assign || in_var) {
				n = split(rhs, toks)
				kept = ""
				for (i = 1; i <= n; i++) {
					if (toks[i] ~ pkg_re) continue
					kept = (kept == "" ? toks[i] : kept " " toks[i])
				}
				if (is_assign) {
					if (kept != "" && trail != "") print lhs " " kept trail
					else if (kept != "") print lhs " " kept
					else if (trail != "") print lhs trail
					else print lhs
				} else {
					indent = ""
					if (match(body, /^[ \t]*/)) indent = substr(body, 1, RLENGTH)
					if (kept != "" && trail != "") print indent kept trail
					else if (kept != "") print indent kept
					else if (trail != "") print indent trail
					else print ""
				}
				in_var = has_cont
				next
			}
			print line
		}
		' "$FILE" > "$FILE.tmp" && mv -f "$FILE.tmp" "$FILE"
	}

	# 2) 摘除 kmod-nft-offload 的硬性来源（防止 DEFAULT_* / DEPENDS 反向拉回）
	strip_make_pkgs "./include/target.mk" 'DEFAULT_PACKAGES([.][A-Za-z0-9_]+)?' '^kmod-nft-offload$'
	if grep -v '^[[:space:]]*#' "./include/target.mk" | grep -qE '(^|[[:space:]:=+])kmod-nft-offload([[:space:]\\]|$)'; then
		echo "!! ZN-M2-WIFI-NO: kmod-nft-offload still present in ./include/target.mk" >&2
		exit 1
	fi

	FW4_MK=$(find ./package -maxdepth 4 -type d -name firewall4 2>/dev/null | head -n 1)
	if [ -n "$FW4_MK" ] && [ -f "$FW4_MK/Makefile" ]; then
		strip_make_pkgs "$FW4_MK/Makefile" 'DEPENDS' '^([+]|[+]?[A-Za-z0-9_]+:)?kmod-nft-offload$'
		if grep -v '^[[:space:]]*#' "$FW4_MK/Makefile" | grep -q '+kmod-nft-offload'; then
			echo "!! ZN-M2-WIFI-NO: +kmod-nft-offload still present in $FW4_MK/Makefile" >&2
			exit 1
		fi
		echo "firewall4/Makefile & include/target.mk: kmod-nft-offload removed"
	else
		echo "!! ZN-M2-WIFI-NO: firewall4/Makefile not found" >&2
		exit 1
	fi

	# 3) 从 qualcommax 默认包与设备包列表摘除 Wi-Fi、USB、NSS 固件/驱动、automount 及冗余存储工具
	#    （防止无提示 CONFIG_DEFAULT_* / DEPENDS 反向拉回 kmod-usb-*、kmod-fs-* 与 kmod-nss-wifi-drv）
	TRIM_PKGS_RE='^(kmod-ath.*|kmod-cfg80211|kmod-mac80211|ath10k-firmware-.*|ath11k-firmware-.*|ipq-wifi-.*|wpad(-.*)?|hostapd(-.*)?|iw|iwinfo|wireless-regdb|kmod-usb.*|kmod-nss-.*|nss-firmware(-.*)?|automount|e2fsprogs|f2fs-tools|losetup|kmod-fs-ext4|kmod-fs-f2fs|kmod-nft-offload)$'
	for MK in "./target/linux/qualcommax/Makefile" "./target/linux/qualcommax/ipq60xx/target.mk" "./target/linux/qualcommax/image/ipq60xx.mk"; do
		[ -f "$MK" ] || continue
		strip_make_pkgs "$MK" '(DEFAULT_PACKAGES([.][A-Za-z0-9_]+)?|DEVICE_PACKAGES)' "$TRIM_PKGS_RE"
		if grep -v '^[[:space:]]*#' "$MK" | grep -qE '(^|[[:space:]:=+])(kmod-nss-wifi-drv|nss-firmware(-ipq60xx)?|automount|e2fsprogs|f2fs-tools|losetup|kmod-fs-(ext4|f2fs))([[:space:]\\]|$)'; then
			echo "!! ZN-M2-WIFI-NO: unexpected trim target still present in $MK" >&2
			exit 1
		fi
		echo "Trimmed Wi-Fi/USB/NSS/automount default packages in $MK"
	done
fi
