#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PROJECT_ROOT/dist"
VERSION="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="$DIST_DIR/vacation-registry-$VERSION.tar.gz"

mkdir -p "$DIST_DIR"

tar \
  --exclude='.git' \
  --exclude='.venv' \
  --exclude='dist' \
  --exclude='__pycache__' \
  -czf "$ARCHIVE" \
  -C "$PROJECT_ROOT" .

echo "Created: $ARCHIVE"
