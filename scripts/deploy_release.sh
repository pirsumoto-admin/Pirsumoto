#!/bin/bash
# ==============================================================================
# Script: deploy_release.sh
# Description: Builds release APK for Pirsumoto and deploys to an Android device via ADB
# Usage:
#   ./scripts/deploy_release.sh [OPTIONS]
#
# Options:
#   -l, --launch         Launch app after installation
#   -c, --clean          Run 'flutter clean' and 'flutter pub get' before building
#   --split-per-abi      Build split APKs per architecture (smaller size, faster install)
#   --skip-build         Skip build step and deploy the last built APK
#   -s, --device <id>    Specify target ADB device serial if multiple devices connected
#   -h, --help           Show this help message
# ==============================================================================

set -e

# Package & Activity definitions for Pirsumoto
PACKAGE_NAME="com.pirsumotoapp"
MAIN_ACTIVITY="com.pirsumoto.app.MainActivity"
DEFAULT_APK_PATH="build/app/outputs/flutter-apk/app-release.apk"

# Formatting colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

LAUNCH_APP=false
CLEAN_BUILD=false
SPLIT_PER_ABI=false
SKIP_BUILD=false
DEVICE_SERIAL=""

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -l|--launch)
      LAUNCH_APP=true
      shift
      ;;
    -c|--clean)
      CLEAN_BUILD=true
      shift
      ;;
    --split-per-abi)
      SPLIT_PER_ABI=true
      shift
      ;;
    --skip-build)
      SKIP_BUILD=true
      shift
      ;;
    -s|--device)
      DEVICE_SERIAL="$2"
      shift 2
      ;;
    -h|--help)
      echo -e "${BLUE}Pirsumoto - Build & Deploy Release APK${NC}"
      echo ""
      echo "Usage: ./scripts/deploy_release.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  -l, --launch         Launch app on device after install"
      echo "  -c, --clean          Run flutter clean & flutter pub get first"
      echo "  --split-per-abi      Build split APKs per ABI and install matching APK"
      echo "  --skip-build         Install existing APK without rebuilding"
      echo "  -s, --device <id>    Specify ADB device ID (if multiple devices)"
      echo "  -h, --help           Show this help message"
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown argument: $1${NC}"
      echo "Use --help for usage instructions."
      exit 1
      ;;
  esac
done

# Navigate to project root (directory containing pubspec.yaml)
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

echo -e "${BLUE}=== Pirsumoto Release Build & Deploy ===${NC}"

# Check for required tools
if ! command -v flutter &> /dev/null; then
  echo -e "${RED}Error: flutter command not found in PATH.${NC}"
  exit 1
fi

if ! command -v adb &> /dev/null; then
  echo -e "${RED}Error: adb command not found in PATH.${NC}"
  exit 1
fi

# Detect ADB devices
ADB_CMD="adb"
if [ -n "$DEVICE_SERIAL" ]; then
  ADB_CMD="adb -s $DEVICE_SERIAL"
fi

echo -e "\n${BLUE}Checking connected Android devices...${NC}"
DEVICES=($($ADB_CMD devices | awk 'NR>1 && $2=="device" {print $1}'))

if [ ${#DEVICES[@]} -eq 0 ]; then
  echo -e "${YELLOW}Warning: No connected Android device found via ADB.${NC}"
  echo "Please connect a device via USB (with USB Debugging enabled) or start an emulator."
  echo "You can still run this script once your device is connected, or build the APK only."
  read -p "Do you want to proceed with building the APK anyway? (y/N) " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
  TARGET_DEVICE=""
elif [ ${#DEVICES[@]} -eq 1 ]; then
  TARGET_DEVICE="${DEVICES[0]}"
  ADB_CMD="adb -s $TARGET_DEVICE"
  echo -e "${GREEN}Detected device: $TARGET_DEVICE${NC}"
else
  if [ -z "$DEVICE_SERIAL" ]; then
    echo -e "${YELLOW}Multiple devices connected:${NC}"
    for i in "${!DEVICES[@]}"; do
      echo "  [$i] ${DEVICES[$i]}"
    done
    read -p "Select device index [0-$((${#DEVICES[@]}-1))]: " SELECTED_INDEX
    TARGET_DEVICE="${DEVICES[$SELECTED_INDEX]}"
    ADB_CMD="adb -s $TARGET_DEVICE"
    echo -e "${GREEN}Using device: $TARGET_DEVICE${NC}"
  else
    TARGET_DEVICE="$DEVICE_SERIAL"
  fi
fi

# 1. Clean if requested
if [ "$CLEAN_BUILD" = true ]; then
  echo -e "\n${BLUE}Cleaning project...${NC}"
  flutter clean
  flutter pub get
fi

# 2. Build Release APK
if [ "$SKIP_BUILD" = false ]; then
  echo -e "\n${BLUE}Building release APK...${NC}"
  BUILD_ARGS=("build" "apk" "--release")
  
  if [ "$SPLIT_PER_ABI" = true ]; then
    BUILD_ARGS+=("--split-per-abi")
  fi

  flutter "${BUILD_ARGS[@]}"
else
  echo -e "\n${YELLOW}Skipping build step, using existing APK...${NC}"
fi

# Determine APK path to install
APK_TO_INSTALL="$DEFAULT_APK_PATH"

if [ "$SPLIT_PER_ABI" = true ]; then
  if [ -n "$TARGET_DEVICE" ]; then
    # Query device primary ABI
    DEVICE_ABI=$($ADB_CMD shell getprop ro.product.cpu.abi | tr -d '\r')
    echo -e "${BLUE}Device ABI detected: ${DEVICE_ABI}${NC}"
    
    case "$DEVICE_ABI" in
      arm64-v8a)
        APK_TO_INSTALL="build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
        ;;
      armeabi-v7a)
        APK_TO_INSTALL="build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk"
        ;;
      x86_64)
        APK_TO_INSTALL="build/app/outputs/flutter-apk/app-x86_64-release.apk"
        ;;
      *)
        echo -e "${YELLOW}Unmatched ABI ($DEVICE_ABI), falling back to fat APK if available${NC}"
        ;;
    esac
  fi
fi

if [ ! -f "$APK_TO_INSTALL" ]; then
  echo -e "${RED}Error: APK file not found at: $APK_TO_INSTALL${NC}"
  exit 1
fi

echo -e "\n${GREEN}APK ready: $APK_TO_INSTALL ($(du -h "$APK_TO_INSTALL" | cut -f1))${NC}"

# 3. Deploy to device
if [ -n "$TARGET_DEVICE" ]; then
  echo -e "\n${BLUE}Installing APK on device ($TARGET_DEVICE)...${NC}"
  $ADB_CMD install -r -d "$APK_TO_INSTALL"
  echo -e "${GREEN}✓ Installation successful!${NC}"

  # 4. Launch app if requested
  if [ "$LAUNCH_APP" = true ]; then
    echo -e "\n${BLUE}Launching $PACKAGE_NAME...${NC}"
    $ADB_CMD shell am start -n "$PACKAGE_NAME/$MAIN_ACTIVITY"
    echo -e "${GREEN}✓ App launched!${NC}"
  fi
else
  echo -e "\n${YELLOW}No device was targeted for installation. APK is ready at: ${APK_TO_INSTALL}${NC}"
fi

echo -e "\n${GREEN}Done!${NC}"
