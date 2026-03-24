# BridgeBox Image Builder — Makefile
#
# Сборка готовых образов OpenWrt для NanoPi R2S/R3S
#
# Использование:
#   make image PROFILE=friendlyarm_nanopi-r3s BOX_ID=BB-001
#   make image PROFILE=friendlyarm_nanopi-r3s BOX_ID=BB-001 VARIANT=dev
#   make batch START=1 COUNT=10 PROFILE=friendlyarm_nanopi-r3s
#   make clean
#
# Параметры:
#   PROFILE   — профиль устройства (обязательный)
#   BOX_ID    — уникальный ID коробки (обязательный для image)
#   VARIANT   — production (по умолчанию) или dev
#   AUTH_KEY  — Headscale auth key (опционально)
#   START     — начальный номер для batch (по умолчанию 1)
#   COUNT     — количество образов для batch (по умолчанию 10)

SHELL := /bin/sh

# OpenWrt Image Builder
OPENWRT_VERSION := 25.12.0-rc1
OPENWRT_TARGET  := rockchip/armv8
OPENWRT_URL_BASE := https://downloads.openwrt.org/releases/$(OPENWRT_VERSION)/targets/$(subst /,-,$(OPENWRT_TARGET))

IB_DIR    := $(CURDIR)/openwrt-imagebuilder
IB_TAR    := $(IB_DIR).tar.zst
OUTPUT_DIR := $(CURDIR)/output

# Параметры сборки
PROFILE  ?=
BOX_ID   ?=
VARIANT  ?= production
AUTH_KEY ?=
START    ?= 1
COUNT    ?= 10

# Пакеты — базовый набор
PACKAGES_BASE := \
	tailscale \
	wpa-supplicant \
	kmod-br-netfilter \
	kmod-nft-queue \
	kmod-rtl8xxxu \
	rtl8188eu-firmware \
	iw \
	-dnsmasq \
	-firewall4 \
	-odhcpd-ipv6only

# Пакеты — dev добавляет LuCI и tcpdump
PACKAGES_DEV := \
	luci \
	luci-ssl \
	tcpdump

# Пакеты — production убирает LuCI
PACKAGES_PRODUCTION := \
	-luci \
	-luci-ssl

# Включаем профиль устройства (если задан)
ifneq ($(PROFILE),)
-include profiles/$(subst friendlyarm_nanopi-,,$(PROFILE)).mk
endif

# Итоговый список пакетов
ifeq ($(VARIANT),dev)
PACKAGES := $(PACKAGES_BASE) $(PACKAGES_DEV)
else
PACKAGES := $(PACKAGES_BASE) $(PACKAGES_PRODUCTION)
endif

# --- Таргеты ---

.PHONY: image batch clean download help

help:
	@echo "BridgeBox Image Builder"
	@echo ""
	@echo "Таргеты:"
	@echo "  make download                          — скачать Image Builder"
	@echo "  make image PROFILE=... BOX_ID=BB-001   — собрать один образ"
	@echo "  make batch PROFILE=... COUNT=10         — собрать пакет образов"
	@echo "  make clean                              — очистить output/"
	@echo ""
	@echo "Профили:"
	@echo "  friendlyarm_nanopi-r2s   — NanoPi R2S (512MB, Lite)"
	@echo "  friendlyarm_nanopi-r3s   — NanoPi R3S (2GB, Pro)"
	@echo ""
	@echo "Варианты:"
	@echo "  production (по умолчанию) — без LuCI, минимальный размер"
	@echo "  dev                       — с LuCI + tcpdump"

download: $(IB_DIR)/Makefile

$(IB_DIR)/Makefile:
	@echo "=== Скачивание OpenWrt Image Builder ==="
	@sh scripts/build.sh download "$(OPENWRT_VERSION)" "$(OPENWRT_TARGET)"

image: $(IB_DIR)/Makefile
	@# Проверки
	@if [ -z "$(PROFILE)" ]; then echo "Ошибка: PROFILE не задан" >&2; exit 1; fi
	@if [ -z "$(BOX_ID)" ]; then echo "Ошибка: BOX_ID не задан" >&2; exit 1; fi
	@# Инжектим BOX_ID
	@sh scripts/inject-identity.sh "$(BOX_ID)" "$(AUTH_KEY)"
	@# Собираем
	@echo "=== Сборка образа: $(BOX_ID) ($(PROFILE), $(VARIANT)) ==="
	@mkdir -p "$(OUTPUT_DIR)"
	$(MAKE) -C "$(IB_DIR)" image \
		PROFILE="$(PROFILE)" \
		PACKAGES="$(PACKAGES)" \
		FILES="$(CURDIR)/files" \
		BIN_DIR="$(OUTPUT_DIR)"
	@# Переименовываем
	@IMGFILE=$$(ls "$(OUTPUT_DIR)"/*-$(PROFILE)-ext4-sysupgrade.img.gz 2>/dev/null | head -1); \
	if [ -n "$$IMGFILE" ]; then \
		NEWNAME="$(OUTPUT_DIR)/bridgebox-$(BOX_ID)-$(VARIANT)-$$(date +%Y%m%d).img.gz"; \
		mv "$$IMGFILE" "$$NEWNAME"; \
		echo ""; \
		echo "=== Готово: $$NEWNAME ==="; \
		echo "  Размер: $$(du -h "$$NEWNAME" | cut -f1)"; \
		echo "  BOX_ID: $(BOX_ID)"; \
	else \
		echo "Ошибка: образ не найден в $(OUTPUT_DIR)" >&2; exit 1; \
	fi

batch: $(IB_DIR)/Makefile
	@if [ -z "$(PROFILE)" ]; then echo "Ошибка: PROFILE не задан" >&2; exit 1; fi
	@sh scripts/gen-batch.sh "$(START)" "$(COUNT)" "$(PROFILE)" "$(VARIANT)" "$(AUTH_KEY)"

clean:
	@echo "Очистка output/..."
	@rm -rf "$(OUTPUT_DIR)"
	@# Восстанавливаем файл идентичности в шаблонное состояние
	@echo "TEMPLATE" > files/etc/bridgebox/box-id
	@rm -f files/etc/bridgebox/auth-key
	@echo "Готово"
