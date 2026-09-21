#!/bin/bash
# ==============================================================================
# Script: install_and_grant_permissions.sh
# Description: Installs Pirsumoto APK via ADB and automatically grants ALL
#              required Android permissions (Accessibility, MediaProjection,
#              Notification Listener, Battery Whitelist, Storage, etc.)
# Usage:
#   ./scripts/install_and_grant_permissions.sh [OPTIONS]
#
# Options:
#   -a, --apk <path>     Path to APK file (default: release APK)
#   -b, --build          Build release APK before installing
#   -l, --launch         Launch app after granting permissions
#   -s, --device <id>    Specify target ADB device serial
#   -h, --help           Show help message
# ==============================================================================

set -e

PACKAGE_NAME="com.pirsumotoapp"
MAIN_ACTIVITY="com.pirsumoto.app.MainActivity"
ACCESSIBILITY_SERVICE="com.pirsumotoapp/com.pirsumoto.app.PirsumotoAccessibilityService"
NOTIFICATION_SERVICE="com.pirsumotoapp/com.pirsumoto.app.WhatsAppNotificationListenerService"
DEFAULT_APK_PATH="build/app/outputs/flutter-apk/app-release.apk"

# Formatting colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

BUILD_FIRST=false
LAUNCH_APP=false
CUSTOM_APK=""
DEVICE_SERIAL=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -b|--build)
      BUILD_FIRST=true
      shift
      ;;
    -a|--apk)
      CUSTOM_APK="$2"
      shift 2
      ;;
    -l|--launch)
      LAUNCH_APP=true
      shift
      ;;
    -s|--device)
      DEVICE_SERIAL="$2"
      shift 2
      ;;
    -h|--help)
      echo -e "${BLUE}Pirsumoto - ADB Install & Full Permission Granter${NC}"
      echo ""
      echo "Usage: ./scripts/install_and_grant_permissions.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  -b, --build          Build release APK before installing"
      echo "  -a, --apk <path>     Specify custom APK path"
      echo "  -l, --launch         Launch app after setting permissions"
      echo "  -s, --device <id>    Specify target ADB device ID"
      echo "  -h, --help           Show this help message"
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown argument: $1${NC}"
      exit 1
      ;;
  esac
done

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}     Pirsumoto ADB Setup & Permission Granter         ${NC}"
echo -e "${BLUE}======================================================${NC}"

# Check ADB
if ! command -v adb &> /dev/null; then
  echo -e "${RED}Error: adb command not found in PATH.${NC}"
  exit 1
fi

ADB_CMD="adb"
if [ -n "$DEVICE_SERIAL" ]; then
  ADB_CMD="adb -s $DEVICE_SERIAL"
fi

# Detect device
echo -e "\n${BLUE}[1/5] Checking connected Android devices...${NC}"
DEVICES=($($ADB_CMD devices | awk 'NR>1 && $2=="device" {print $1}'))

if [ ${#DEVICES[@]} -eq 0 ]; then
  echo -e "${RED}Error: No connected Android device found via ADB.${NC}"
  echo "Please connect your Android device with USB debugging enabled."
  exit 1
elif [ ${#DEVICES[@]} -eq 1 ]; then
  TARGET_DEVICE="${DEVICES[0]}"
  ADB_CMD="adb -s $TARGET_DEVICE"
  echo -e "${GREEN}✓ Target device: $TARGET_DEVICE${NC}"
else
  if [ -z "$DEVICE_SERIAL" ]; then
    echo -e "${YELLOW}Multiple devices connected:${NC}"
    for i in "${!DEVICES[@]}"; do
      echo "  [$i] ${DEVICES[$i]}"
    done
    read -p "Select device index [0-$((${#DEVICES[@]}-1))]: " SELECTED_INDEX
    TARGET_DEVICE="${DEVICES[$SELECTED_INDEX]}"
    ADB_CMD="adb -s $TARGET_DEVICE"
    echo -e "${GREEN}✓ Using device: $TARGET_DEVICE${NC}"
  else
    TARGET_DEVICE="$DEVICE_SERIAL"
  fi
fi

# Build if requested
if [ "$BUILD_FIRST" = true ]; then
  echo -e "\n${BLUE}[2/5] Building release APK...${NC}"
  flutter build apk --release
fi

APK_PATH="$DEFAULT_APK_PATH"
if [ -n "$CUSTOM_APK" ]; then
  APK_PATH="$CUSTOM_APK"
fi

# Install APK if present
if [ -f "$APK_PATH" ]; then
  echo -e "\n${BLUE}[3/5] Installing APK: $APK_PATH...${NC}"
  $ADB_CMD install -r -d -g "$APK_PATH"
  echo -e "${GREEN}✓ APK installed successfully!${NC}"
else
  echo -e "\n${YELLOW}[3/5] APK not found at '$APK_PATH'. Skipping installation, configuring permissions for installed package...${NC}"
fi

# Configure permissions via ADB / AppOps / Settings
echo -e "\n${BLUE}[4/5] Setting up persistent permissions...${NC}"

# 0. Allow Restricted Settings (Required on Android 13+ for sideloaded/ADB apps)
echo -e "  → Allowing Restricted Settings (Android 13+)..."
$ADB_CMD shell appops set "$PACKAGE_NAME" ACCESS_RESTRICTED_SETTINGS allow 2>/dev/null || true
$ADB_CMD shell appops set --user 0 "$PACKAGE_NAME" ACCESS_RESTRICTED_SETTINGS allow 2>/dev/null || true

# 1. Enable Accessibility Service without system prompts
echo -e "  → Enabling Accessibility Service..."
EXISTING_A11Y=$($ADB_CMD shell settings get secure --user 0 enabled_accessibility_services | tr -d '\r')
if [[ "$EXISTING_A11Y" != *"$ACCESSIBILITY_SERVICE"* ]]; then
  if [ -z "$EXISTING_A11Y" ] || [ "$EXISTING_A11Y" == "null" ]; then
    NEW_A11Y="$ACCESSIBILITY_SERVICE"
  else
    NEW_A11Y="${EXISTING_A11Y}:${ACCESSIBILITY_SERVICE}"
  fi
  $ADB_CMD shell settings put secure --user 0 enabled_accessibility_services "$NEW_A11Y" 2>/dev/null || true
  $ADB_CMD shell settings put secure enabled_accessibility_services "$NEW_A11Y" 2>/dev/null || true
fi
$ADB_CMD shell settings put secure --user 0 accessibility_enabled 1 2>/dev/null || true
$ADB_CMD shell settings put secure accessibility_enabled 1 2>/dev/null || true

# 2. Grant MediaProjection permission permanently (Prevents casting dialog)
echo -e "  → Granting MediaProjection (PROJECT_MEDIA)..."
$ADB_CMD shell appops set "$PACKAGE_NAME" PROJECT_MEDIA allow 2>/dev/null || true
$ADB_CMD shell appops set --user 0 "$PACKAGE_NAME" PROJECT_MEDIA allow 2>/dev/null || true

  # [WHATSAPP-DISABLED] Notification Listener Service disabled.
  # echo -e "  → Enabling Notification Listener..."
  # $ADB_CMD shell cmd notification allow_listener "$NOTIFICATION_SERVICE" 2>/dev/null || true
  # $ADB_CMD shell cmd notification allow_listener --user 0 "$NOTIFICATION_SERVICE" 2>/dev/null || true

  # [WHATSAPP-DISABLED] WhatsApp storage permissions disabled.
  # $ADB_CMD shell appops set "$PACKAGE_NAME" MANAGE_EXTERNAL_STORAGE allow 2>/dev/null || true
  # $ADB_CMD shell pm grant "$PACKAGE_NAME" android.permission.READ_MEDIA_AUDIO 2>/dev/null || true
  # $ADB_CMD shell pm grant "$PACKAGE_NAME" android.permission.READ_EXTERNAL_STORAGE 2>/dev/null || true

# 6. Grant Notifications permission (Android 13+)
echo -e "  → Granting notification permissions..."
$ADB_CMD shell pm grant --user 0 "$PACKAGE_NAME" android.permission.POST_NOTIFICATIONS 2>/dev/null || true
$ADB_CMD shell pm grant "$PACKAGE_NAME" android.permission.POST_NOTIFICATIONS 2>/dev/null || true

# 7. Whitelist from Battery Optimization (Unrestricted background execution)
echo -e "  → Whitelisting from battery optimizations (Doze mode)..."
$ADB_CMD shell dumpsys deviceidle whitelist +"$PACKAGE_NAME" 2>/dev/null || true

echo -e "${GREEN}✓ All permissions and services successfully configured!${NC}"

# 5. Launch app if requested
if [ "$LAUNCH_APP" = true ]; then
  echo -e "\n${BLUE}[5/5] Launching $PACKAGE_NAME...${NC}"
  $ADB_CMD shell am start -n "$PACKAGE_NAME/$MAIN_ACTIVITY"
  echo -e "${GREEN}✓ App launched!${NC}"
else
  echo -e "\n${BLUE}[5/5] Done! App is fully provisioned.${NC}"
fi

echo -e "\n${GREEN}======================================================${NC}"
echo -e "${GREEN}  Pirsumoto is ready with zero permission prompts!   ${NC}"
echo -e "${GREEN}======================================================${NC}"
