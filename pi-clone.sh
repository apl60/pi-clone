#!/bin/bash

# --- KONFIGURATION ---
DEV_USB="/dev/sda"
DEV_SD="/dev/mmcblk0"
ROOT_SIZE="20G"  # Größe der System-Partition
MIN_DATA_SIZE=5  # Mindestgröße in GB, damit eine DATA-Partition erstellt wird

# Editierbare EXCLUDES (Ordner, die nicht mitkopiert werden sollen)
# Achtung: /* sorgt dafür, dass der leere Ordner als Mountpoint erhalten bleibt
MY_EXCLUDES="--exclude=/proc/* --exclude=/sys/* --exclude=/dev/* --exclude=/run/* --exclude=/tmp/* --exclude=/lost+found --exclude=/mnt/* --exclude=/media/*"

# --- INITIALISIERUNG ---
TARGET_INPUT=$(echo "$1" | tr '[:upper:]' '[:lower:]')
if [ "$TARGET_INPUT" == "usb" ]; then TARGET=$DEV_USB
elif [ "$TARGET_INPUT" == "sd" ]; then TARGET=$DEV_SD
else
    echo "Nutzung: sudo $0 [USB|SD]"; exit 1
fi

echo "Ziel-Device gewählt: $TARGET"
read -p "Soll ein spezifisches Exclude hinzugefügt werden? (Enter für Nein): " EXTRA_EXCLUDE
MY_EXCLUDES="$MY_EXCLUDES $EXTRA_EXCLUDE"

# --- PARTITIONIERUNG ---
sudo wipefs -a $TARGET
sudo parted $TARGET mklabel msdos
sudo parted -a optimal $TARGET mkpart primary fat32 4MiB 512MiB

# Prüfen, ob genug Platz für DATA da ist
DISK_SIZE=$(lsblk -bno SIZE $TARGET | head -n1)
DISK_GB=$(($DISK_SIZE / 1024 / 1024 / 1024))
ROOT_GB_NUM=$(echo $ROOT_SIZE | sed 's/G//')

if [ $(($DISK_GB - $ROOT_GB_NUM)) -ge $MIN_DATA_SIZE ]; then
    echo "Erstelle ROOT ($ROOT_SIZE) und DATA (Rest)..."
    sudo parted -a optimal $TARGET mkpart primary ext4 512MiB ${ROOT_GB_NUM}.5GiB
    sudo parted -a optimal $TARGET mkpart primary ext4 ${ROOT_GB_NUM}.5GiB 100%
    HAS_DATA=true
else
    echo "Zu wenig Platz für DATA. Erstelle ROOT über den gesamten Rest..."
    sudo parted -a optimal $TARGET mkpart primary ext4 512MiB 100%
    HAS_DATA=false
fi

# --- FORMATIERUNG ---
sudo mkfs.vfat -F 32 -n BOOT ${TARGET}1
sudo mkfs.ext4 -L ROOT ${TARGET}2
[ "$HAS_DATA" = true ] && sudo mkfs.ext4 -L DATA ${TARGET}3

# --- MOUNTEN & KOPIEREN ---
sudo mkdir -p /mnt/target
sudo mount ${TARGET}2 /mnt/target
sudo mkdir -p /mnt/target/boot/firmware
sudo mount ${TARGET}1 /mnt/target/boot/firmware

echo "Kopiere System mit rsync..."
sudo rsync -axHAWXS --numeric-ids --info=progress2 $MY_EXCLUDES / /mnt/target
sudo rsync -axHAWXS --numeric-ids --info=progress2 /boot/firmware/ /mnt/target/boot/firmware

# --- KONFIGURATION & LINKS ---
ID_BOOT=$(lsblk -dno PARTUUID ${TARGET}1)
ID_ROOT=$(lsblk -dno PARTUUID ${TARGET}2)

sudo sed -i "s/root=PARTUUID=[^ ]*/root=PARTUUID=$ID_ROOT/" /mnt/target/boot/firmware/cmdline.txt
sudo sed -i "s|^PARTUUID=[^ ]* \+/boot/firmware|PARTUUID=$ID_BOOT  /boot/firmware|" /mnt/target/etc/fstab
sudo sed -i "s|^PARTUUID=[^ ]* \+/ |PARTUUID=$ID_ROOT  / |" /mnt/target/etc/fstab

if [ "$HAS_DATA" = true ]; then
    ID_DATA=$(lsblk -dno PARTUUID ${TARGET}3)
    echo "PARTUUID=$ID_DATA  /mnt/data  ext4  defaults,noatime  0  2" | sudo tee -a /mnt/target/etc/fstab
    sudo mkdir -p /mnt/target/mnt/data
    # Link im Home-Verzeichnis erstellen (auf dem Backup-System)
    sudo ln -s /mnt/data /mnt/target/home/pi/data
    echo "DATA-Partition erstellt und als Link in /home/pi/data hinterlegt."
fi

# --- ABSCHLUSS ---
sudo umount /mnt/target/boot/firmware
sudo umount /mnt/target
echo "Backup auf $TARGET erfolgreich abgeschlossen!"
