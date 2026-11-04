#!/bin/bash
# Kör enhetsproven i RecorderKit med Xcodes verktygskedja (Testing finns inte i CLT).
set -euo pipefail
cd "$(dirname "$0")/../RecorderKit"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift test "$@"
