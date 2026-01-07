#!/bin/bash
set -e

#################################
# НАСТРОЙКИ (ШАГИ 1-2 ГАЙДА)
#################################
DEVICE_CODENAME="alioth"
DPI_VALUE="440"

# ПРОВЕРЬТЕ ССЫЛКИ ПЕРЕД ЗАПУСКОМ!
STOCK_URL="https://bn.d.miui.com/OS1.0.3.0.TKHMIXM/miui_ALIOTHGlobal_OS1.0.3.0.TKHMIXM_57a88631b9_13.0.zip"
DONOR_URL="https://bn.d.miui.com/OS3.0.2.0.WMCCNXM/fuxi-ota_full-OS3.0.2.0.WMCCNXM-user-16.0-88aad63558.zip"

WORKDIR="$PWD/work"
TOOLS="$WORKDIR/tools"
export PATH="$TOOLS:$PATH"

# Поддержание sudo (для GitHub Actions)
sudo -v
( while true; do sudo -v; sleep 60; done; ) &
SUDO_PID=$!

cleanup() {
    echo "Очистка..."
    kill "$SUDO_PID" 2>/dev/null || true
    sudo umount "$WORKDIR"/stock/super_extracted/* 2>/dev/null || true
    sudo umount "$WORKDIR"/donor/super_extracted/* 2>/dev/null || true
}
trap cleanup EXIT

#################################
# 1. ЗАВИСИМОСТИ И ИНСТРУМЕНТЫ
#################################
echo "[1] Установка инструментов..."
sudo apt update && sudo apt install -y unzip lz4 tar aria2 wget python3 xmlstarlet e2fsprogs android-sdk-libsparse-utils lib32z1

mkdir -p "$TOOLS"
cd "$TOOLS"

# payload-dumper-go (Исправлено перемещение)
if [ ! -f payload-dumper-go ]; then
    wget -q -O pd.tar.gz https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz
    tar -zxf pd.tar.gz
    # Ищем бинарник во вложенных папках и переносим без ошибок
    find . -type f -name "payload-dumper-go" -exec mv {} ./payload-dumper-go_tmp \;
    mv ./payload-dumper-go_tmp ./payload-dumper-go
    chmod +x payload-dumper-go
    rm -rf pd.tar.gz payload-dumper-go_1.2.2_linux_amd64
fi

# lpunpack/lpmake
wget -q -O lpunpack https://github.com/unix3dgforce/lpunpack_lpmake/raw/master/bin/lpunpack
wget -q -O lpmake https://github.com/unix3dgforce/lpunpack_lpmake/raw/master/bin/lpmake
chmod +x lpunpack lpmake
cd - > /dev/null

#################################
# 2. РАСПАКОВКА (ШАГ 1 ГАЙДА)
#################################
mkdir -p "$WORKDIR"/{stock,donor}

extract_fw() {
    NAME=$1; URL=$2; DIR="$WORKDIR/$NAME"
    echo "[*] Обработка $NAME..."
    [ -f "$WORKDIR/$NAME.zip" ] || aria2c -x 4 -s 4 -d "$WORKDIR" -o "$NAME.zip" "$URL"
    unzip -q "$WORKDIR/$NAME.zip" -d "$DIR"
    
    # Извлечение super.img
    payload-dumper-go -o "$DIR/images" "$DIR/payload.bin"
    simg2img "$DIR/images/super.img" "$DIR/super.raw.img" || cp "$DIR/images/super.img" "$DIR/super.raw.img"
    
    mkdir -p "$DIR/super_extracted"
    lpunpack "$DIR/super.raw.img" "$DIR/super_extracted"
    
    # Монтирование разделов
    for img in "$DIR/super_extracted/"*.img; do
        mnt="${img%.img}"
        mkdir -p "$mnt"
        sudo mount -o loop "$img" "$mnt"
    done
}

extract_fw stock "$STOCK_URL"
extract_fw donor "$DONOR_URL"

#################################
# 3. ПОРТИРОВАНИЕ (ШАГИ 2-13 ГАЙДА)
#################################
echo "[*] Применение модификаций по гайду..."

# Шаги 2-4: device_features и displayconfig
sudo cp -r "$WORKDIR/stock/super_extracted/product/etc/device_features/"* "$WORKDIR/donor/super_extracted/product/etc/device_features/"
sudo cp -r "$WORKDIR/stock/super_extracted/product/etc/displayconfig/"* "$WORKDIR/donor/super_extracted/product/etc/displayconfig/"

# Шаг 3: AOD Fullscreen
TARGET_XML=$(ls "$WORKDIR/donor/super_extracted/product/etc/device_features/"*.xml | head -n 1)
sudo xmlstarlet ed -L -s "/resources" -t elem -n "bool" -v "true" -i "/resources/bool[last()]" -t attr -n "name" -v "support_aod_fullscreen" "$TARGET_XML"

# Шаги 5, 6, 7: product build.prop
PROP_P="$WORKDIR/donor/super_extracted/product/etc/build.prop"
sudo sed -i "/persist.miui.density_v2/d;/ro.sf.lcd_density/d;/ro.product.product.name/d" "$PROP_P"
echo "persist.miui.density_v2=$DPI_VALUE" | sudo tee -a "$PROP_P"
echo "ro.sf.lcd_density=$DPI_VALUE" | sudo tee -a "$PROP_P"
echo "ro.product.product.name=$DEVICE_CODENAME" | sudo tee -a "$PROP_P"

# --- ШАГ 7: ВСТАВЬТЕ СЮДА СТРОКИ ИЗ product_build_prop.txt ---
echo "
# Ваши строки из шага 7 ниже:
" | sudo tee -a "$PROP_P"
# -------------------------------------------------------------

# Шаг 8: Biometrics
sudo cp -r "$WORKDIR/stock/super_extracted/product/app/"*Biometrics* "$WORKDIR/donor/super_extracted/product/app/" 2>/dev/null || true

# Шаг 9: Pangu
sudo mv "$WORKDIR/donor/super_extracted/product/pangu/system/"* "$WORKDIR/donor/super_extracted/product/app/" 2>/dev/null || true
sudo mv "$WORKDIR/donor/super_extracted/product/pangu/framework/"* "$WORKDIR/donor/super_extracted/product/framework/" 2>/dev/null || true

# Шаг 10: VNDK Apex
sudo cp "$WORKDIR/stock/super_extracted/system_ext/apex/"com.android.vndk.v30*.apex "$WORKDIR/donor/super_extracted/system_ext/apex/" 2>/dev/null || true

# --- ШАГ 11: ВСТАВЬТЕ СЮДА СТРОКИ ИЗ system_system_build_prop.txt ---
PROP_S="$WORKDIR/donor/super_extracted/system/system/build.prop"
echo "
# Ваши строки из шага 11 ниже:
" | sudo tee -a "$PROP_S"
# ------------------------------------------------------------------

# Шаг 12: mi_ext
PROP_M="$WORKDIR/donor/super_extracted/mi_ext/etc/build.prop"
sudo sed -i "/ro.product.mod_device/d" "$PROP_M"
echo "ro.product.mod_device=$DEVICE_CODENAME" | sudo tee -a "$PROP_M"

# Шаг 13: Overlays
for apk in AospFrameworkResOverlay.apk DevicesAndroidOverlay.apk DevicesOverlay.apk MiuiFrameworkResOverlay.apk; do
    [ -f "$WORKDIR/stock/super_extracted/product/overlay/$apk" ] && sudo cp "$WORKDIR/stock/super_extracted/product/overlay/$apk" "$WORKDIR/donor/super_extracted/product/overlay/"
done

#################################
# 4. СБОРКА (ШАГИ 14-15 ГАЙДА)
#################################
echo "[*] Сборка разделов..."
mkdir -p "$WORKDIR/out"

build_image() {
    NAME=$1; SRC=$2; OUT="$WORKDIR/out/$NAME.img"
    # Автоматический расчет размера (размер папки + 10% запаса)
    SIZE_KB=$(sudo du -sk "$SRC" | cut -f1)
    SIZE=$(( (SIZE_KB + (SIZE_KB/10)) * 1024 ))
    
    echo "   Упаковка $NAME.img (размер: $SIZE байт)"
    truncate -s $SIZE "$OUT"
    mkfs.ext4 -L "$NAME" -O ^has_journal "$OUT" >/dev/null
    sudo e2fsdroid -e -a "/$NAME" -f "$SRC" "$OUT"
    sudo chown $USER:$USER "$OUT"
}

# Шаг 14: Упаковка разделов
# Из Стока
for p in vendor odm system_dlkm vendor_dlkm; do
    build_image $p "$WORKDIR/stock/super_extracted/$p"
done
# Из Донора
for p in mi_ext system product system_ext; do
    build_image $p "$WORKDIR/donor/super_extracted/$p"
done

# Шаг 15: Сборка финального super.img
echo "[*] Финальная упаковка super.img..."
LP_ARGS="--metadata-size 65536 --super-name super --device super:9663676416 --group main:9663676416"
for img in "$WORKDIR/out/"*.img; do
    PART=$(basename "$img" .img)
    LP_ARGS="$LP_ARGS --partition $PART:readonly:$(stat -c%s "$img"):main --image $PART=$img"
done

lpmake $LP_ARGS --output "$WORKDIR/super_final.img"

echo "🎉 ГОТОВО! Ваш файл: $WORKDIR/super_final.img"
