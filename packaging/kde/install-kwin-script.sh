#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$SCRIPT_DIR/kwin/ztrans_popup"

if ! command -v kpackagetool6 >/dev/null 2>&1; then
    echo "kpackagetool6 not found. Install KDE Plasma 6 tooling first." >&2
    exit 1
fi

if kpackagetool6 --type KWin/Script --upgrade "$PACKAGE_DIR" >/dev/null 2>&1; then
    echo "Updated KWin script: ztrans_popup"
else
    kpackagetool6 --type KWin/Script --install "$PACKAGE_DIR"
    echo "Installed KWin script: ztrans_popup"
fi

if command -v qdbus6 >/dev/null 2>&1; then
    qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
elif command -v qdbus >/dev/null 2>&1; then
    qdbus org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
fi

echo
echo "Next:"
echo "1. Open System Settings > Window Management > KWin Scripts."
echo "2. Ensure \"ZTrans Popup Anchor\" is enabled."
echo "3. Keep your global shortcut bound to: ztrans"
