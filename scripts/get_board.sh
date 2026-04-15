#!/bin/bash

BOARD_URL=https://github.com/cathalmccabe/pynq-z1_board_files/raw/master/pynq-z1.zip
TEMP_DIR="$1"
XILINX_DIR="$2"

if [ -z "$TEMP_DIR" ] || [ -z "$XILINX_DIR" ]; then
  echo "Usage: $0 <temp_dir> <vivado_data_dir>"
  exit 1
fi

# make temp dir for downloading the board file
mkdir -p "$TEMP_DIR"
wget -P "$TEMP_DIR" "$BOARD_URL"

if command -v unzip &> /dev/null; then
  ZIPFILE=$(basename "$BOARD_URL")
  unzip "$TEMP_DIR/$ZIPFILE" -d "$TEMP_DIR"
else
  echo "unzip command not found. Please install unzip to extract the board file."
  exit 1
fi

BOARD_STEM=$(basename "$BOARD_URL" .zip)
BOARD_DIR="$XILINX_DIR/data/xhub/boards/XilinxBoardStore/boards/Xilinx"

mkdir -p "$BOARD_DIR"
mv "$TEMP_DIR/$BOARD_STEM" "$BOARD_DIR/"

rm -rf "$TEMP_DIR"

echo "Board files have been moved to $BOARD_DIR"