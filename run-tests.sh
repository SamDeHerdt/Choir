#!/bin/bash
# Headless checks: parsing, prompt assembly, and one live round trip per CLI bridge.
set -euo pipefail
cd "$(dirname "$0")"
BUILD_DIR=$(mktemp -d); trap 'rm -rf "$BUILD_DIR"' EXIT
SOURCES=(Sources/Models.swift Sources/Engines.swift Sources/CLIEngines.swift Sources/Design.swift Sources/Markdown.swift Sources/MCPServer.swift Sources/Discovery.swift Sources/Store.swift Tests/TestMain.swift)
swiftc -parse-as-library -swift-version 5 -module-cache-path "$BUILD_DIR/ModuleCache" \
  -target arm64-apple-macos14.0 "${SOURCES[@]}" -o "$BUILD_DIR/tests"
"$BUILD_DIR/tests"
