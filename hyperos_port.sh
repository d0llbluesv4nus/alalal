#!/bin/bash
set -e

#################################
# НАСТРОЙКИ
#################################
DEVICE_CODENAME="alioth"
DPI_VALUE="440"

# ПРОВЕРЬ ССЫЛКИ ПЕРЕД ЗАПУСКОМ!
STOCK_URL="https://bn.d.miui.com/OS1.0.3.0.TKHMIXM/miui_ALIOTHGlobal_OS1.0.3.0.TKHMIXM_57a88631b9_13.0.zip"
DONOR_URL="https://bn.d.miui.com/OS3.0.2.0.WMCCNXM/fuxi-ota_full-OS3.0.2.0.WMCCNXM-user-16.0-88aad63558.zip"

WORKDIR="$PWD/work"
TOOLS="$WORKDIR/tools"
# Добавляем tools в PATH, чтобы скрипт видел скачанные утилиты
export PATH="$TOOLS:$PATH"

#################################
# ФУНКЦИЯ БЕЗОПАСНОГО ВЫХОДА (TRAP)
#################################
# Это спасет тебя, если скрипт вылетит с ошибкой. 
# Он сам размонтирует образы, чтобы не блокировать файлы.
cleanup() {
    echo ""
    echo "⚠️  Скрипт завершен или прерван. Выполняем очистку..."
    # Убиваем фоновый обновитель sudo
    kill "$SUDO_PID" 2>/dev/null || true
    
    # Пытаемся размонтировать всё, что могли забыть
    if [ -d "$WORKDIR" ]; then
        sudo umount "$WORKDIR"/stock/super/* 2>/dev/null || true
        sudo umount "$WORKDIR"/donor/super/* 2>/dev/null || true
    fi
    echo "✅ Очистка завершена."
}
trap cleanup EXIT INT TERM

#################################
# SUDO KEEP-ALIVE
#################################
# Запрашиваем пароль один раз в начале
sudo -v
# Обновляем таймер sudo в фоне, пока скрипт работает
( while true; do sudo -v; sleep 60; done; ) &
SUDO_PID=$!

#################################
# 0. ОЧИСТКА МЕСТА
#################################
echo "[0] Подготовка рабочего пространства..."
# sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc || true
sudo apt clean
# Создаем папки заранее
mkdir -p "$WORKDIR" "$TOOLS"

#################################
# 1. СИСТЕМНЫЕ ЗАВИСИМОСТИ
#################################
echo "[1] Установка системных пакетов..."
sudo apt update
sudo apt install -y \
  unzip lz4 tar \
  android-sdk-libsparse-utils \
  xmlstarlet e2fsprogs \
  aria2 wget python3

#################################
# 2. ЗАГРУЗКА ИНСТРУМЕНТОВ
#################################
echo "[2] Проверка и загрузка утилит..."
mkdir -p "$TOOLS"
cd "$TOOLS"

# 2.1 payload-dumper-go
if [ ! -f payload-dumper-go ]; then
    echo "   -> Скачивание payload-dumper-go..."
    wget -q -O pd.tar.gz https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz
    mkdir -p tmp_pd && tar -zxf pd.tar.gz -C tmp_pd
    find tmp_pd -type f -name "payload-dumper-go*" -exec mv {} ./payload-dumper-go \;
    rm -rf pd.tar.gz tmp_pd
    chmod +x payload-dumper-go
    echo "   ✅ payload-dumper-go готов."
fi

# 2.2 make_ext4fs (Используем надежное зеркало)
if [ ! -f make_ext4fs ]; then
    echo "   -> Скачивание make_ext4fs..."
    # Пытаемся скачать из надежного источника (утилиты для сборки Android)
    wget -q --show-progress -O make_ext4fs https://github.com/carlitoxx-pro/AnyKernel3/raw/master/tools/make_ext4fs || \
    wget -q --show-progress -O make_ext4fs https://raw.githubusercontent.com/skylot/jadx/master/scripts/make_ext4fs
    
    if [ ! -s make_ext4fs ]; then
        echo "❌ Ошибка: Не удалось скачать make_ext4fs. Ссылки недоступны."
        exit 1
    fi
    chmod +x make_ext4fs
    echo "   ✅ make_ext4fs готов."
fi

# 2.3 lpunpack / lpmake
if [ ! -f lpunpack ] || [ ! -f lpmake ]; then
    echo "   -> Скачивание lpunpack/lpmake..."
    # Прямые ссылки на стабильные бинарники
    wget -q -O lpunpack https://github.com/unix3dgforce/lpunpack_lpmake/raw/master/bin/lpunpack
    wget -q -O lpmake https://github.com/unix3dgforce/lpunpack_lpmake/raw/master/bin/lpmake
    chmod +x lpunpack lpmake
    echo "   ✅ lpunpack/lpmake готовы."
fi
cd - > /dev/null

#################################
# 3. СКАЧИВАНИЕ ПРОШИВОК
#################################
mkdir -p "$WORKDIR"/{stock,donor}

download_fw () {
  NAME=$1
  URL=$2
  ZIP="$WORKDIR/$NAME.zip"

  echo "[3] Обработка $NAME..."
  
  if [ -f "$ZIP" ]; then
      echo "   ZIP файл уже существует, пропускаем скачивание."
  else
      echo "   Скачивание $NAME..."
      aria2c --file-allocation=trunc --allow-overwrite=true -x 4 -s 4 \
        -o "$(basename "$ZIP")" -d "$(dirname "$ZIP")" "$URL"
  fi

  if ! unzip -t "$ZIP" >/dev/null 2>&1; then
    echo "❌ $NAME: Битая ссылка или файл."
    exit 1
  fi

  # Распаковываем только если папка пуста
  if [ -z "$(ls -A "$WORKDIR/$NAME" 2>/dev/null)" ]; then
      echo "   Распаковка ZIP..."
      unzip -q "$ZIP" -d "$WORKDIR/$NAME"
  fi
}

download_fw stock "$STOCK_URL"
download_fw donor "$DONOR_URL"

#################################
# 4. ИЗВЛЕЧЕНИЕ SUPER.IMG
#################################
extract_super () {
  NAME=$1
  DIR="$WORKDIR/$NAME"
  mkdir -p "$DIR/images"

  if [ -f "$DIR/images/super.img" ]; then
      return
  fi

  if [ -f "$DIR/payload.bin" ]; then
    echo "[4] Извлечение payload.bin для $NAME..."
    payload-dumper-go -o "$DIR/images" "$DIR/payload.bin" >/dev/null
  fi
  
  # Проверка результата
  if [ ! -f "$DIR/images/super.img" ]; then
      # Иногда payload dumper не переименовывает super, ищем самый большой файл
      BIGGEST=$(find "$DIR/images" -type f -printf "%s\t%p\n" | sort -n | tail -1 | cut -f2)
      if [[ "$BIGGEST" == *"super"* ]]; then
          echo "⚠️  super.img не найден явно, но найден $(basename "$BIGGEST"). Переименовываем..."
          mv "$BIGGEST" "$DIR/images/super.img"
      else
          echo "❌ Ошибка: super.img не найден в $NAME"
          exit 1
      fi
  fi
}

extract_super stock
extract_super donor

#################################
# 5. РАСПАКОВКА SUPER.IMG
#################################
for TYPE in stock donor; do
  echo "[5] Распаковка super раздела ($TYPE)..."
  if [ ! -d "$WORKDIR/$TYPE/super" ]; then
      # Конвертируем sparse -> raw
      simg2img "$WORKDIR/$TYPE/images/super.img" "$WORKDIR/$TYPE/super.raw.img" || cp "$WORKDIR/$TYPE/images/super.img" "$WORKDIR/$TYPE/super.raw.img"
      
      mkdir -p "$WORKDIR/$TYPE/super"
      lpunpack "$WORKDIR/$TYPE/super.raw.img" "$WORKDIR/$TYPE/super"
      
      # Удаляем raw файл (он огромный)
      rm "$WORKDIR/$TYPE/super.raw.img"
  fi
done

#################################
# 6. МОНТИРОВАНИЕ IMG
#################################
mount_img () {
  IMG=$1
  DIR=${IMG%.img}
  
  if mountpoint -q "$DIR"; then return; fi
  
  mkdir -p "$DIR"
  # Монтируем. Важно: Stock монтируем RO (чтение), Donor RW (запись не нужна, но скрипт может требовать)
  # Для безопасности исходников используем RO, если скрипт не пишет ПРЯМО В НИХ.
  # Твой скрипт копирует ИЗ stock В donor.
  sudo mount -o loop "$IMG" "$DIR"
}

echo "[6] Монтирование разделов..."
for i in "$WORKDIR/stock/super/"*.img; do mount_img "$i"; done
for i in "$WORKDIR/donor/super/"*.img; do mount_img "$i"; done

#################################
# 7 - 14. МОДИФИКАЦИЯ (ТВОЯ ЛОГИКА)
#################################
echo "[7-14] Применение патчей..."

# 7. device_features
sudo cp -r "$WORKDIR/stock/super/product/etc/device_features/"* \
         "$WORKDIR/donor/super/product/etc/device_features/"

# XML Fix
TARGET_XML=$(ls "$WORKDIR/donor/super/product/etc/device_features/"*.xml 2>/dev/null | head -n 1)
if [ -n "$TARGET_XML" ]; then
    sudo xmlstarlet ed -L \
    -s "/resources" -t elem -n "bool" -v "true" \
    -i "/resources/bool[last()]" -t attr -n "name" -v "support_aod_fullscreen" \
    "$TARGET_XML"
fi

# 8. displayconfig
sudo cp -r "$WORKDIR/stock/super/product/etc/displayconfig/"* \
         "$WORKDIR/donor/super/product/etc/displayconfig/"

# 9. build.prop
PROP="$WORKDIR/donor/super/product/etc/build.prop"
# Используем временный файл, чтобы sed не ругался на права
sudo cp "$PROP" "$PROP.tmp"
sudo chmod 777 "$PROP.tmp"
sed -i "/persist.miui.density_v2/d;/ro.sf.lcd_density/d;/ro.product.product.name/d" "$PROP.tmp"
echo "persist.miui.density_v2=$DPI_VALUE" >> "$PROP.tmp"
echo "ro.sf.lcd_density=$DPI_VALUE" >> "$PROP.tmp"
echo "ro.product.product.name=$DEVICE_CODENAME" >> "$PROP.tmp"
sudo mv "$PROP.tmp" "$PROP"
sudo chown root:root "$PROP"

# 10. Biometrics
sudo cp -r "$WORKDIR/stock/super/product/app/"*Biometrics* \
         "$WORKDIR/donor/super/product/app/" 2>/dev/null || echo "   Biometrics пропущен (не найден)"

# 11. Pangu
sudo mv "$WORKDIR/donor/super/product/pangu/system/"* \
        "$WORKDIR/donor/super/product/app/" 2>/dev/null || true
sudo mv "$WORKDIR/donor/super/product/pangu/framework/"* \
        "$WORKDIR/donor/super/product/framework/" 2>/dev/null || true

# 12. VNDK
sudo cp "$WORKDIR/stock/super/system_ext/apex/"com.android.vndk.v30*.apex \
        "$WORKDIR/donor/super/system_ext/apex/" 2>/dev/null || true

# 13. mi_ext prop
MI_EXT_PROP="$WORKDIR/donor/super/mi_ext/etc/build.prop"
if [ -f "$MI_EXT_PROP" ]; then
    sudo sed -i "/ro.product.mod_device/d" "$MI_EXT_PROP"
    echo "ro.product.mod_device=$DEVICE_CODENAME" | sudo tee -a "$MI_EXT_PROP" >/dev/null
fi

# 14. Overlays
for o in AospFrameworkResOverlay.apk DevicesAndroidOverlay.apk DevicesOverlay.apk MiuiFrameworkResOverlay.apk; do
  if [ -f "$WORKDIR/stock/super/product/overlay/$o" ]; then
      sudo cp "$WORKDIR/stock/super/product/overlay/$o" "$WORKDIR/donor/super/product/overlay/"
  fi
done

#################################
# 15. РАЗМОНТИРОВАНИЕ
#################################
echo "[15] Размонтирование..."
sudo umount "$WORKDIR"/stock/super/* 2>/dev/null || true
sudo umount "$WORKDIR"/donor/super/* 2>/dev/null || true

#################################
# 16. СБОРКА ОБРАЗОВ
#################################
echo "[16] Пересборка разделов в IMG..."
cd "$WORKDIR"
mkdir -p out
cd out

# Увеличил размер до 6G (6144M), так как 4G часто мало для HyperOS.
# make_ext4fs создает sparse image, поэтому файл на диске будет маленьким,
# но система будет думать, что раздел на 6ГБ.
IMG_SIZE="6144M"

# Функция для сборки, чтобы не писать одно и то же
build_img() {
    NAME=$1
    SRC_DIR=$2
    if [ -d "$SRC_DIR" ]; then
        echo "   Сборка $NAME.img..."
        # -L = метка, -l = размер, -a = точка монтирования (важно для Android)
        sudo "$TOOLS/make_ext4fs" -T -1 -S "$SRC_DIR/file_contexts" -L "$NAME" -l "$IMG_SIZE" -a "$NAME" "$NAME.img" "$SRC_DIR" 2>/dev/null || \
        sudo "$TOOLS/make_ext4fs" -T -1 -L "$NAME" -l "$IMG_SIZE" -a "$NAME" "$NAME.img" "$SRC_DIR"
        
        # Меняем права на файл, чтобы lpmake мог его читать
        sudo chown $USER:$USER "$NAME.img"
    fi
}

# Stock нам нужен только для vendor/odm/dlkm, если мы берем их из стока?
# В твоем скрипте vendor создается из stock, а system из donor.
build_img vendor        "$WORKDIR/stock/super/vendor"
build_img odm           "$WORKDIR/stock/super/odm"
build_img system_dlkm   "$WORKDIR/stock/super/system_dlkm"
build_img vendor_dlkm   "$WORKDIR/stock/super/vendor_dlkm"

build_img system        "$WORKDIR/donor/super/system"
build_img product       "$WORKDIR/donor/super/product"
build_img system_ext    "$WORKDIR/donor/super/system_ext"
build_img mi_ext        "$WORKDIR/donor/super/mi_ext"

echo "[*] Упаковка в super.img..."
# Динамически формируем команду lpmake, добавляя только существующие файлы
LPMAKE_ARGS="--metadata-size 65536 --super-name super --device super:9663676416 --group main:9663676416"

for part in system product system_ext mi_ext vendor odm system_dlkm vendor_dlkm; do
    if [ -f "$part.img" ]; then
        SIZE=$(stat -c%s "$part.img")
        LPMAKE_ARGS="$LPMAKE_ARGS --partition $part:readonly:$SIZE:main --image $part=$part.img"
    fi
done

lpmake $LPMAKE_ARGS --output super.img

echo ""
echo "🎉 ГОТОВО! Файл находится здесь: $PWD/super.img"
