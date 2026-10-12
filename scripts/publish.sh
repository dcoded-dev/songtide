#!/bin/zsh
# Publishes the release that scripts/release-direct.sh built, once it's committed on main:
# deploys the site (the download and the update feed), checks the live download is the built DMG,
# then pushes main and the Homebrew cask and posts the release on GitHub.
#
#   scripts/publish.sh
#
# GitHub actions run as the dcoded-bot account (gh auth login as that account once).
set -euo pipefail
cd "$(dirname "$0")/.."

SITE=https://songtide.dcoded.dev
VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
DMG=site/releases/Songtide-$VERSION.dmg
NOTES=site/releases/Songtide-$VERSION.html
TAP=${SONGTIDE_TAP:-../homebrew-tap}
[[ -f $DMG ]] || { echo "$DMG doesn't exist; run scripts/release-direct.sh first."; exit 1; }
[[ $(git branch --show-current) == main && -z $(git status --porcelain) ]] || { echo "Commit the release and merge it to main first."; exit 1; }
export GH_TOKEN=$(gh auth token --user dcoded-bot)

echo "▸ Deploying the site…"
npx wrangler deploy | grep -E "Version ID|ERROR" || true

echo "▸ Waiting for $VERSION to be live…"
for attempt in {1..60}; do
  curl -fs "$SITE/appcast.xml" | grep -q ">$VERSION<" && break
  (( attempt == 60 )) && { echo "The live update feed still doesn't list $VERSION."; exit 1; }
  sleep 5
done
LIVE=$(mktemp -t songtide-live).dmg
curl -fsL -A curl -o "$LIVE" "$SITE/releases/Songtide-$VERSION.dmg"
cmp -s "$LIVE" "$DMG" || { echo "The live download differs from $DMG."; exit 1; }
spctl --assess --type open --context context:primary-signature -vv "$LIVE" 2>&1 | head -2
rm -f "$LIVE"

echo "▸ Pushing main, the Homebrew cask and the GitHub release…"
git push -q origin main
[[ -d $TAP/.git ]] && git -C "$TAP" push -q origin main
# Release notes: the bullet points of the update window's notes, as Markdown.
BODY=$(python3 - "$NOTES" <<'PY'
import html, re, sys
try: text = open(sys.argv[1], encoding="utf-8").read()
except OSError: text = ""
for item in re.findall(r"<li>(.*?)</li>", text, re.S):
    print("- " + html.unescape(re.sub(r"<[^>]+>", "", item)).strip())
PY
)
gh release create "v$VERSION" "$DMG" --repo dcoded-dev/songtide --target main --title "Songtide $VERSION" \
  --notes "$BODY

Download above, from [songtide.dcoded.dev]($SITE), or with \`brew install --cask dcoded-dev/tap/songtide\`. Songtide updates itself once installed."

echo "✓ Songtide $VERSION is published."
