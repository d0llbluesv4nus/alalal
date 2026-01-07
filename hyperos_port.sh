#!/bin/bash
set -e

########################
# НАСТРОЙКИ
########################
DEVICE_CODENAME="alioth"
DPI_VALUE="440"

STOCK_URL="https://cdnorg.d.miui.com/OS1.0.3.0.TKHMIXM/alioth_global_images_OS1.0.3.0.TKHMIXM_20240604.0000.00_13.0_global_af9c432b92.tgz"
DONOR_URL="https://cdnorg.d.miui.com/OS3.0.2.0.WMCCNXM/fuxi_images_OS3.0.2.0.WMCCNXM_20251127.0000.00_16.0_cn_f4799ae6de.tgz"

WORKDIR="$PWD/work"
TOOLS="$WORKDIR/tools"

########################
# 0. ОЧИСТКА МЕСТА (GitHub Actions)
########################
echo "[0] Очистка места"
sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc || true
sudo apt clean
df -h

########################
# 1. ЗАВИСИМОСТИ
########################
sudo apt update
sudo apt install -y \
  wget unzip lz4 simg2img img2simg \
  android-sdk-libsparse-utils \
  xmlstarlet e2fsprogs

########################
# 2. payload-dumper-go
########################
mkdir -p "$TOOLS"
cd "$TOOLS"
if [ ! -f payload-dumper-go ]; then
  wget -q https://github.com/ssut/payload-dumper-go/releases/latest/download/payload-dumper-go-linux-amd64
  chmod +x payload-dumper-go
fi
cd -

########################
# 3. СКАЧИВАНИЕ ПРОШИВОК
########################
mkdir -p "$WORKDIR"/{stock,donor}

download_fw () {
  NAME=$1
  URL=$2
  ZIP="$WORKDIR/$NAME.zip"

  echo "[*] Скачивание $NAME"
  wget -q --show-progress -O "$ZIP" "$URL"

  unzip -q "$ZIP" -d "$WORKDIR/$NAME"
}

download_fw stock "$STOCK_URL"
download_fw donor "$DONOR_URL"

########################
# 4. ИЗВЛЕЧЕНИЕ SUPER.IMG
########################
extract_super () {
  NAME=$1
  DIR="$WORKDIR/$NAME"

  mkdir -p "$DIR/images"

  if [ -f "$DIR/payload.bin" ]; then
    echo "[*] payload.bin найден ($NAME)"
    "$TOOLS/payload-dumper-go" -o "$DIR/images" "$DIR/payload.bin"
  fi

  if [ ! -f "$DIR/images/super.img" ]; then
    echo "❌ super.img не найден ($NAME)"
    exit 1
  fi
}

extract_super stock
extract_super donor

########################
# 5. РАСПАКОВКА SUPER.IMG
########################
for TYPE in stock donor; do
  simg2img "$WORKDIR/$TYPE/images/super.img" "$WORKDIR/$TYPE/super.raw.img"
  mkdir -p "$WORKDIR/$TYPE/super"
  lpunpack "$WORKDIR/$TYPE/super.raw.img" "$WORKDIR/$TYPE/super"
done

########################
# 6. МОНТИРОВАНИЕ IMG
########################
mount_img () {
  IMG=$1
  DIR=${IMG%.img}
  mkdir -p "$DIR"
  sudo mount -o loop "$IMG" "$DIR"
}

for i in "$WORKDIR/stock/super/"*.img; do mount_img "$i"; done
for i in "$WORKDIR/donor/super/"*.img; do mount_img "$i"; done

########################
# 7. device_features + AOD
########################
cp -r \
"$WORKDIR/stock/super/product/etc/device_features/"* \
"$WORKDIR/donor/super/product/etc/device_features/"

xmlstarlet ed -L \
-s "/resources" -t elem -n "bool" -v "true" \
-i "/resources/bool[last()]" -t attr -n "name" -v "support_aod_fullscreen" \
"$WORKDIR/donor/super/product/etc/device_features/"*.xml

########################
# 8. displayconfig
########################
cp -r \
"$WORKDIR/stock/super/product/etc/displayconfig/"* \
"$WORKDIR/donor/super/product/etc/displayconfig/"

########################
# 9. DPI + codename
########################
PROP="$WORKDIR/donor/super/product/etc/build.prop"

sed -i "/persist.miui.density_v2/d;/ro.sf.lcd_density/d;/ro.product.product.name/d" "$PROP"
echo "persist.miui.density_v2=$DPI_VALUE" >> "$PROP"
echo "ro.sf.lcd_density=$DPI_VALUE" >> "$PROP"
echo "ro.product.product.name=$DEVICE_CODENAME" >> "$PROP"

########################
# 10. Biometrics
########################
cp -r "$WORKDIR/stock/super/product/app/"*Biometrics* \
      "$WORKDIR/donor/super/product/app/" || true

########################
# 11. pangu → app / framework
########################
mv "$WORKDIR/donor/super/product/pangu/system/"* \
   "$WORKDIR/donor/super/product/app/" || true
mv "$WORKDIR/donor/super/product/pangu/framework/"* \
   "$WORKDIR/donor/super/product/framework/" || true

########################
# 12. vndk apex
########################
cp "$WORKDIR/stock/super/system_ext/apex/"com.android.vndk.v30*.apex \
   "$WORKDIR/donor/super/system_ext/apex/"

########################
# 13. mi_ext mod_device
########################
sed -i "/ro.product.mod_device/d" \
"$WORKDIR/donor/super/mi_ext/etc/build.prop"
echo "ro.product.mod_device=$DEVICE_CODENAME" \
>> "$WORKDIR/donor/super/mi_ext/etc/build.prop"

########################
# 14. overlay
########################
for o in AospFrameworkResOverlay.apk DevicesAndroidOverlay.apk DevicesOverlay.apk MiuiFrameworkResOverlay.apk; do
  cp "$WORKDIR/stock/super/product/overlay/$o" \
     "$WORKDIR/donor/super/product/overlay/"
done

########################
# 15. РАЗМОНТИРОВАНИЕ
########################
sudo umount "$WORKDIR"/{stock,donor}/super/* || true

########################
# 16. ПЕРЕУПАКОВКА + SUPER
########################
cd "$WORKDIR"
mkdir out && cd out

make_ext4fs -l 4G vendor.img        "$WORKDIR/stock/super/vendor"
make_ext4fs -l 4G odm.img           "$WORKDIR/stock/super/odm"
make_ext4fs -l 4G system_dlkm.img   "$WORKDIR/stock/super/system_dlkm"
make_ext4fs -l 4G vendor_dlkm.img   "$WORKDIR/stock/super/vendor_dlkm"

make_ext4fs -l 4G system.img        "$WORKDIR/donor/super/system"
make_ext4fs -l 4G product.img       "$WORKDIR/donor/super/product"
make_ext4fs -l 4G system_ext.img    "$WORKDIR/donor/super/system_ext"
make_ext4fs -l 4G mi_ext.img        "$WORKDIR/donor/super/mi_ext"

lpmake \
--metadata-size 65536 \
--super-name super \
--device super:9126805504 \
--group main:9126805504 \
--partition system:readonly:$(stat -c%s system.img):main \
--partition product:readonly:$(stat -c%s product.img):main \
--partition system_ext:readonly:$(stat -c%s system_ext.img):main \
--partition mi_ext:readonly:$(stat -c%s mi_ext.img):main \
--partition vendor:readonly:$(stat -c%s vendor.img):main \
--partition odm:readonly:$(stat -c%s odm.img):main \
--partition system_dlkm:readonly:$(stat -c%s system_dlkm.img):main \
--partition vendor_dlkm:readonly:$(stat -c%s vendor_dlkm.img):main \
--image system=system.img \
--image product=product.img \
--image system_ext=system_ext.img \
--image mi_ext=mi_ext.img \
--image vendor=vendor.img \
--image odm=odm.img \
--image system_dlkm=system_dlkm.img \
--image vendor_dlkm=vendor_dlkm.img \
--output super.img

echo "[✓] ГОТОВО: work/out/super.img"
