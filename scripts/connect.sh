#!/usr/bin/env bash
# /wonderkit:connect — install Wonderkit's builder runner on this Mac and link
# it to the parent's family (plan Task 16). Claude Code runs this in two Bash
# calls because a call is capped at 10 min and its output shows only at the end:
#
#   connect.sh           phase 1: platform checks → download, verify, extract
#                        → `doctor --json --deep` → `install --browser-only`
#                        (Chromium, the slow one-time download, so phase 2
#                        fits the cap) → `link --start` (prints the code,
#                        opens the browser, saves the pending link) → exit 0
#   connect.sh --finish  phase 2: `link --finish --timeout 420` → `install`
#                        → `selftest` → the success lines
#
# Layout (ruling R1): the package is extracted to ~/.wonderkit/versions/<v>/
# (a space-free path — the runner refuses paths with spaces) and
# ~/.wonderkit/runner is a SYMLINK to the current version, swapped atomically.
# `install --root ~/.wonderkit/runner` puts that SYMLINK path in the plist, so
# launchd always starts the current version. The runner's own home (token,
# sessions, logs) is ~/Library/Application Support/Wonderkit; this script
# never writes there — only the runner does (it reads the installed plist, to
# learn which version launchd names). At most the 2 newest versions are kept,
# never the one `runner` points at nor the one the plist names.
#
# Server-sourced text (family name, the runner's relayed lines, error text)
# is stripped of control/ANSI characters and capped before it is printed:
# the output goes into Claude's context verbatim.
#
# Trust root (ruling R2): the constants below, shipped inside the plugin. The
# tarball must hash to the pinned SHA-256 before anything is extracted, and the
# package's own SHA256SUMS must then verify every file.
#
# Every failure prints one plain line and the next step — never a stack trace.
set -u
set -o pipefail

# ---- release constants (rewritten by scripts/bump-runner.sh at release) ----
RUNNER_VERSION="0.1.0"
RUNNER_SHA256_ARM64="cc5081b10e887b68eda0f5d34a272047ddae2b1b65c79f761858740f1115d866"
RUNNER_SHA256_X64="REPLACE_AT_RELEASE"
# ---- end release constants --------------------------------------------------

# The same constant as apps/web/public/portal/builder.js:22 (PLUGIN_REPO): the
# portal's install instructions and this download name one repo.
PLUGIN_REPO="wonderkitdev/claude-plugin"
PLACEHOLDER="REPLACE_AT_RELEASE"

# Test-only overrides (test/connect.test.sh): the fixture server (an
# http://127.0.0.1 base is allowed only through this), the expected tarball
# hash — honoured ONLY together with a loopback-http base, so one stray
# variable can never downgrade a real run — and the directory that stands
# in for ~.
BASE_URL_OVERRIDE="${WK_CONNECT_BASE_URL:-}"
SHA_OVERRIDE="${WK_CONNECT_SHA256:-}"
HOME_ROOT="${WK_CONNECT_HOME_ROOT:-$HOME}"

# Exactly http://127.0.0.1[:port][/path] — parsed, not globbed: userinfo
# (`http://127.0.0.1:@other.host/`) or a longer host never pass.
loopback_http() { [[ "$1" =~ ^http://127\.0\.0\.1(:[0-9]{1,5})?(/[^[:space:]@]*)?$ ]]; }

say() { printf '%s\n' "$@"; }
# fail <exit-code> <line>... — the lines, then exit.
fail() { local code="$1"; shift; printf '%s\n' "$@"; exit "$code"; }
# clean <max> — stdin → one safe line: ANSI CSI sequences, then every control
# character (a bare ESC included) removed, then capped at <max> characters.
ESC=$'\033'
clean() {
  local s
  s="$(cat)"
  s="$(printf '%s' "$s" | LC_ALL=C sed -E "s/${ESC}\\[[0-9;?]*[ -\\/]*[@-~]//g" | LC_ALL=C tr -d '\000-\037\177')"
  printf '%s' "${s:0:$1}"
}
FAMILY_MAX=60
ERROR_MAX=200
LINE_MAX=512
# The last non-empty line of a file, cleaned (error text from the runner / server).
last_line() { awk 'NF { l = $0 } END { print l }' "$1" 2>/dev/null | clean "$ERROR_MAX"; }

MODE="phase1"
case "${1:-}" in
  "") ;;
  --finish) MODE="finish" ;;
  *) fail 2 "usage: connect.sh [--finish]" ;;
esac

# ---- 1. platform ------------------------------------------------------------
if [[ "$(uname -s 2>/dev/null)" != "Darwin" ]]; then
  fail 2 "Wonderkit's builder is macOS only for now. Windows is coming."
fi
ARCH=""
case "$(uname -m 2>/dev/null)" in
  arm64) ARCH="arm64" ;;
  x86_64)
    # Under Rosetta uname says x86_64 on an Apple Silicon Mac; the hardware knows.
    if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" == "1" ]]; then ARCH="arm64"; else ARCH="x64"; fi ;;
  *) fail 2 "This Mac's processor ($(uname -m)) isn't supported by the Wonderkit builder." ;;
esac

WK_HOME="$HOME_ROOT/.wonderkit"
# The runner's install check admits exactly ^/[A-Za-z0-9_./@+-]+$ (its
# bundled Node is named inside a single-quoted shell string).
case "$WK_HOME" in
  /*) ;;
  *) fail 1 "Your home folder's path ($WK_HOME) isn't absolute. This Mac can't host the builder." ;;
esac
case "$WK_HOME" in
  *[!A-Za-z0-9_./@+-]*) fail 1 "Your home folder's path ($WK_HOME) has a space or an unusual character, which the Wonderkit builder can't run from. This Mac can't host the builder yet." ;;
esac

VERSIONS="$WK_HOME/versions"
RUNNER_LINK="$WK_HOME/runner"
RUNNER="$RUNNER_LINK/bin/wonderkit-runner"
# The installed agent (read only, to learn which version launchd names).
PLIST="$HOME_ROOT/Library/LaunchAgents/dev.wonderkit.runner.plist"
LOG="$WK_HOME/connect.log"
mkdir -p "$WK_HOME" || fail 1 "Couldn't create $WK_HOME. Check that your home folder is writable, then run /wonderkit:connect again."
printf '\n== %s connect.sh %s (plugin runner %s)\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${1:---start}" "$RUNNER_VERSION" >>"$LOG"
# Every temp file/dir this script makes, removed on exit (normal or interrupted).
ERR="$(mktemp "${TMPDIR:-/tmp}/wk-connect-err.XXXXXX")"
DOC="$(mktemp "${TMPDIR:-/tmp}/wk-connect-doc.XXXXXX")"
SELF="$(mktemp "${TMPDIR:-/tmp}/wk-connect-self.XXXXXX")"
PART=""; EXTRACT=""; LINK_TMP=""
cleanup() { rm -f "$ERR" "$DOC" "$SELF"; [[ -n "$PART" ]] && rm -f "$PART"; [[ -n "$EXTRACT" ]] && rm -rf "$EXTRACT"; [[ -n "$LINK_TMP" ]] && rm -f "$LINK_TMP"; return 0; }
trap cleanup EXIT

# Run the runner with its stdout to $1 (a file, or /dev/stdout) and stderr
# captured in $ERR and appended to the log; returns its exit code.
runner() {
  local stdout_to="$1"; shift
  : >"$ERR"
  "$RUNNER" "$@" >"$stdout_to" 2>"$ERR"
  local code=$?
  { printf -- '-- %s (exit %s)\n' "$*" "$code"; cat "$ERR"; } >>"$LOG"
  return "$code"
}

# ---- phase 2 ----------------------------------------------------------------
if [[ "$MODE" == "finish" ]]; then
  if [[ ! -x "$RUNNER" ]]; then
    fail 1 "The Wonderkit builder isn't downloaded yet. Run /wonderkit:connect first (without --finish)."
  fi

  # 7 min for the parent's confirmation: with install (Chromium already
  # fetched in phase 1) and selftest (≤ 60 s) after it, the phase stays
  # inside the Bash tool's 10 min cap.
  runner /dev/null link --finish --timeout 420
  code=$?
  case "$code" in
    0) ;;
    3) fail 3 "The code expired — run /wonderkit:connect again" ;;
    4) fail 4 "Wonderkit isn't accepting new computers right now. Try /wonderkit:connect again later." ;;
    *) fail "$code" "Couldn't finish linking this Mac: $(last_line "$ERR")" "Run /wonderkit:connect again." ;;
  esac
  LINKED_LINE="✓ Linked to your Wonderkit family"

  # The plist names the SYMLINK path (R1): launchd always starts the current version.
  runner /dev/null install --root "$RUNNER_LINK"
  code=$?
  if [[ $code -ne 0 ]]; then
    say "$LINKED_LINE"
    fail "$code" "Couldn't install the Wonderkit builder: $(last_line "$ERR")" "Fix that, then run /wonderkit:connect again."
  fi
  INSTALLED_LINE="✓ Installed the Wonderkit builder (starts when you log in)"

  runner "$SELF" selftest
  code=$?
  family="$(sed -n 's/^Linked to \(.*\); the runner is online\.$/\1/p' "$SELF" | tail -1 | clean "$FAMILY_MAX")"
  cat "$SELF" >>"$LOG"
  case "$code" in
    0)
      # Family names are "<parent>'s family" (the web's onboarding), so don't
      # double the word; a name without it gets the mock's "the <name> family".
      if [[ -n "$family" && "$family" != "(no family)" ]]; then
        shopt -s nocasematch
        if [[ "$family" == *" family" ]]; then LINKED_LINE="✓ Linked to $family"; else LINKED_LINE="✓ Linked to the $family family"; fi
        shopt -u nocasematch
      fi
      say "$LINKED_LINE" "$INSTALLED_LINE" "✓ Builder is online and waiting for builds"
      say "All set. You can close this window — the builder keeps"
      say "running in the background while your Mac is awake."
      say "To try it, open the Builder page in the Wonderkit parent portal and run a test build."
      exit 0 ;;
    5)
      say "$LINKED_LINE" "$INSTALLED_LINE"
      fail 5 "The builder is installed but isn't online yet: $(last_line "$ERR")" "Give it a minute, then run /wonderkit:connect again. If it keeps happening, look at runner.log in ~/Library/Application Support/Wonderkit." ;;
    6)
      say "$LINKED_LINE" "$INSTALLED_LINE"
      fail 6 "Sign-in to Wonderkit was rejected — this Mac's link is no longer valid. Run /wonderkit:connect again." ;;
    *)
      say "$LINKED_LINE" "$INSTALLED_LINE"
      fail "$code" "The builder's self-test failed: $(last_line "$ERR")" "Run /wonderkit:connect again." ;;
  esac
fi

# ---- phase 1: which tarball, which hash --------------------------------------
if [[ "$ARCH" == "arm64" ]]; then EXPECTED_SHA="$RUNNER_SHA256_ARM64"; else EXPECTED_SHA="$RUNNER_SHA256_X64"; fi
# The hash override counts only for a fixture run (a loopback-http base);
# otherwise it is ignored and the pinned hash stands.
if [[ -n "$SHA_OVERRIDE" && -n "$BASE_URL_OVERRIDE" ]] && loopback_http "$BASE_URL_OVERRIDE"; then EXPECTED_SHA="$SHA_OVERRIDE"; fi
if [[ "$EXPECTED_SHA" == "$PLACEHOLDER" ]]; then
  if [[ "$ARCH" == "x64" ]]; then
    fail 2 "This version of the Wonderkit plugin has no builder for Intel Macs yet (only Apple Silicon). Update the plugin later, then run /wonderkit:connect again."
  fi
  fail 2 "This copy of the Wonderkit plugin isn't a release build: no builder checksum is pinned in it. Install the plugin from its release (/plugin marketplace add $PLUGIN_REPO), then run /wonderkit:connect again."
fi
case "$EXPECTED_SHA" in
  *[!0-9a-f]*|"") fail 2 "The builder checksum pinned in this plugin isn't a SHA-256; the plugin is damaged. Reinstall it, then run /wonderkit:connect again." ;;
esac
if [[ ${#EXPECTED_SHA} -ne 64 ]]; then
  fail 2 "The builder checksum pinned in this plugin isn't a SHA-256; the plugin is damaged. Reinstall it, then run /wonderkit:connect again."
fi

TARBALL="wonderkit-runner-${RUNNER_VERSION}-darwin-${ARCH}.tar.gz"
if [[ -n "$BASE_URL_OVERRIDE" ]]; then
  URL="${BASE_URL_OVERRIDE%/}/$TARBALL"
else
  URL="https://github.com/${PLUGIN_REPO}/releases/download/runner-v${RUNNER_VERSION}/${TARBALL}"
fi
CURL_PROTO="=https"
if [[ -n "$BASE_URL_OVERRIDE" ]] && loopback_http "$BASE_URL_OVERRIDE"; then CURL_PROTO="=http,https"; fi

VDIR="$VERSIONS/$RUNNER_VERSION"
PART="$WK_HOME/downloads/$TARBALL.part"
EXTRACT="$VERSIONS/.extract-$$"
LINK_TMP="$WK_HOME/.runner.tmp.$$"

# An intact copy of this exact version: the right VERSION, an executable
# binary, and every file matching the package's own manifest.
version_intact() {
  [[ -d "$1" && -x "$1/bin/wonderkit-runner" && -f "$1/SHA256SUMS" && -f "$1/VERSION" ]] || return 1
  [[ "$(cat "$1/VERSION")" == "$RUNNER_VERSION" ]] || return 1
  ( cd "$1" && shasum -a 256 --status -c SHA256SUMS ) 2>/dev/null
}

if version_intact "$VDIR"; then
  say "✓ Wonderkit builder $RUNNER_VERSION is already downloaded and intact"
else
  # ---- download + verify the tarball (nothing is extracted before this passes) ----
  rm -rf "$VDIR" "$EXTRACT"
  if ! mkdir -p "$VERSIONS" "$WK_HOME/downloads"; then
    fail 1 "Couldn't create $VERSIONS. Check that your home folder is writable, then run /wonderkit:connect again."
  fi
  if ! curl -fsSL --proto "$CURL_PROTO" --tlsv1.2 -o "$PART" "$URL" 2>"$ERR"; then
    rm -f "$PART"
    fail 1 "Couldn't download the Wonderkit builder ($TARBALL): $(last_line "$ERR")" "Check your connection, then run /wonderkit:connect again."
  fi
  GOT_SHA="$(shasum -a 256 "$PART" | awk '{print $1}')"
  if [[ "$GOT_SHA" != "$EXPECTED_SHA" ]]; then
    rm -f "$PART"
    fail 1 "The downloaded builder's checksum didn't match the one pinned in this plugin (got $GOT_SHA, expected $EXPECTED_SHA). Nothing was installed." "Run /wonderkit:connect again; if it happens twice, update the Wonderkit plugin."
  fi

  # ---- extract to a private dir; verify the package's SHA256SUMS -------------
  mkdir -p "$EXTRACT"
  if ! /usr/bin/tar -xzf "$PART" -C "$EXTRACT" 2>"$ERR"; then
    fail 1 "The downloaded builder couldn't be unpacked: $(last_line "$ERR")" "Run /wonderkit:connect again."
  fi
  rm -f "$PART"
  if [[ ! -f "$EXTRACT/SHA256SUMS" ]] || ! ( cd "$EXTRACT" && shasum -a 256 --status -c SHA256SUMS ) 2>/dev/null; then
    fail 1 "The builder's files didn't match its SHA256SUMS manifest. Nothing was installed." "Run /wonderkit:connect again; if it happens twice, update the Wonderkit plugin."
  fi
  # Every file must be in the manifest too (a planted extra is as bad as a changed one).
  listed="$(awk '{ $1 = ""; sub(/^ +/, ""); print }' "$EXTRACT/SHA256SUMS" | LC_ALL=C sort)"
  present="$(cd "$EXTRACT" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort)"
  if [[ "$listed" != "$present" ]]; then
    fail 1 "The builder's files didn't match its SHA256SUMS manifest (extra or missing files). Nothing was installed." "Run /wonderkit:connect again; if it happens twice, update the Wonderkit plugin."
  fi
  if [[ "$(cat "$EXTRACT/VERSION" 2>/dev/null)" != "$RUNNER_VERSION" || ! -x "$EXTRACT/bin/wonderkit-runner" ]]; then
    fail 1 "The downloaded builder isn't version $RUNNER_VERSION or has no runnable binary. Nothing was installed." "Update the Wonderkit plugin, then run /wonderkit:connect again."
  fi
  mv "$EXTRACT" "$VDIR" || fail 1 "Couldn't move the builder into place at $VDIR." "Run /wonderkit:connect again."
  say "✓ Wonderkit builder $RUNNER_VERSION downloaded and verified"
fi
touch "$VDIR"   # newest by mtime = most recently activated (the prune order)

# ---- activate: swap the `runner` symlink atomically ---------------------------
if [[ -e "$RUNNER_LINK" && ! -L "$RUNNER_LINK" ]]; then
  fail 1 "$RUNNER_LINK is a folder, not a link; move it aside, then run /wonderkit:connect again."
fi
if [[ "$(readlink "$RUNNER_LINK" 2>/dev/null)" != "versions/$RUNNER_VERSION" ]]; then
  # A directory symlink is fine (the binary keeps its own basename for the
  # runner's family lock); a renamed symlink to the BINARY would not be.
  if ! ln -s "versions/$RUNNER_VERSION" "$LINK_TMP" || ! mv -fh "$LINK_TMP" "$RUNNER_LINK"; then
    fail 1 "Couldn't point $RUNNER_LINK at the new builder." "Run /wonderkit:connect again."
  fi
fi

# ---- prune: keep the 2 newest versions, always the current one, and always ----
# the one the installed launchd agent names (an older plist may still hold a
# realpath'd versions/<v>; a phase 1 that never reached phase 2 leaves it so).
current="$(basename "$(readlink "$RUNNER_LINK")")"
launchd_ver=""
if [[ -f "$PLIST" ]]; then
  launchd_bin="$(grep -o '<string>[^<]*/bin/wonderkit-runner</string>' "$PLIST" 2>/dev/null | head -1 | sed 's|<string>||; s|</string>||')"
  case "$launchd_bin" in
    "$VERSIONS"/*/bin/wonderkit-runner) launchd_ver="${launchd_bin#"$VERSIONS"/}"; launchd_ver="${launchd_ver%%/*}" ;;
  esac
fi
n=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  d="${line#* }"
  name="$(basename "$d")"
  n=$((n + 1))
  if [[ $n -le 2 || "$name" == "$current" || "$name" == "$launchd_ver" ]]; then continue; fi
  rm -rf "$d"
done < <(for d in "$VERSIONS"/*/; do [[ -d "$d" ]] && stat -f '%m %N' "${d%/}"; done | sort -rn)

# ---- doctor (deep: one tiny Claude call proves the sign-in) -------------------
runner "$DOC" doctor --json --deep
code=$?
DOCTOR="$(cat "$DOC")"
# The Nth match (default first) of "key":"value". The top-level fields come
# before `paths` in the report, so the first `"policy":…` is the status and the
# second (when present) is the policy file's path.
json_str() { printf '%s' "$DOCTOR" | grep -o "\"$1\":\"[^\"]*\"" | sed -n "${2:-1}p" | sed 's/^"[^"]*":"//; s/"$//'; }
claude="$(json_str claude)"
if [[ $code -ne 0 || -z "$claude" ]]; then
  fail 1 "The builder's self-check didn't answer (see $LOG)." "Run /wonderkit:connect again; if it happens twice, update the Wonderkit plugin."
fi
login="$(json_str claudeLogin)"
claude_version="$(json_str claudeVersion)"
sandbox="$(json_str sandbox)"
sandbox_missing="$(json_str sandboxMissing)"
policy="$(json_str policy)"
policy_path="$(json_str policy 2)"
macos="$(sw_vers -productVersion 2>/dev/null || echo "?")"

case "$claude" in
  ok) ;;
  outdated) fail 1 "✗ Claude Code ${claude_version:-?} is older than the builder needs." "Install or update Claude Code, then run /wonderkit:connect again" ;;
  *) fail 1 "✗ Claude Code wasn't found on this Mac." "Install or update Claude Code, then run /wonderkit:connect again" ;;
esac
if [[ "$login" == "logged-out" ]]; then
  fail 1 "✗ Claude Code $claude_version isn't signed in." "Sign in to Claude Code (/login), then run /wonderkit:connect again"
fi
if [[ "$login" == "ok" ]]; then say "✓ Claude Code $claude_version · signed in"; else say "✓ Claude Code $claude_version · found"; fi

if [[ "$sandbox" != "ok" ]]; then
  # sandboxMissing names what is missing (a path) or, since the check became
  # a real probe, why sandbox-exec did not enforce.
  fail 1 "✗ macOS $macos · sandbox unavailable${sandbox_missing:+ ($sandbox_missing)}" "The builder needs macOS's app sandbox. Run /wonderkit:connect again on a Mac with a standard macOS install."
fi
say "✓ macOS $macos · sandbox enforcing"

if [[ "$policy" != "ok" ]]; then
  fail 1 "✗ An admin policy manages Claude Code on this Mac${policy_path:+ ($policy_path)}, which blocks the builder." "Use a Mac that isn't managed by an organisation, then run /wonderkit:connect again."
fi
say "✓ No admin policies blocking the builder"

# ---- the build browser (Chromium, one-time ~150 MB) — here, not in phase 2 ----
runner /dev/null install --browser-only --root "$RUNNER_LINK"
code=$?
if [[ $code -ne 0 ]]; then
  fail 1 "Couldn't set up the build browser: $(last_line "$ERR")" "Check your connection, then run /wonderkit:connect again."
fi
say "✓ Build browser ready"

# ---- link, phase 1: code + browser; the pending state waits for --finish ------
# The runner's lines are relayed through clean(): server text never reaches
# the terminal (or Claude) with escapes in it.
runner "$SELF" link --start
code=$?
while IFS= read -r l || [[ -n "$l" ]]; do printf '%s\n' "$l" | clean "$LINE_MAX"; printf '\n'; done <"$SELF"
case "$code" in
  0) exit 0 ;;
  4) fail 4 "Wonderkit isn't accepting new computers right now. Try /wonderkit:connect again later." ;;
  *) fail "$code" "Couldn't start linking this Mac: $(last_line "$ERR")" "Check your connection, then run /wonderkit:connect again." ;;
esac
