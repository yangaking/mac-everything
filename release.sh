#!/bin/bash
set -euo pipefail

# =============================================================================
# MacEverything — standard release pipeline
#
# Usage:   ./release.sh <new-version>      (e.g. ./release.sh 0.1.9)
#
# Steps:
#   1) bump version (Cargo.toml + build.sh CFBundleShortVersionString/Build)
#   2) cargo test (must be green)
#   3) ./build.sh (release build + ad-hoc sign)
#   4) verify code signature (--deep --strict)
#   5) package DMG (hdiutil UDZO + /Applications symlink)
#   6) verify DMG checksum
#   7) commit + tag + push (main + tag)
#   8) create GitHub release + upload DMG + verify latest
# =============================================================================

NEW_VERSION="${1:?usage: ./release.sh <new-version> (e.g. 0.1.9)}"
TAG="v${NEW_VERSION}"
DMG="MacEverything-${NEW_VERSION}.dmg"
REPO="yangaking/mac-everything"

if [ -d "$HOME/.cargo/bin" ]; then
    export PATH="$HOME/.cargo/bin:$PATH"
fi

echo "==> Releasing ${NEW_VERSION} (tag ${TAG})"

# Capture the changelog BEFORE the bump commit: feature commits since last tag.
PREV_TAG=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
if [ -n "$PREV_TAG" ]; then
    CHANGELOG=$(git log --pretty=format:'- %s' "$PREV_TAG"..HEAD)
else
    CHANGELOG=$(git log --pretty=format:'- %s' -n 30)
fi
if [ -z "$CHANGELOG" ]; then
    CHANGELOG="- ${NEW_VERSION}"
fi

# --- 1. Bump version ---------------------------------------------------------
echo "==> [1/8] Bump version -> ${NEW_VERSION}"
python3 - "$NEW_VERSION" <<'PYEOF'
import re, sys
v = sys.argv[1]

p = "mac-everything-core/Cargo.toml"
s = open(p).read()
s = re.sub(r'^version = ".*"$', f'version = "{v}"', s, count=1, flags=re.M)
open(p, "w").write(s)

p = "build.sh"
s = open(p).read()
s = re.sub(r'(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*(</string>)',
           lambda m: f'{m.group(1)}{v}{m.group(2)}', s, count=1)
m = re.search(r'<key>CFBundleVersion</key>\s*<string>(\d+)</string>', s)
cur = int(m.group(1))
s = re.sub(r'(<key>CFBundleVersion</key>\s*<string>)\d+(</string>)',
           lambda mm: f'{mm.group(1)}{cur + 1}{mm.group(2)}', s, count=1)
open(p, "w").write(s)
print(f"    CFBundleVersion {cur} -> {cur + 1}")
PYEOF

# --- 2. Tests ----------------------------------------------------------------
echo "==> [2/8] cargo test"
(cd mac-everything-core && cargo test 2>&1 | tail -n 15)

# --- 3. Build ----------------------------------------------------------------
echo "==> [3/8] build.sh"
./build.sh

# --- 4. Verify signature -----------------------------------------------------
echo "==> [4/8] verify code signature"
codesign --verify --deep --strict build/MacEverything.app
echo "    signature OK"

# --- 5. Package DMG ----------------------------------------------------------
echo "==> [5/8] package ${DMG}"
STAGE="$(mktemp -d)"
cp -R build/MacEverything.app "$STAGE/"
ln -sfn /Applications "$STAGE/Applications"
hdiutil create -volname "MacEverything" -srcfolder "$STAGE" -ov -format UDZO "$DMG" | tail -n 1
rm -rf "$STAGE"

# --- 6. Verify DMG -----------------------------------------------------------
echo "==> [6/8] verify DMG checksum"
hdiutil verify "$DMG" | tail -n 1

# --- 7. Commit + tag + push --------------------------------------------------
echo "==> [7/8] commit + tag + push"
git add build.sh mac-everything-core/Cargo.toml mac-everything-core/Cargo.lock
git commit -m "chore: bump version to ${NEW_VERSION}"
git tag "$TAG"
git push origin main
git push origin "$TAG"

# --- 8. GitHub release -------------------------------------------------------
echo "==> [8/8] create GitHub release + upload DMG"
CRED=$(printf "protocol=https\nhost=github.com\n\n" | git credential fill)
TOKEN=$(printf '%s\n' "$CRED" | sed -n 's/^password=//p')
if [ -z "$TOKEN" ]; then
    echo "ERROR: no GitHub token from 'git credential fill'" >&2
    exit 1
fi

BODY=$(printf '## Changes\n%s\n' "$CHANGELOG")
PAYLOAD=$(python3 -c 'import json,sys; print(json.dumps({"tag_name": sys.argv[1], "name": "MacEverything " + sys.argv[1], "body": sys.argv[2], "draft": False, "prerelease": False}))' "$TAG" "$BODY")

RESP=$(curl -sS -X POST "https://api.github.com/repos/${REPO}/releases" \
    -H "Authorization: token $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")

if ! printf '%s' "$RESP" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
    echo "ERROR: failed to create release" >&2
    echo "$RESP" >&2
    exit 1
fi

RELEASE_ID=$(printf '%s' "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
UPLOAD_URL=$(printf '%s' "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["upload_url"])')
BASE_UPLOAD=$(printf '%s' "$UPLOAD_URL" | sed 's/{.*}//')

echo "    release id: ${RELEASE_ID}"
curl -sS -X POST "${BASE_UPLOAD}?name=${DMG}" \
    -H "Authorization: token $TOKEN" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@${DMG}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print("    asset:", d.get("name"), d.get("state"), d.get("size"), "bytes")'

# --- Verify latest -----------------------------------------------------------
echo "==> verify latest"
curl -sS "https://api.github.com/repos/${REPO}/releases/latest" -H "Authorization: token $TOKEN" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print("    latest:", d["tag_name"], "| assets:", [a["name"] for a in d["assets"]])'

echo ""
echo "==> Release complete: https://github.com/${REPO}/releases/tag/${TAG}"
