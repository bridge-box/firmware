	# BridgeWRT Image Builder — Makefile
#
# Сборка готовых образов OpenWrt для NanoPi R2S/R3S через Docker.
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

DOCKER_IMAGE := bridgewrt-builder
OUTPUT_DIR   := $(CURDIR)/output

# Параметры сборки
PROFILE  ?=
BOX_ID   ?=
VARIANT  ?= production
AUTH_KEY ?=
START    ?= 1
COUNT    ?= 10

# --- Таргеты ---

# SD-карта для прошивки (автоопределение или задать вручную: SDCARD=/dev/sdX)
SDCARD ?=

.PHONY: image batch clean docker-build flash help

help:
	@echo "BridgeWRT Image Builder"
	@echo ""
	@echo "Таргеты:"
	@echo "  make docker-build                      — собрать Docker образ (один раз)"
	@echo "  make image PROFILE=... BOX_ID=BB-001   — собрать один образ"
	@echo "  make batch PROFILE=... COUNT=10         — собрать пакет образов"
	@echo "  make flash SDCARD=/dev/sdX              — прошить SD-карту (последний образ)"
	@echo "  make clean                              — очистить output/"
	@echo ""
	@echo "Профили:"
	@echo "  friendlyarm_nanopi-r2s   — NanoPi R2S (512MB, Lite)"
	@echo "  friendlyarm_nanopi-r3s   — NanoPi R3S (2GB, Pro)"
	@echo ""
	@echo "Варианты:"
	@echo "  production (по умолчанию) — без LuCI, минимальный размер"
	@echo "  dev                       — с LuCI + tcpdump"

docker-build:
	@echo "=== Сборка Docker образа ==="
	docker build --build-arg CACHEBUST=$(shell date +%s) -t $(DOCKER_IMAGE) .

image:
	@if [ -z "$(PROFILE)" ]; then echo "Ошибка: PROFILE не задан" >&2; exit 1; fi
	@if [ -z "$(BOX_ID)" ]; then echo "Ошибка: BOX_ID не задан" >&2; exit 1; fi
	@# Проверяем что Docker образ собран
	@docker image inspect $(DOCKER_IMAGE) >/dev/null 2>&1 || { \
		echo "Docker образ не найден, собираем..."; \
		$(MAKE) docker-build; \
	}
	@mkdir -p "$(OUTPUT_DIR)"
	docker run --rm --network=host \
		-v "$(OUTPUT_DIR)":/output \
		-e http_proxy=http://127.0.0.1:8888 \
		-e https_proxy=http://127.0.0.1:8888 \
		$(DOCKER_IMAGE) \
		PROFILE="$(PROFILE)" \
		BOX_ID="$(BOX_ID)" \
		VARIANT="$(VARIANT)" \
		$(if $(AUTH_KEY),AUTH_KEY="$(AUTH_KEY)")

batch:
	@if [ -z "$(PROFILE)" ]; then echo "Ошибка: PROFILE не задан" >&2; exit 1; fi
	@# Проверяем что Docker образ собран
	@docker image inspect $(DOCKER_IMAGE) >/dev/null 2>&1 || { \
		echo "Docker образ не найден, собираем..."; \
		$(MAKE) docker-build; \
	}
	@mkdir -p "$(OUTPUT_DIR)"
	@sh scripts/gen-batch.sh "$(START)" "$(COUNT)" "$(PROFILE)" "$(VARIANT)" "$(AUTH_KEY)"

flash:
	@# Прошивка SD-карты. Обнуляет диск перед записью чтобы ext4 не сохранял старое состояние.
	@if [ -z "$(SDCARD)" ]; then echo "Ошибка: SDCARD не задан (make flash SDCARD=/dev/sdX)" >&2; exit 1; fi
	@if [ ! -b "$(SDCARD)" ]; then echo "Ошибка: $(SDCARD) не блочное устройство" >&2; exit 1; fi
	@IMGFILE=$$(ls -t "$(OUTPUT_DIR)"/bridgewrt-*.img.gz 2>/dev/null | head -1); \
	if [ -z "$$IMGFILE" ]; then echo "Ошибка: нет образов в $(OUTPUT_DIR)/" >&2; exit 1; fi; \
	echo "=== Прошивка SD ==="; \
	echo "  Образ:  $$IMGFILE"; \
	echo "  Диск:   $(SDCARD)"; \
	echo ""; \
	echo "Отмонтируем партиции..."; \
	for p in $(SDCARD)*; do sudo umount "$$p" 2>/dev/null || true; done; \
	echo "Обнуляем первые 200MB (чистый старт)..."; \
	sudo dd if=/dev/zero of=$(SDCARD) bs=4M count=50 status=progress conv=fsync 2>&1; \
	echo "Записываем образ..."; \
	zcat "$$IMGFILE" | sudo dd of=$(SDCARD) bs=4M status=progress conv=fsync 2>&1; \
	sudo sync; \
	echo ""; \
	echo "=== Готово. Вставляй SD в коробку. ==="

clean:
	@echo "Очистка output/..."
	@rm -rf "$(OUTPUT_DIR)"
	@echo "Готово"
