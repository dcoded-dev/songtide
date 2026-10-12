#!/bin/zsh
# Builds a Developer ID release of Songtide for direct download: archive → export signed with
# "Developer ID Application" → notarized by Apple (notarytool, the songtide-notary keychain profile;
# no Xcode account needed) → stapled → DMG → Sparkle appcast, all written into site/ ready to deploy.
#
#   scripts/release-direct.sh
#
# Needs once: the "songtide-notary" notarytool profile (see the DMG step below).
# Before each release: bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml (Sparkle
# compares CURRENT_PROJECT_VERSION), and write release notes in site/releases/Songtide-<version>.html
# (copy the previous one: its <meta charset> and <style> keep the notes readable in dark mode).
# The appcast is signed with the Sparkle key in the login keychain (generate_keys).
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID=YQ9V6SFRL4
ARCHIVE=build/Songtide-direct.xcarchive
EXPORT_DIR=build/Direct
OPTIONS=build/ExportOptions-direct.plist
SPARKLE_BIN=build/dd/SourcePackages/artifacts/sparkle/Sparkle/bin
SITE=site
RELEASES=$SITE/releases

xcodegen generate -q
VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' project.yml)
DMG_NAME=Songtide-$VERSION.dmg
echo "▸ Songtide $VERSION ($BUILD)"
[[ -f $RELEASES/$DMG_NAME ]] && { echo "$RELEASES/$DMG_NAME already exists; bump the version first."; exit 1; }
[[ -f $RELEASES/Songtide-$VERSION.html ]] || echo "  (no release notes at $RELEASES/Songtide-$VERSION.html; the update window will show none)"

rm -rf "$ARCHIVE" "$EXPORT_DIR"
echo "▸ Archiving…"
xcodebuild -project Songtide.xcodeproj -scheme Songtide -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -derivedDataPath build/dd \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" \
  -allowProvisioningUpdates archive | grep -E "error|ARCHIVE" || true
[[ -d "$ARCHIVE" ]] || { echo "Archive failed"; exit 1; }

cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST

echo "▸ Signing with Developer ID…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" \
  -exportPath "$EXPORT_DIR" | grep -vE "^\s*$" | tail -3
APP=$EXPORT_DIR/Songtide.app
[[ -d "$APP" ]] || { echo "Export failed"; exit 1; }

echo "▸ Notarizing the app (usually a few minutes)…"
ditto -c -k --keepParent "$APP" build/Songtide-notarize.zip
xcrun notarytool submit build/Songtide-notarize.zip --keychain-profile songtide-notary --wait | tail -3
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute -vv "$APP" 2>&1 | head -2

echo "▸ Making $DMG_NAME…"
# A styled installer window: background with an arrow to Applications, fixed icon positions.
# dmgbuild lives in build/tools-venv (python3 -m venv build/tools-venv && build/tools-venv/bin/pip install dmgbuild).
python3 scripts/dmg/make-background.py build/dmg-bg.png build/dmg-bg@2x.png
tiffutil -cathidpicheck build/dmg-bg.png build/dmg-bg@2x.png -out build/dmg-bg.tiff >/dev/null
mkdir -p "$RELEASES"
build/tools-venv/bin/dmgbuild -s scripts/dmg/dmg-settings.py -D app="$APP" -D background=build/dmg-bg.tiff \
  Songtide "$RELEASES/$DMG_NAME" >/dev/null
codesign --sign "Developer ID Application: WORDPRESSDEV, LLC ($TEAM_ID)" --timestamp "$RELEASES/$DMG_NAME"

# The DMG is notarized too, or a downloaded copy may not open ("can't be checked for malicious
# software"). notarytool can't use Xcode's account; it uses a saved keychain profile, made once with:
#   xcrun notarytool store-credentials songtide-notary --apple-id <Apple ID> --team-id YQ9V6SFRL4
echo "▸ Notarizing the DMG…"
xcrun notarytool submit "$RELEASES/$DMG_NAME" --keychain-profile songtide-notary --wait | tail -3
xcrun stapler staple "$RELEASES/$DMG_NAME"
spctl --assess --type open --context context:primary-signature -vv "$RELEASES/$DMG_NAME" 2>&1 | head -2

echo "▸ Updating the appcast…"
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "https://songtide.dcoded.dev/releases/" \
  --link "https://songtide.dcoded.dev" --embed-release-notes -o "$SITE/appcast.xml" "$RELEASES"
# The site's Download button always points at the newest DMG.
print -r -- "/download /releases/$DMG_NAME 302" > "$SITE/_redirects"

# The home page says which version the Download button gets.
sed -i '' -E "s|(<span class=\"version\">)[^<]*(</span>)|\\1Version $VERSION · $(date '+%-d %B %Y')\\2|" "$SITE/index.html"

# The Homebrew cask (github.com/dcoded-dev/homebrew-tap, cloned next to this repo) points at the
# new DMG. Committed here; scripts/publish.sh pushes it once the site is live (before that, brew
# would get a 404 for the download).
TAP=${SONGTIDE_TAP:-../homebrew-tap}
if [[ -f $TAP/Casks/songtide.rb ]]; then
  SHA=$(shasum -a 256 "$RELEASES/$DMG_NAME" | cut -d' ' -f1)
  sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TAP/Casks/songtide.rb"
  git -C "$TAP" commit -qam "Songtide $VERSION" && echo "▸ Homebrew cask updated to $VERSION"
fi

echo "✓ $RELEASES/$DMG_NAME and $SITE/appcast.xml are ready. Commit, merge to main, then publish:"
echo "  scripts/publish.sh"
