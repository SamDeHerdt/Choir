#!/bin/bash
# Choir.dmg for colleagues: blank read-write image → copy app + Applications
# link → convert to compressed read-only. (hdiutil create -srcfolder hits
# "Resource busy" on some Macs; this route does not.)
set -euo pipefail
cd "$(dirname "$0")"
APP="Choir.app"; [ -d "$APP" ] || { echo "Build first: bash build.sh"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
OUT="Choir-$VERSION.dmg"; WORK=$(mktemp -d); RW="$WORK/rw.dmg"; MNT="$WORK/mnt"
hdiutil create -size 80m -fs HFS+ -volname "Choir" -layout NONE "$RW" >/dev/null
mkdir -p "$MNT"; hdiutil attach "$RW" -mountpoint "$MNT" -nobrowse -quiet
cp -R "$APP" "$MNT/"; ln -s /Applications "$MNT/Applications"
cat > "$MNT/Start Here.txt" <<'TXT'
Choir — one thread for every AI model you already pay for.

1. Drag Choir to Applications.
2. First open: Control-click Choir → Open → Open.
3. Sign in to the AIs you use, in Terminal:
     claude login      (Claude Pro / Max)
     codex login       (ChatGPT Plus / Pro / Team)
   Local models: install Ollama from ollama.com.
4. In Choir, press Find models.

Full guide: README in the project, or Help › Show Me Around inside the app.
TXT
hdiutil detach "$MNT" -quiet
rm -f "$OUT"; hdiutil convert "$RW" -format UDZO -o "$OUT" >/dev/null; hdiutil verify "$OUT" >/dev/null
rm -rf "$WORK"; echo "Wrote $OUT"
