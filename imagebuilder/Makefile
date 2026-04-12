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
#   AUTH_KEY  — Headscale auth key (опционально, для dev)
#   START     — начальный номер для batch (по умолчанию 1)
#   COUNT     — количество образов для batch (по умолчанию 10)
#
# Wi-Fi credentials вводит ЮЗЕР через CGI setup page, не оператор.

SHELL := /bin/sh

DOCKER_IMAGE := bridgewrt-builder
OUTPUT_DIR   := $(CURDIR)/output

# Параметры сборки
PROFILE  ?=
BOX_ID   ?= TEMPLATE
VARIANT  ?= production
AUTH_KEY ?=
WIFI_SSID ?=
WIFI_PASS ?=
START    ?= 1
COUNT    ?= 10

# --- Таргеты ---

# SD-карта для прошивки (автоопределение или задать вручную: SDCARD=/dev/sdX)
SDCARD ?=

.PHONY: image batch clean docker-build flash test qemu-test qemu-dev help ready

test:
	@echo "=== L1: Smoke Test ==="
	@sh scripts/smoke-test.sh
	@echo ""
	@echo "=== L2: Integration Test (Docker) ==="
	@docker build -t bridgewrt-test -f test/Dockerfile . 2>&1 | tail -3
	@docker run --rm --privileged bridgewrt-test

qemu-test:
	@echo "=== L3: QEMU Boot Test ==="
	@echo "Сборка образа armsr/armv8 + запуск в QEMU..."
	@echo "(первый запуск ~5мин: скачивание Image Builder + сборка)"
	@echo ""
	docker build -t bridgewrt-qemu-test -f test/qemu/Dockerfile .
	docker run --rm --privileged --device /dev/kvm:/dev/kvm bridgewrt-qemu-test

qemu-dev:
	@echo "=== BridgeBox Dev Sandbox ==="
	@echo "Кросс-компиляция Rust бинарей..."
	@sh test/qemu-dev/build-binaries.sh
	@echo ""
	@echo "Сборка Docker образа (первый запуск ~5 мин)..."
	docker build -t bridgewrt-qemu-dev -f test/qemu-dev/Dockerfile .
	@echo ""
	@echo "Запуск QEMU dev sandbox..."
	docker run -it --rm \
		--privileged \
		--cap-add=NET_ADMIN \
		--device /dev/kvm:/dev/kvm \
		--device /dev/net/tun:/dev/net/tun \
		-p 9999:9999 \
		-p 2222:2222 \
		bridgewrt-qemu-dev

help:
	@echo "BridgeWRT Image Builder"
	@echo ""
	@echo "Таргеты:"
	@echo "  make docker-build                      — собрать Docker образ (один раз)"
	@echo "  make image PROFILE=... BOX_ID=BB-001   — собрать один образ"
	@echo "  make batch PROFILE=... COUNT=10         — собрать пакет образов"
	@echo "  make flash SDCARD=/dev/sdX              — прошить SD-карту (последний образ)"
	@echo "  make qemu-test                          — L3: загрузка в QEMU + проверки"
	@echo "  make qemu-dev                           — dev sandbox: коробка на localhost:9999"
	@echo "  make clean                              — очистить output/"
	@echo ""
	@echo "Профили:"
	@echo "  friendlyarm_nanopi-r2s   — NanoPi R2S (512MB, Lite)"
	@echo "  friendlyarm_nanopi-r3s   — NanoPi R3S (2GB, Pro)"
	@echo ""
	@echo "Варианты:"
	@echo "  production (по умолчанию) — минимальный размер"
	@echo "  dev                       — с tcpdump для отладки"

docker-build:
	@echo "=== Сборка Docker образа ==="
	docker build --no-cache -t $(DOCKER_IMAGE) .

image:
	@if [ -z "$(PROFILE)" ]; then echo "Ошибка: PROFILE не задан" >&2; exit 1; fi
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
		$(if $(AUTH_KEY),AUTH_KEY="$(AUTH_KEY)") \
		$(if $(WIFI_SSID),WIFI_SSID="$(WIFI_SSID)") \
		$(if $(WIFI_PASS),WIFI_PASS="$(WIFI_PASS)")

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
	echo "Обнуляем первые 1GB (чистый старт, включая overlay)..."; \
	sudo dd if=/dev/zero of=$(SDCARD) bs=4M count=256 status=progress conv=fsync 2>&1; \
	echo "Записываем образ..."; \
	zcat "$$IMGFILE" | sudo dd of=$(SDCARD) bs=4M status=progress conv=fsync 2>&1; \
	sudo sync; \
	echo ""; \
	echo "=== Готово. Вставляй SD в коробку. ==="


ready:
	@echo "=== Готовим коробку к отправке ==="
	@echo ""
	@echo "--- 1/3: Smoke test ---"
	@sh scripts/smoke-test.sh
	@echo ""
	@echo "--- 2/3: Сборка образа ---"
	@$(MAKE) image PROFILE="$(PROFILE)"
	@echo ""
	@echo "--- 3/3: Проверка образа ---"
	@IMGFILE=$$(ls -t "$(OUTPUT_DIR)"/bridgewrt-*.img.gz 2>/dev/null | head -1); \
	if [ -z "$$IMGFILE" ]; then echo "ОШИБКА: образ не найден" >&2; exit 1; fi; \
	echo "  Образ: $$IMGFILE"; \
	echo "  Размер: $$(du -h "$$IMGFILE" | cut -f1)"; \
	echo ""; \
	echo "  Проверяем что wpa.conf НЕ вшит..."; \
	if zcat "$$IMGFILE" | strings | grep -q "WIFI_SSID\|wpa_supplicant\|key_mgmt=WPA" 2>/dev/null; then \
		echo "  ОШИБКА: wpa.conf вшит в образ!" >&2; exit 1; \
	fi; \
	echo "  ✓ wpa.conf не вшит — юзер введёт через CGI"; \
	echo ""; \
	echo "=== Коробка готова к отправке. make flash SDCARD=/dev/sdX ==="

clean:
	@echo "Очистка output/..."
	@rm -rf "$(OUTPUT_DIR)"
	@echo "Готово"
