# --- OPTIONAL: ROBUST ZRAM SETUP ---
# This part can be added to your clone script to ensure the target 
# has a working zRAM config without buggy zram packages.

echo "Setting up robust zRAM configuration on target..."
cat <<EOF | sudo tee -a /mnt/target/etc/rc.local
# Added by Smart-Pi-Clone: zRAM Setup
modprobe zram
echo zstd > /sys/block/zram0/comp_algorithm
echo 967120896 > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon -p 100 /dev/zram0
exit 0
EOF
sudo chmod +x /mnt/target/etc/rc.local
