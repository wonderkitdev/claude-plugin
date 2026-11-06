#!/usr/bin/env bash
# Pin a runner release into connect.sh (plan Task 16, ruling R2; Ian runs it at
# release, Task 19):
#
#   scripts/bump-runner.sh <version> <arm64.tar.gz> [<x64.tar.gz>]
#
# Rewrites ONLY the release-constant block of scripts/connect.sh (beside this
# script): RUNNER_VERSION and the per-arch tarball SHA-256s — and the
# "version" line of .claude-plugin/plugin.json, set to the same version.
# Claude Code caches an installed plugin by its manifest version, so a runner
# bump that left the manifest alone was never picked up by /plugin update
# (runner 0.1.1, 2026-11-06: the cached 0.1.0 connect.sh kept installing 0.1.0). With no x64
# tarball the x64 hash is set back to the placeholder, so connect.sh refuses
# Intel Macs with a clear message instead of a wrong hash. Each tarball must
# be named wonderkit-runner-<version>-darwin-<arch>.tar.gz — the name the
# GitHub release asset must carry for the download URL to resolve.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$HERE/connect.sh"
MANIFEST="$HERE/../.claude-plugin/plugin.json"
PLACEHOLDER="REPLACE_AT_RELEASE"

usage() { echo "usage: bump-runner.sh <version> <arm64.tar.gz> [<x64.tar.gz>]" >&2; exit 2; }
[[ $# -ge 2 && $# -le 3 ]] || usage
VERSION="$1"; ARM64="$2"; X64="${3:-}"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "bump-runner.sh: '$VERSION' is not a version (expected e.g. 1.2.3 or 1.2.3-rc.1)" >&2; exit 2
fi
[[ -f "$TARGET" ]] || { echo "bump-runner.sh: $TARGET not found" >&2; exit 2; }
[[ -f "$MANIFEST" ]] || { echo "bump-runner.sh: plugin manifest $MANIFEST not found" >&2; exit 2; }
if [[ "$(grep -c '^  "version": "[^"]*",$' "$MANIFEST")" != 1 ]]; then
  echo "bump-runner.sh: expected exactly one '  \"version\": \"…\",' line in $MANIFEST" >&2; exit 2
fi

check_tarball() {  # path arch
  [[ -f "$1" ]] || { echo "bump-runner.sh: $1 does not exist" >&2; exit 2; }
  local want="wonderkit-runner-$VERSION-darwin-$2.tar.gz"
  if [[ "$(basename "$1")" != "$want" ]]; then
    echo "bump-runner.sh: $(basename "$1") must be named $want (the release asset name connect.sh downloads)" >&2; exit 2
  fi
}
check_tarball "$ARM64" arm64
ARM64_SHA="$(shasum -a 256 "$ARM64" | awk '{print $1}')"
X64_SHA="$PLACEHOLDER"
if [[ -n "$X64" ]]; then
  check_tarball "$X64" x64
  X64_SHA="$(shasum -a 256 "$X64" | awk '{print $1}')"
fi

for key in RUNNER_VERSION RUNNER_SHA256_ARM64 RUNNER_SHA256_X64; do
  if [[ "$(grep -c "^$key=" "$TARGET")" != 1 ]]; then
    echo "bump-runner.sh: expected exactly one '$key=' line in $TARGET" >&2; exit 2
  fi
done

TMP="$(mktemp "$HERE/.connect.sh.XXXXXX")"
MTMP="$(mktemp "$HERE/.plugin.json.XXXXXX")"
trap 'rm -f "$TMP" "$MTMP"' EXIT
sed -e "s|^  \"version\": \"[^\"]*\",\$|  \"version\": \"$VERSION\",|" "$MANIFEST" >"$MTMP"
sed -e "s|^RUNNER_VERSION=.*|RUNNER_VERSION=\"$VERSION\"|" \
    -e "s|^RUNNER_SHA256_ARM64=.*|RUNNER_SHA256_ARM64=\"$ARM64_SHA\"|" \
    -e "s|^RUNNER_SHA256_X64=.*|RUNNER_SHA256_X64=\"$X64_SHA\"|" \
    "$TARGET" >"$TMP"
cat "$TMP" >"$TARGET"   # keeps connect.sh's mode and inode
cat "$MTMP" >"$MANIFEST"

echo "pinned in $TARGET:"
grep -n '^RUNNER_VERSION=\|^RUNNER_SHA256_' "$TARGET"
echo "plugin version in $MANIFEST:"
grep -n '"version"' "$MANIFEST"
echo "release asset URL: https://github.com/wonderkitdev/claude-plugin/releases/download/runner-v$VERSION/$(basename "$ARM64")"
