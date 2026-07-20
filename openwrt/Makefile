#
# Copyright (C) 2026 mitmproxy contributors
#
# This is free software, licensed under the MIT License.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=mitmweb
# Version resolution (in order of precedence):
#   1. MITMWEB_VERSION env var — used by the GitHub Actions workflow.
#   2. mitmproxy/version.py — the actual source of truth (pyproject.toml
#      declares `dynamic = ["version"]`, so there is no literal version
#      to grep from there).
#   3. A hardcoded fallback so a stray standalone build still works.
ifdef MITMWEB_VERSION
  PKG_VERSION:=$(MITMWEB_VERSION)
else
  PKG_VERSION:=$(shell sed -nE 's/^VERSION\s*=\s*"([^"]+)".*/\1/p' $(CURDIR)/../mitmproxy/version.py 2>/dev/null | head -n1)
  PKG_VERSION:=$(if $(PKG_VERSION),$(PKG_VERSION),13.0.0.dev)
endif
PKG_RELEASE:=1

# No remote source. Everything in this package comes from the files in this
# directory + a single prebuilt ELF tarball placed in the SDK's dl/ by
# ./tools/build-mitmweb-musl.sh.
PKG_SOURCE:=
PKG_SOURCE_URL:=
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

# Map the SDK's $ARCH onto a tarball-arch-suffix. Override with
# `make ... MITMWEB_ARCH_HINT=<...>` for unusual targets.
MITMWEB_ARCH_HINT?=
ifeq ($(MITMWEB_ARCH_HINT),)
  ifeq ($(filter x86_64,$(ARCH)),x86_64)
    MITMWEB_ARCH_HINT:=x86_64
  endif
  ifeq ($(filter aarch64% arm64,$(ARCH)),aarch64)
    MITMWEB_ARCH_HINT:=aarch64
  endif
  ifeq ($(filter arm_cortex-a%,$(ARCH)),$(ARCH))
    MITMWEB_ARCH_HINT:=armv7
  endif
endif
ifeq ($(MITMWEB_ARCH_HINT),)
  $(warning MITMWEB_ARCH_HINT could not be auto-detected from ARCH=$(ARCH); defaulting to x86_64)
  MITMWEB_ARCH_HINT:=x86_64
endif

# OpenWrt's defaults take care of `Build/Prepare` (it `cp`s our tree into
# $(PKG_BUILD_DIR) when PKG_SOURCE is empty). Build/Compile just unpacks the
# prebuilt binary.
NO_CONFIGURE:=1
NO_INSTALL_STAGING:=1
NO_INSTALL_HOST:=1
NO_PYTHON:=1

include $(INCLUDE_DIR)/package.mk

TARBALL_NAME:=mitmweb-linux-musl-$(MITMWEB_ARCH_HINT)-$(PKG_VERSION).tar.xz
TARBALL_PATH:=$(DL_DIR)/$(TARBALL_NAME)

# ---------------------------------------------------------------------------
# Package: mitmweb — the daemon
# ---------------------------------------------------------------------------

define Package/mitmweb
  SECTION:=net
  CATEGORY:=Network
  TITLE:=mitmweb (man-in-the-middle proxy web UI)
  URL:=https://mitmproxy.org/
  DEPENDS:=+iptables-nft +kmod-nf-nat +kmod-ipt-nat +libc +libopenssl +zlib +ca-bundle +libpthread
  USERID:=mitmweb=472:mitmweb=472
endef

# OpenWrt's musl libc package installs /lib/libc.so + /lib/ld-musl-<arch>.so.1
# (a symlink to libc.so). It does NOT ship a file literally named
# libc.musl-<arch>.so.1, so the libc package's auto-generated .provides list
# omits that SONAME. musl's loader handles this at runtime (it falls back to
# libc.so when libc.musl-<arch>.so.1 isn't found), but `gen-dependencies.sh`
# requires the dep to be declared by some package we depend on. Declare it as
# an extra_provides of mitmweb so the dep check passes.
define Package/mitmweb/extra_provides
	echo libc.musl-x86_64.so.1
endef

define Package/mitmweb/description
  Self-contained mitmweb binary (built with PyInstaller against musl libc)
  that provides an interactive man-in-the-middle web UI for HTTP/1, HTTP/2,
  HTTP/3, and WebSocket traffic.

  This package only ships the daemon, init script, and UCI defaults. Install
  luci-app-mitmweb in addition for a web-based configuration UI.
endef

define Build/Compile
	@[ -f $(TARBALL_PATH) ] || { \
		echo "" >&2; \
		echo "ERROR: $(TARBALL_PATH) not found." >&2; \
		echo "       Build it first:" >&2; \
		echo "         ./tools/build-mitmweb-musl.sh --arch=$(MITMWEB_ARCH_HINT) --tag=v$(PKG_VERSION)" >&2; \
		echo "       then copy the resulting .tar.xz into your SDK's dl/ directory." >&2; \
		echo "       See openwrt/README.md for full instructions." >&2; \
		exit 1; \
	}
	$(TAR) -xJf $(TARBALL_PATH) -C $(PKG_BUILD_DIR)
endef

define Package/mitmweb/install
	# 1. PyInstaller-built mitmweb ELF
	$(INSTALL_DIR) $(1)/usr/lib/mitmweb
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/mitmweb-linux-musl-$(MITMWEB_ARCH_HINT)/mitmweb.bin \
		$(1)/usr/lib/mitmweb/mitmweb.bin

	# 2. /usr/bin/mitmweb wrapper (sets HOME so confdir resolution works)
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/mitmweb $(1)/usr/bin/mitmweb

	# 3. UCI defaults
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./files/etc/config/mitmweb $(1)/etc/config/mitmweb

	# 4. procd init script
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/mitmweb $(1)/etc/init.d/mitmweb

	# 5. Drop-ins
	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_DATA) ./files/etc/hotplug.d/iface/99-mitmweb-restart \
		$(1)/etc/hotplug.d/iface/99-mitmweb-restart

	$(INSTALL_DIR) $(1)/etc/logrotate.d
	$(INSTALL_DATA) ./files/etc/logrotate.d/mitmweb $(1)/etc/logrotate.d/mitmweb

	$(INSTALL_DIR) $(1)/etc/sysctl.d
	$(INSTALL_DATA) ./files/etc/sysctl.d/99-mitmweb.conf $(1)/etc/sysctl.d/99-mitmweb.conf

	$(INSTALL_DIR) $(1)/etc/rpcd/acl.d
	$(INSTALL_DATA) ./files/etc/rpcd/acl.d/50-mitmweb.json $(1)/etc/rpcd/acl.d/50-mitmweb.json

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/99-mitmweb-perms $(1)/etc/uci-defaults/99-mitmweb-perms

	# 6. confdir (empty; will be populated with CA files on first run)
	$(INSTALL_DIR) $(1)/etc/mitmweb
	chmod 0750 $(1)/etc/mitmweb
endef

define Package/mitmweb/postinst
#!/bin/sh
chown -R mitmweb:mitmweb /etc/mitmweb 2>/dev/null || true
chmod 0750 /etc/mitmweb
mkdir -p /var/log
touch /var/log/mitmweb.log
chown mitmweb:mitmweb /var/log/mitmweb.log
exit 0
endef

define Package/mitmweb/prerm
#!/bin/sh
/etc/init.d/mitmweb stop >/dev/null 2>&1 || true
/etc/init.d/mitmweb disable >/dev/null 2>&1 || true
exit 0
endef

# ---------------------------------------------------------------------------
# Package: luci-app-mitmweb — the LuCI web UI
# ---------------------------------------------------------------------------

define Package/luci-app-mitmweb
  SECTION:=luci
  CATEGORY:=LuCI
  TITLE:=LuCI support for mitmweb
  URL:=https://mitmproxy.org/
  DEPENDS:=+luci-base +mitmweb
  DEFAULT_DEPENDS:=+mitmweb
  PKGARCH:=all
endef

define Package/luci-app-mitmweb/description
  LuCI web interface for the OpenWrt-side configuration of mitmweb: service
  control, ports, transparent-proxy iptables integration, CA certificate
  download, and a link out to mitmweb's own web UI for full proxy features
  (filters, intercept rules, modify_*, map_*, block list, replay, etc.).

  This package deliberately does NOT duplicate anything mitmweb's own web UI
  already handles; it only covers router-side concerns (procd lifecycle,
  network integration, CA files, system logging).
endef

define Package/luci-app-mitmweb/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/mitmweb.lua \
		$(1)/usr/lib/lua/luci/controller/mitmweb.lua

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
	$(INSTALL_DATA) ./luasrc/model/cbi/mitmweb.lua \
		$(1)/usr/lib/lua/luci/model/cbi/mitmweb.lua

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/mitmweb
	$(INSTALL_DATA) ./luasrc/view/mitmweb/status.htm \
		$(1)/usr/lib/lua/luci/view/mitmweb/status.htm

	# Translations (LuCI loads .po or .lmo from /usr/lib/lua/luci/i18n/).
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n
	$(INSTALL_DATA) ./po/en/mitmweb.po    $(1)/usr/lib/lua/luci/i18n/mitmweb.en.po
	$(INSTALL_DATA) ./po/zh-cn/mitmweb.po $(1)/usr/lib/lua/luci/i18n/mitmweb.zh-cn.po
endef

# ---------------------------------------------------------------------------
# Package definitions.
# ---------------------------------------------------------------------------

$(eval $(call BuildPackage,mitmweb))
$(eval $(call BuildPackage,luci-app-mitmweb))
