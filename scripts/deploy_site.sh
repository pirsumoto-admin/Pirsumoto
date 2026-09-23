#!/bin/bash
# ==============================================================================
# Script: deploy_site.sh
# Description: Builds and deploys the Pirsumoto Next.js landing site to Firebase Hosting
# Usage:
#   ./scripts/deploy_site.sh [OPTIONS]
#
# Options:
#   -b, --build-only     Build Next.js static export without deploying
#   -p, --project <id>   Specify Firebase project ID (default: car-publisher)
#   -h, --help           Show this help message
# ==============================================================================

set -e

# Formatting colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Determine script & site directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SITE_DIR="$ROOT_DIR/pirsumoto-site"

DEFAULT_PROJECT="car-publisher"
PROJECT_ID="$DEFAULT_PROJECT"
BUILD_ONLY=false

# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -b|--build-only)
      BUILD_ONLY=true
      shift
      ;;
    -p|--project)
      PROJECT_ID="$2"
      shift 2
      ;;
    -h|--help)
      echo -e "${BLUE}Pirsumoto Site - Build & Deploy to Firebase Hosting${NC}"
      echo ""
      echo "Usage: ./scripts/deploy_site.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  -b, --build-only     Build Next.js static export without deploying"
      echo "  -p, --project <id>   Firebase project ID (default: ${DEFAULT_PROJECT})"
      echo "  -h, --help           Show this help message"
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}"
      echo "Use -h or --help for usage."
      exit 1
      ;;
  esac
done

echo -e "${BLUE}=== Pirsumoto Site: Build & Deploy ===${NC}"
echo -e "Site directory: ${YELLOW}${SITE_DIR}${NC}"
echo -e "Firebase project: ${YELLOW}${PROJECT_ID}${NC}"
echo ""

if [ ! -d "$SITE_DIR" ]; then
  echo -e "${RED}Error: Site directory not found at $SITE_DIR${NC}"
  exit 1
fi

cd "$SITE_DIR"

# Check dependencies
if ! command -v npm &> /dev/null; then
  echo -e "${RED}Error: npm is not installed or not in PATH.${NC}"
  exit 1
fi

# 1. Install dependencies if node_modules missing
if [ ! -d "node_modules" ]; then
  echo -e "${YELLOW}Installing node dependencies...${NC}"
  npm install
fi

# 2. Build Next.js static export
echo -e "${BLUE}[1/2] Building Next.js static export...${NC}"
npm run build

if [ ! -d "out" ]; then
  echo -e "${RED}Error: 'out' directory not found after build.${NC}"
  exit 1
fi

echo -e "${GREEN}✓ Build completed successfully (output in ${SITE_DIR}/out)${NC}"

if [ "$BUILD_ONLY" = true ]; then
  echo -e "${GREEN}Build-only flag specified. Skipping Firebase deployment.${NC}"
  exit 0
fi

# 3. Deploy to Firebase Hosting
echo ""
echo -e "${BLUE}[2/2] Deploying to Firebase Hosting (${PROJECT_ID})...${NC}"

if command -v firebase &> /dev/null; then
  firebase deploy --only hosting --project "$PROJECT_ID"
else
  echo -e "${YELLOW}'firebase' CLI not found globally, falling back to npx firebase-tools...${NC}"
  npx -y firebase-tools deploy --only hosting --project "$PROJECT_ID"
fi

echo ""
echo -e "${GREEN}=== Deployment Complete! ===${NC}"
echo -e "Live URL: ${BLUE}https://${PROJECT_ID}.web.app${NC} / ${BLUE}https://${PROJECT_ID}.firebaseapp.com${NC} (or custom domain https://pirsumoto.com)"
