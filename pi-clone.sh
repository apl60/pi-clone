#!/bin/bash
# ==============================================================================
# Title:        Smart-Pi-Clone
# Description:  A CLI tool to clone a running Raspberry Pi OS (Bookworm) 
#               to a USB or SD device with optional data partitioning.
# Author:       Andreas Pagel
# Date:         2026-01-02
# Version:      1.0.0
# License:      MIT License
# GitHub:       https://github.com/apl60/pi-clone
# ==============================================================================
# Usage:        sudo ./pi-clone.sh [usb|sd]
# Note:         Specifically designed for Raspberry Pi OS (64-bit) 
#               using the /boot/firmware mount point.
# ==============================================================================
#!/bin/bash

# --- CONFIGURATION ---
# Default devices for Raspberry Pi
DEV_USB="/dev/sdb"
DEV_SD="/dev/mmcblk0"
ROOT_SIZE="20G"        # Fixed size for the System partition
ROOT_SIZE=16           # Fixed size in GB for the System partition
MIN_DATA_SIZE=5        # Minimum remaining space in GB to trigger a DATA partition

# Editable EXCLUDES
# The /* suffix ensures the directory remains as a mount point but its volatile content is ignored
MY_EXCLUDES="--exclude=/proc/* --exclude=/sys/* --exclude=/dev/* --exclude=/run/* --exclude=/tmp/* --exclude=/lost+found --exclude=/mnt/* --exclude=/media/*"

# --- CHECK FOR ROOT PRIVILEGES ---
if [ "$EUID" -ne 0 ]; then 
  echo "Please run as root (use sudo)"
  exit 1
fi

# --- INITIALIZATION ---
TARGET_INPUT=$(echo "$1" | tr '[:upper:]' '[:lower:]')
if [ "$TARGET_INPUT" == "usb" ]; then 
  # Wir suchen ein USB-Gerät (TRAN=usb), das NICHT die System-SD ist
  TARGET_DEVICE=$(lsblk -dno NAME,TRAN,SIZE | grep "usb" | awk '{print "/dev/"$1}' | head -n 1)
  if [ -z "$TARGET_DEVICE" ]; then
    echo "FEHLER: Kein USB-Stick gefunden!"
    exit 1
  elif [ "$TARGET_DEVICE" != "$DEV_USB" ]; then
    echo "WARN -  found different USB device: $TARGET_DEVICE != $DEV_USB"
    echo "        are there more than 1 USB device (besides the backup-stick)?"
    echo ""
    lsblk -no NAME,TRAN,SIZE,MOUNTPOINTS
    echo -n "Please enter the correct USB device /dev/sdX : "
    read DEV_USB
  else
    echo " found USB device: TARGET = $DEV_USB"
  fi

  TARGET=$DEV_USB
  TARGET_DISK=${TARGET}
elif [ "$TARGET_INPUT" == "sd" ]; then 
  TARGET=$DEV_SD
  TARGET_DISK=${TARGET}p
else
    echo "Usage: sudo $0 [USB|SD]"
    echo "Current defaults: USB=$DEV_USB, SD=$DEV_SD"
    exit 1
fi

echo "Target device selected: $TARGET"

# Sicherheitsabfrage zur Bestätigung
echo "System wird geklont auf: $TARGET_DEVICE"
lsblk $TARGET_DEVICE
echo -n "Sind Sie sicher? (y/n): "
read confirmation
if [ "$confirmation" != "y" ]; then
    echo "Abbruch."
    exit 1
fi

DEST=$TARGET_DEVICE



echo "current excludes: $MY_EXCLUDES"
read -p "Add specific folder to excludes? (each needs to be like --exclude=dir - Leave empty for none): " EXTRA_EXCLUDE
MY_EXCLUDES="$MY_EXCLUDES $EXTRA_EXCLUDE"

# --- PARTITIONING ---
echo "Wiping existing partition table on $TARGET..."
#echo "Vorbereitung: Unmounte alle Partitionen von ${TARGET_DISK}..."

# Findet alle Mountpoints von sda1, sda2, etc. und unmountet sie
for part in $(lsblk -ln -o NAME "${TARGET_DISK}" | grep -E "^[a-z]+[0-9]+$"); do
    mountpoint=$(lsblk -no MOUNTPOINT "/dev/$part")
    if [ -n "$mountpoint" ]; then
        echo "Löse Mount: /dev/$part von $mountpoint"
        sudo umount -l "/dev/$part" 2>/dev/null
    fi
done

# Zusätzlicher Wipe-Schutz
sudo wipefs -a "${TARGET_DISK}" || { echo "Fehler: ${TARGET_DISK} ist noch belegt!"; exit 1; }

sudo parted $TARGET mklabel msdos

echo "Creating partitions..."
# Boot Partition: 512MB (FAT32)
sudo parted -a optimal $TARGET mkpart primary fat32 4MiB 512MiB

# Calculate disk size to decide if DATA partition is feasible
DISK_SIZE=$(lsblk -bno SIZE $TARGET | head -n1)
DISK_GB=$(($DISK_SIZE / 1024 / 1024 / 1024))
#ROOT_GB_NUM=$(echo $ROOT_SIZE | sed 's/G//')

#if [ $(($DISK_GB - $ROOT_GB_NUM)) -ge $MIN_DATA_SIZE ]; then
if [ $(($DISK_GB - $ROOT_SIZE)) -ge $MIN_DATA_SIZE ]; then
    echo "Sufficient space found. Creating ROOT ($ROOT_SIZE)GB and DATA (Remainder)..."
    sudo parted -a optimal $TARGET mkpart primary ext4 512MiB ${ROOT_SIZE}.5GiB
    #sudo parted -a optimal $TARGET mkpart primary ext4 512MiB ${ROOT_GB_NUM}.5GiB
    sudo parted -a optimal $TARGET mkpart primary ext4 ${ROOT_SIZE}.5GiB 100%
    HAS_DATA=true
else
    echo "Insufficient space for DATA partition. Using remainder for ROOT..."
    sudo parted -a optimal $TARGET mkpart primary ext4 512MiB 100%
    HAS_DATA=false
fi

# --- FORMATTING ---
echo "Formatting partitions..."
sudo mkfs.vfat -F 32 -n BOOT ${TARGET_DISK}1
sudo mkfs.ext4 -L ROOT ${TARGET_DISK}2
[ "$HAS_DATA" = true ] && sudo mkfs.ext4 -L DATA ${TARGET_DISK}3

# --- MOUNTING & CLONING ---
sudo mkdir -p /mnt/target
sudo mount ${TARGET_DISK}2 /mnt/target
sudo mkdir -p /mnt/target/boot/firmware
sudo mount ${TARGET_DISK}1 /mnt/target/boot/firmware

echo -n "Starting rsync clone (this may take a while)..."
echo -n " /root"
sudo rsync -axHAWXS --numeric-ids --info=progress2 --exclude /boot/firmware/* $MY_EXCLUDES / /mnt/target
echo -n " /boot"
sudo rsync -axHAWXS --numeric-ids --info=progress2 /boot/firmware/ /mnt/target/boot/firmware
echo  " - DONE"


echo "Updating PARTUUIDs and Mounts..."

# Kernel zwingen, die Partitionstabelle neu zu laden
sudo partprobe ${TARGET_DISK}
# Warten, bis alle Device-Nodes (/dev/sdXn) erstellt sind
sudo udevadm settle

# IDs auslesen
ID_BOOT=$(lsblk -dno PARTUUID ${TARGET_DISK}1)
ID_ROOT=$(lsblk -dno PARTUUID ${TARGET_DISK}2)
ID_DATA=$(lsblk -dno PARTUUID ${TARGET_DISK}3)

# --- SICHERHEITS-CHECK ---
if [ -z "$ID_BOOT" ] || [ -z "$ID_ROOT" ] || [ -z "$ID_DATA" ]; then
    echo -e "\e[1;31mFEHLER: PARTUUIDs konnten nicht gelesen werden!\e[0m"
    echo "Boot: $ID_BOOT | Root: $ID_ROOT | Data: $ID_DATA"
    echo "Breche Prozess ab, um korrupte Boot-Konfiguration zu verhindern."
    # Hier ggf. unmount Befehle einfügen
    exit 1
fi

# 1. Update cmdline.txt
sudo sed -i "s|root=PARTUUID=[a-z0-9-]*|root=PARTUUID=${ID_ROOT}|" /mnt/target/boot/firmware/cmdline.txt

# 2. Update fstab (System-Partitionen)
# Wir nutzen \s+ für Tabs/Leerzeichen und [a-z0-9-]* für die UUID
sudo sed -i "s|^PARTUUID=[a-z0-9-]*\s\+/boot/firmware|PARTUUID=${ID_BOOT}  /boot/firmware|" /mnt/target/etc/fstab
sudo sed -i "s|^PARTUUID=[a-z0-9-]*\s\+/ |PARTUUID=${ID_ROOT}  / |" /mnt/target/etc/fstab

# 3. Update fstab (Data-Partition /mnt/data)

# Bestehende /mnt/data Einträge IMMER löschen (Tabula Rasa)
# Das '-i' löscht jede Zeile, die '/mnt/data' enthält
sudo sed -i '/\/mnt\/data/d' /mnt/target/etc/fstab


# 3. Daten-Partition nur hinzufügen, wenn gewünscht und vorhanden
if [ "$HAS_DATA" = true ]; then
    if [ -n "$ID_DATA" ]; then
        echo "Adding fresh /mnt/data entry with PARTUUID=$ID_DATA"
        echo "PARTUUID=$ID_DATA  /mnt/data  ext4  defaults,noatime  0  2" | sudo tee -a /mnt/target/etc/fstab
    else
        echo -e "\e[1;33mWARNUNG: HAS_DATA=true, aber Partition 3 nicht gefunden! Manuelles Update der fstab erforderlich!\e[0m"
    fi
else
    echo "No Data partition requested. Cleaned /mnt/data from fstab."
fi

echo -e "\e[1;32mKonfiguration erfolgreich aktualisiert.\e[0m"




#--------- if we have a data partition on the target device, clone also the data partition ----------
if [ "$HAS_DATA" = true ]; then
  sudo mount ${TARGET_DISK}3 /mnt/target-data

  # Data partition auf transferieren
  declare -a EXCLUDES_ARR=(
    --exclude="backup_filelist.log"
    --exclude="backups/"
    --exclude="containerd/"
    --exclude="docker/"
    --exclude="volumes/influxdb/data/data"
    --exclude="volumes/influxdb/data/meta"
    --exclude="volumes/influxdb/data/wal"
    --exclude=".venv/"
    --exclude=".virtualenv-menu/"
    --exclude="**/*.log"
    --exclude=".tmp/"
  )
  echo -n "Starting rsync for clone of DATA partition  (this may take a while)..."
  sudo rsync -axHAWXS --numeric-ids --info=progress2 "${EXCLUDES_ARR[@]}" /mnt/data/ /mnt/target-data
  echo " DONE!"

  #Neue Partition 3 konfigurieren
  #prepare empty directories for docker on /data /mnt/data
  sudo mkdir -p /mnt/target-data/docker
  sudo mkdir -p /mnt/target-data/containerd
  sudo chmod 711 /mnt/target-data/docker
  sudo chmod 711 /mnt/target-data/containerd

  sudo ln -s /mnt/data /mnt/target/home/pi/data2 #test link
  echo "DATA partition configured and linked to /home/pi/data."

  echo "Warnings:
all backups, logs and other unvital data has been excluded.
after first boot, pls run
cd /home/pi/IOTstack &&  docker-compose up -d
... "
  #sudo umount /mnt/target-data
else
    # FALLS KEINE DATENPARTITION:
    # Alte Zeile aus der fstab löschen, die /mnt/data mounten will
    sudo sed -i '/\/mnt\/data/d' "$FSTAB_PATH"

    # (Optional) Den Symlink im Home-Verzeichnis entfernen, falls er ins Leere zeigt
    sudo rm -f /mnt/target/home/pi/data && sudo mkdir /mnt/target/home/pi/data
    sudo rm -f /mnt/target/home/pi/scripts && sudo mkdir /mnt/target/home/pi/scripts
    sudo cp -rp /home/pi/scripts /mnt/target/home/pi/scripts

    # restore base config for docker and containerd
    sudo rm -f /mnt/target/var/lib/docker&& sudo mkdir /mnt/target/var/lib/docker
    sudo rm -f /mnt/target/var/lib/containerd && sudo mkdir /mnt/target/var/lib/containerd
    sudo mv /mnt/target/etc/docker/daemon.json /mnt/target/etc/docker/daemon.json.back
    sudo mv /mnt/target/etc/containerd/config.toml /mnt/target/etc/containerd/config.toml.bak 
    sudo containerd config default | sudo tee /mnt/target/etc/containerd/config.toml # Neue Standard-Config generieren 

    echo "data partition not included in cloned system." > /mnt/target/home/pi/data/readme.txt
    echo "To-DOs:
- please restore IOTstack from backup
- check /home/pi/scripts (link to IOTstack/my_scripts)
- check/clean up fstab: Remove old DATA partition entry.
- if new data disk or partition is added, move docker+containerd there
... and any other needed steps that I could not think off yet ;-)" >> /mnt/target/home/pi/data/readme.txt

    sudo ln /mnt/target/home/pi/data/readme.txt /mnt/target/data/readme.txt
fi

# --- CLEANUP ---
#sudo umount /mnt/target/boot/firmware
#sudo umount /mnt/target
echo "------------------------------------------------------"
echo "Success! System successfully cloned to $TARGET."
echo "Note: To test, power off, remove source medium, and boot from $TARGET."
