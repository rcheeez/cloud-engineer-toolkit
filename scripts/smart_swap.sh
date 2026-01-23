#!/bin/bash

# Define the swap file path and desired size
SWAP_PATH="/swapfile"
SWAP_SIZE="4G"

# 1. PRE-CHECK: RAM and Disk Space availability
echo "--- Step 1: Smart Safety Check ---"
FREE_RAM=$(free -m | awk '/^Mem:/{print $4+$7}') # Free + Available RAM in MB
USED_SWAP=$(free -m | awk '/^Swap:/{print $3}')  # Used Swap in MB
SWAP_SIZE_MB=$(echo "$SWAP_SIZE" | sed 's/G$//' | awk '{print $1*1024}') # Convert to MB
AVAIL_DISK=$(df / | awk 'NR==2{print int($4/1024)}') # Available disk space in MB

echo "Available RAM: ${FREE_RAM}MB"
echo "Used Swap: ${USED_SWAP}MB"
echo "Required Swap Size: ${SWAP_SIZE_MB}MB"
echo "Available Disk Space: ${AVAIL_DISK}MB"

# Check RAM availability
RAM_OK=true
if [ "$USED_SWAP" -ge "$FREE_RAM" ]; then
    echo "WARNING: Not enough free RAM to offload current swap (${USED_SWAP}MB used, ${FREE_RAM}MB available)"
    RAM_OK=false
fi

# Check disk space availability
DISK_OK=true
if [ "$SWAP_SIZE_MB" -ge "$AVAIL_DISK" ]; then
    echo "WARNING: Not enough disk space for swap file (${SWAP_SIZE_MB}MB required, ${AVAIL_DISK}MB available)"
    DISK_OK=false
fi

# Decision logic
if [ "$RAM_OK" = true ] && [ "$DISK_OK" = true ]; then
    echo "Safety check passed. Proceeding with swap creation..."
elif [ "$RAM_OK" = true ] && [ "$DISK_OK" = false ]; then
    echo "CRITICAL ERROR: Cannot create swap - insufficient disk space."
    echo "Free up at least $((SWAP_SIZE_MB - AVAIL_DISK))MB of disk space before running this script."
    exit 1
elif [ "$RAM_OK" = false ] && [ "$DISK_OK" = true ]; then
    echo "CRITICAL ERROR: Cannot create swap - insufficient RAM to offload current swap."
    echo "Close some applications or stop data processing before running this script."
    exit 1
else
    echo "CRITICAL ERROR: Cannot create swap - insufficient both RAM and disk space."
    echo "Need $((USED_SWAP - FREE_RAM))MB more RAM and $((SWAP_SIZE_MB - AVAIL_DISK))MB more disk space."
    exit 1
fi

# 2. DISABLE SWAP
echo "--- Step 2: Disabling Swap ---"
sudo swapoff "$SWAP_PATH"

# 3. RESIZE AND RECREATE
echo "--- Step 3: Resizing to $SWAP_SIZE ---"
# Using dd as a fallback for fallocate
sudo fallocate -l "$SWAP_SIZE" "$SWAP_PATH" || sudo dd if=/dev/zero of="$SWAP_PATH" bs=1M count=4096

echo "--- Step 4: Setting Permissions & Formatting ---"
sudo chmod 600 "$SWAP_PATH"
sudo mkswap "$SWAP_PATH"

echo "--- Step 5: Activating New Swap ---"
sudo swapon "$SWAP_PATH"

# 4. MAKE PERMANENT
if ! grep -q "$SWAP_PATH" /etc/fstab; then
    echo "$SWAP_PATH none swap sw 0 0" | sudo tee -a /etc/fstab
fi

echo "--- Done! ---"
free -h