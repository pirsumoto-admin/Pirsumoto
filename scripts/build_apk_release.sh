#!/bin/bash
# ==============================================================================
# Script: build_apk_release.sh
# Description: Builds release APK for Pirsumoto with optional clean & split-per-abi
# Usage:
#   ./scripts/build_apk_release.sh [OPTIONS]
#
# Options:
#   -c, --clean          Run 'flutter clean' and 'flutter pub get' before building
#   --split-per-abi      Build separate APKs per CPU architecture (arm64, armeabi, x86_64)
#   -h, --help           Show help message
# ==============================================================================

set -e

# Formatting colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

CLEAN_BUILD=false
SPLIT_PER_ABI=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -c|--clean)
      CLEAN_BUILD=true
      shift
      ;;
    --split-per-abi)
      SPLIT_PER_ABI=true
      shift
      ;;
    -h|--help)
      echo -e "${BLUE}Pirsumoto - Build Release APK${NC}"
      echo ""
      echo "Usage: ./scripts/build_apk_release.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  -c, --clean          Run 'flutter clean' and 'flutter pub get' first"
      echo "  --split-per-abi      Build separate smaller APKs per architecture"
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

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   Building Pirsumoto Release APK       ${NC}"
echo -e "${BLUE}========================================${NC}"

if [ "$CLEAN_BUILD" = true ]; then
  echo -e "\n${YELLOW}Running flutter clean & pub get...${NC}"
  flutter clean
  flutter pub get
fi

BUILD_ARGS=("build" "apk" "--release")
if [ "$SPLIT_PER_ABI" = true ]; then
  BUILD_ARGS+=("--split-per-abi")
fi

echo -e "\n${BLUE}Executing: flutter ${BUILD_ARGS[*]}${NC}\n"
flutter "${BUILD_ARGS[@]}"

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}   Build Completed Successfully!        ${NC}"
echo -e "${GREEN}========================================${NC}"

OUTPUT_DIR="build/app/outputs/flutter-apk"
if [ "$SPLIT_PER_ABI" = true ]; then
  echo -e "APKs generated at:"
  ls -lh "$OUTPUT_DIR"/*.apk
else
  echo -e "APK generated at:"
  echo -e "${GREEN}${OUTPUT_DIR}/app-release.apk${NC} ($(du -h "${OUTPUT_DIR}/app-release.apk" | cut -f1))"
fi
