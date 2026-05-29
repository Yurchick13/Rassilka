#!/usr/bin/env bash
set -euo pipefail
systemctl stop vacation-registry >/dev/null 2>&1 || true
systemctl disable vacation-registry >/dev/null 2>&1 || true
