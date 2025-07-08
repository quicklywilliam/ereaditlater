#!/bin/bash

# KOReader Instapaper Plugin Deployment Script
# This script copies the Instapaper plugin to your development device

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
PLUGIN_SOURCE="plugins/ereader.koplugin"
DEVICE_PLUGIN_DIR="/Volumes/KOBOeReader/.adds/koreader/plugins"

# Additional files to copy (source -> destination relative to KOReader root)
KOREADER_BASE_FILES=(
    "frontend/ui/elements/filemanager_menu_order.lua"
    "frontend/ui/elements/reader_menu_order.lua"
    "frontend/ui/widget/menu.lua"
    "reader.lua"
)

echo -e "${GREEN}KOReader eReader Plugin Deployment Script${NC}"
echo "================================================"

# Check if plugin source exists
if [ ! -d "$PLUGIN_SOURCE" ]; then
    echo -e "${RED}Error: Plugin source directory not found: $PLUGIN_SOURCE${NC}"
    echo "Make sure you're running this script from the KOReader root directory"
    exit 1
fi

# Check if device is connected
if [ ! -d "/Volumes/KOBOeReader" ]; then
    echo -e "${YELLOW}Warning: Device not found at /Volumes/KOBOeReader${NC}"
    echo "Please ensure your Kobo device is connected and mounted"
    echo "The device should appear as 'KOBOeReader' in Finder"
    exit 1
fi

# Check if KOReader plugins directory exists on device
if [ ! -d "$DEVICE_PLUGIN_DIR" ]; then
    echo -e "${YELLOW}Creating plugins directory on device...${NC}"
    mkdir -p "$DEVICE_PLUGIN_DIR"
fi

# Copy plugin to device
echo -e "${GREEN}Copying plugin to device...${NC}"
cp -r "$PLUGIN_SOURCE" "$DEVICE_PLUGIN_DIR/"

# Copy base files to device
for FILE in "${KOREADER_BASE_FILES[@]}"; do
    DEST="/Volumes/KOBOeReader/.adds/koreader/${FILE}"
    DEST_DIR="$(dirname "$DEST")"
    if [ ! -d "$DEST_DIR" ]; then
        echo -e "${YELLOW}Creating directory $DEST_DIR on device...${NC}"
        mkdir -p "$DEST_DIR"
    fi
    echo -e "${GREEN}Copying $FILE to device...${NC}"
    cp "$FILE" "$DEST"
done

# Check for .adds/nm directory and create ereader menu item if needed
NM_DIR="/Volumes/KOBOeReader/.adds/nm"
NM_FILE="$NM_DIR/ereader"
if [ -d "$NM_DIR" ]; then
    if [ ! -f "$NM_FILE" ]; then
        echo -e "${GREEN}Creating eReader menu item in $NM_DIR...${NC}"
        cat > "$NM_FILE" <<EOF
menu_item : main : eReader : cmd_spawn : quiet : exec /mnt/onboard/.adds/koreader/koreader.sh -ereader
EOF
    else
        echo -e "${YELLOW}eReader menu item already exists in $NM_DIR.${NC}"
    fi
fi

# Set proper permissions
echo -e "${GREEN}Setting permissions...${NC}"
chmod -R 755 "$DEVICE_PLUGIN_DIR/ereader.koplugin"

echo -e "${GREEN}Ejecting Kobo device...${NC}"
diskutil eject /Volumes/KOBOeReader

echo -e "${GREEN}Deployment completed successfully!${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Restart KOReader on your device"
echo "2. The eReader plugin should now be available in the plugin menu"
echo ""
echo -e "${YELLOW}To restore the previous version:${NC}"