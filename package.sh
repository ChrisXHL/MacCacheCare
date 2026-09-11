#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
/bin/zsh build.sh
mkdir -p dist
/usr/bin/codesign --verify --deep --strict 'build/轻缓存.app'
# Stable asset name keeps /releases/latest/download/... usable for each version.
/usr/bin/ditto -c -k --sequesterRsrc --keepParent 'build/轻缓存.app' dist/MacCacheCare-macOS-arm64.zip
(cd dist && /usr/bin/shasum -a 256 MacCacheCare-macOS-arm64.zip > SHA256SUMS.txt)
echo "Packaged version $(cat VERSION) in dist/"
