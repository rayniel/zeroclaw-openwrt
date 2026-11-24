include $(TOPDIR)/rules.mk

PKG_NAME:=zeroclaw-openwrt
PKG_VERSION:=0.9.0
PKG_RELEASE:=2
PKG_LICENSE:=MIT
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/zeroclaw-openwrt
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=ZeroClaw MMC launcher and procd service
  DEPENDS:=+ca-bundle
endef

define Package/zeroclaw-openwrt/description
  Small integration package only. Install the separately built ARMv7
  binary on mounted MMC storage before enabling it. FAT-backed storage
  can use an explicitly prepared ext4 loop image for config and data.
endef

define Package/zeroclaw-openwrt/conffiles
/etc/config/zeroclaw
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/zeroclaw-openwrt/install
	$(INSTALL_DIR) $(1)/usr/bin $(1)/usr/libexec $(1)/etc/init.d $(1)/etc/config
	$(INSTALL_BIN) ./files/zeroclaw $(1)/usr/bin/zeroclaw
	$(INSTALL_DATA) ./files/zeroclaw-common.sh $(1)/usr/libexec/zeroclaw-common.sh
	$(INSTALL_BIN) ./files/zeroclaw.init $(1)/etc/init.d/zeroclaw
	$(INSTALL_CONF) ./files/zeroclaw.config $(1)/etc/config/zeroclaw
endef

$(eval $(call BuildPackage,zeroclaw-openwrt))
