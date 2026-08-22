#!/usr/bin/env bash
# Download the two sidebar/status plugins into ~/.config/zellij/plugins/.
# Both ship prebuilt wasm, so no Rust toolchain is needed.
set -euo pipefail
DEST="${1:-$HOME/.config/zellij/plugins}"
mkdir -p "$DEST"

curl -sSL --fail -o "$DEST/zellij-vertical-tabs.wasm" \
  https://github.com/cfal/zellij-vertical-tabs/releases/download/v0.1.0/zellij-vertical-tabs.wasm
curl -sSL --fail -o "$DEST/zjstatus.wasm" \
  https://github.com/dj95/zjstatus/releases/download/v0.24.0/zjstatus.wasm

file "$DEST/zellij-vertical-tabs.wasm" "$DEST/zjstatus.wasm"
