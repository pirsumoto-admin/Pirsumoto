#!/bin/bash
# ==============================================================================
# Script: setup_kiosk_device.sh
# Description: Installs Pirsumoto, sets it as Device Owner, grants permissions, 
#              and configures the device for Kiosk Mode (Lock Task Mode).
#
# IMPORTANT PREREQUISITES:
# 1. The device MUST have all Google/User accounts removed (or be factory reset).
# 2. The app MUST have a DeviceAdminReceiver registered in AndroidManifest.xml.
# ==============================================================================

set -e

PACKAGE_NAME="com.pirsumotoapp"
MAIN_ACTIVITY="com.pirsumoto.app.MainActivity"
# NOTE: You must create this receiver in your Android code for Device Owner to work!
ADMIN_RECEIVER="com.pirsumoto.app.DeviceAdminReceiver" 

ADB_CMD="adb"
if [ ! -z "$1" ]; then
  echo "Using specific device: $1"
  ADB_CMD="$ADB_CMD -s $1"
fi

echo "======================================================"
echo "      Pirsumoto Kiosk Mode Provisioning Script        "
echo "======================================================"

# 0. Remove Device Owner (Exit Kiosk Mode) before installing to avoid blocked prompts
echo -e "\n[0/4] Removing existing Device Owner to exit Kiosk Mode..."
$ADB_CMD shell dpm remove-active-admin "$PACKAGE_NAME/$ADMIN_RECEIVER" 2>/dev/null || true

# 1. Install the App First
# You cannot set an app as Device Owner if it is not installed on the device.
echo -e "\n[1/4] Building and Installing Pirsumoto App..."
flutter build apk --release
$ADB_CMD push build/app/outputs/flutter-apk/app-release.apk /data/local/tmp/app.apk
$ADB_CMD shell pm install -t -r -d /data/local/tmp/app.apk

# 2. Set as Device Owner
# This command will FAIL if there are any accounts on the device (e.g., in Settings -> Accounts)
echo -e "\n[2/4] Setting $PACKAGE_NAME as Device Owner..."
echo "Note: If this fails, ensure ALL accounts are removed from the device settings."
$ADB_CMD shell dpm set-device-owner "$PACKAGE_NAME/$ADMIN_RECEIVER" || true

# 3. Grant Permissions (Reusing logic from your previous script)
echo -e "\n[3/4] Granting required permissions via ADB..."
# Allow Restricted Settings (Android 13+)
$ADB_CMD shell appops set "$PACKAGE_NAME" ACCESS_RESTRICTED_SETTINGS allow 2>/dev/null || true
# Accessibility Service
ACCESSIBILITY_SERVICE="$PACKAGE_NAME/com.pirsumoto.app.PirsumotoAccessibilityService"
EXISTING_A11Y=$($ADB_CMD shell settings get secure enabled_accessibility_services | tr -d '\r')
if [[ "$EXISTING_A11Y" != *"$ACCESSIBILITY_SERVICE"* ]]; then
  NEW_A11Y="${EXISTING_A11Y:+$EXISTING_A11Y:}$ACCESSIBILITY_SERVICE"
  $ADB_CMD shell settings put secure enabled_accessibility_services "$NEW_A11Y" 2>/dev/null || true
fi
$ADB_CMD shell settings put secure accessibility_enabled 1 2>/dev/null || true
# Media Projection
$ADB_CMD shell appops set "$PACKAGE_NAME" PROJECT_MEDIA allow 2>/dev/null || true
# Notifications
$ADB_CMD shell pm grant "$PACKAGE_NAME" android.permission.POST_NOTIFICATIONS 2>/dev/null || true
# Battery Optimization Whitelist
$ADB_CMD shell dumpsys deviceidle whitelist +"$PACKAGE_NAME" 2>/dev/null || true

# 4. Enable Lock Task Mode (Kiosk Mode)
# This allows the app to pin itself to the screen without user prompts.
echo -e "\n[4/4] Launching App in Kiosk Mode..."
# Note: True Kiosk mode requires the app to call startLockTask() in its onCreate() method
# once it verifies it is the Device Owner.
$ADB_CMD shell am start -n "$PACKAGE_NAME/$MAIN_ACTIVITY"

echo -e "\n======================================================"
echo " Provisioning Complete!"
echo "======================================================"
