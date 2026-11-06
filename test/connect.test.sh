#!/usr/bin/env bash
# Tests for scripts/connect.sh (plan Task 16, ruling R7). Plain bash:
#
#   bash packages/claude-plugin/test/connect.test.sh
#
# Everything runs under a temp WK_CONNECT_HOME_ROOT against a local fixture
# server (python3 -m http.server on a random loopback port) serving dummy
# tarballs whose bin/wonderkit-runner is a STUB that records its arguments
# and exits with codes the test controls. Nothing here touches the real
# ~/.wonderkit or ~/Library, launchd, a browser, the network or `claude`.
set -u
set -o pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN=$(cd "$HERE/.." && pwd)
CONNECT="$PLUGIN/scripts/connect.sh"
# The version connect.sh asks for: "$CUR_VERSION" in the repo, the real one once
# bump-runner.sh has pinned a release. Fixtures are named after it so the
# suite passes on both (it ran only against the unreleased constants before).
CUR_VERSION="$(sed -n 's/^RUNNER_VERSION="\(.*\)"$/\1/p' "$CONNECT")"
[[ -n "$CUR_VERSION" ]] || { echo "connect.test.sh: no RUNNER_VERSION in $CONNECT" >&2; exit 1; }
BUMP="$PLUGIN/scripts/bump-runner.sh"
MANIFEST="$PLUGIN/.claude-plugin/plugin.json"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/wk-connect-test.XXXXXX")
SERVER_PID=""

# ---- host portability (final review Minor 8: this file runs in CI's Linux job)
# connect.sh is macOS-only BY DESIGN: it refuses a non-Darwin uname (case 3)
# and uses the BSD spellings of stat (-f '%m %N') and mv (-h). On a non-Darwin
# host the whole run is given a shim dir at the front of PATH that answers
# like a Mac: uname → Darwin/arm64, stat -f → the GNU equivalent, mv -fh →
# mv -fT. Said on the first line so a Linux pass is read as what it is (the
# script's logic under macOS semantics), never as a claim that connect.sh
# runs on Linux. The test's own tarballs use the GNU/BSD-neutral flags below.
HOST_OS="$(uname -s 2>/dev/null)"
if [[ "$HOST_OS" == Darwin ]]; then
  TAR_CMD=/usr/bin/tar; TAR_FLAGS=(--no-mac-metadata)
  sed_inplace() { sed -i '' "$@"; }
else
  TAR_CMD=tar; TAR_FLAGS=()
  sed_inplace() { sed -i "$@"; }
  PORTABLE_SHIM="$TMP/shim-portable"; mkdir -p "$PORTABLE_SHIM"
  printf '#!/bin/bash\ncase "${1:-}" in -s) echo Darwin;; -m) echo arm64;; *) echo Darwin;; esac\n' >"$PORTABLE_SHIM/uname"
  # stat -f '%m %N' <path>  →  stat -c '%Y %n' <path>; anything else passes through.
  printf '#!/bin/bash\nif [[ "${1:-}" == -f && "${2:-}" == "%%m %%N" ]]; then shift 2; exec /usr/bin/stat -c "%%Y %%n" "$@"; fi\nexec /usr/bin/stat "$@"\n' >"$PORTABLE_SHIM/stat"
  # mv -fh (BSD: never follow a symlink target)  →  mv -fT (GNU: target is a file, never a dir to enter).
  printf '#!/bin/bash\nif [[ "${1:-}" == -fh ]]; then shift; exec /bin/mv -fT "$@"; fi\nexec /bin/mv "$@"\n' >"$PORTABLE_SHIM/mv"
  chmod +x "$PORTABLE_SHIM/uname" "$PORTABLE_SHIM/stat" "$PORTABLE_SHIM/mv"
  export PATH="$PORTABLE_SHIM:$PATH"
  echo "connect.test.sh: non-Darwin host ($HOST_OS): shimming uname/stat/mv to macOS semantics for this run; no case is skipped"
fi
cleanup() {
  if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

PASS=0
FAIL=0
CURRENT=""
ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL [%s]: %s\n' "$CURRENT" "$1" >&2; }
assert_eq() {  # expected actual label
  if [[ "$1" == "$2" ]]; then ok; else bad "$3: expected '$1', got '$2'"; fi
}
assert_contains() {  # haystack needle label
  if [[ "$1" == *"$2"* ]]; then ok; else bad "$3: expected to contain '$2'; got: $1"; fi
}
assert_not_contains() {
  if [[ "$1" != *"$2"* ]]; then ok; else bad "$3: expected NOT to contain '$2'; got: $1"; fi
}
assert_exists()  { if [[ -e "$1" ]]; then ok; else bad "$2: expected $1 to exist"; fi; }
assert_missing() { if [[ ! -e "$1" ]]; then ok; else bad "$2: expected $1 to be absent"; fi; }

# ---- fixture server -------------------------------------------------------
WWW="$TMP/www"
mkdir -p "$WWW"
( cd "$WWW" && exec python3 -u -m http.server --bind 127.0.0.1 0 >"$TMP/server.log" 2>&1 ) &
SERVER_PID=$!
PORT=""
for _ in $(seq 1 100); do
  PORT=$(sed -n 's/.*port \([0-9][0-9]*\).*/\1/p' "$TMP/server.log" | head -1)
  [[ -n "$PORT" ]] && break
  sleep 0.1
done
if [[ -z "$PORT" ]]; then echo "fixture server did not start: $(cat "$TMP/server.log")" >&2; exit 1; fi
BASE_URL="http://127.0.0.1:$PORT"
requests_logged() { grep -c "GET " "$TMP/server.log" || true; }

# ---- the stub runner ------------------------------------------------------
STUB_DOCTOR_OK='{"version":"STUBVER","packaged":true,"policy":"ok","sandbox":"ok","assets":"ok","node":"ok","playwright":"missing-browser","browser":"missing","claude":"ok","claudeLogin":"ok","quarantine":"ok","token":"absent","paths":{"assets":"/x/assets","node":"/x/runtime/node","browsers":"/x/browsers","claude":"/Users/parent/.local/bin/claude","claudeVersion":"2.1.318","home":"/x/home","token":"/x/home/runner-token"}}'

write_stub() {  # dir version
  mkdir -p "$1/bin"
  cat >"$1/bin/wonderkit-runner" <<'EOF'
#!/bin/bash
# Stub wonderkit-runner (test fixture): records "<basename $0> <args>" and
# answers from WK_STUB_* env vars.
printf '%s %s\n' "$(basename "$0")" "$*" >>"${WK_STUB_LOG:?}"
case "$1" in
  doctor)
    printf '%s\n' "${WK_STUB_DOCTOR_JSON:?}"
    exit 0 ;;
  link)
    case "${2:-}" in
      --start)
        echo "Opening your browser to link this Mac to Wonderkit…"
        echo "If it didn't open, go to this address:"
        echo "https://wonderkit.dev/parent#/link?code=ABCD-1234"
        if [[ -n "${WK_STUB_LINK_START_CODE_LINE:-}" ]]; then printf '%b\n' "$WK_STUB_LINK_START_CODE_LINE"; else echo "Your code: ABCD-1234"; fi
        exit "${WK_STUB_LINK_START_EXIT:-0}" ;;
      --finish)
        [[ "${WK_STUB_LINK_FINISH_EXIT:-0}" == 0 ]] && echo "Linked. The runner token is in /x/home/runner-token (mode 0600)."
        [[ "${WK_STUB_LINK_FINISH_EXIT:-0}" == 3 ]] && echo "The link code expired before it was confirmed. Run link again for a new code." >&2
        exit "${WK_STUB_LINK_FINISH_EXIT:-0}" ;;
      *) echo "stub: unexpected link args: $*" >&2; exit 99 ;;
    esac ;;
  install)
    if [[ "${2:-}" == "--browser-only" ]]; then
      [[ "${WK_STUB_BROWSER_EXIT:-0}" == 0 ]] && echo "Chromium installed into /x/home/browsers."
      [[ "${WK_STUB_BROWSER_EXIT:-0}" != 0 ]] && echo "Chromium install failed (exit 1): download failed" >&2
      exit "${WK_STUB_BROWSER_EXIT:-0}"
    fi
    [[ "${WK_STUB_INSTALL_EXIT:-0}" == 0 ]] && echo "Installed dev.wonderkit.runner (/x/LaunchAgents/dev.wonderkit.runner.plist); it starts at login and logs to /x/home/runner.log."
    [[ "${WK_STUB_INSTALL_EXIT:-0}" != 0 ]] && printf '%s\n' "${WK_STUB_INSTALL_ERR:-launchctl bootstrap failed (exit 5): Input/output error}" >&2
    exit "${WK_STUB_INSTALL_EXIT:-0}" ;;
  selftest)
    fam="${WK_STUB_FAMILY-}"
    [[ -z "$fam" ]] && fam="Ian's family"   # (bash 3.2 can't take the apostrophe inside ${…:-…})
    [[ "${WK_STUB_SELFTEST_EXIT:-0}" == 0 ]] && printf 'Linked to %b; the runner is online.\n' "$fam"
    [[ "${WK_STUB_SELFTEST_EXIT:-0}" == 5 ]] && echo "the runner is not online after 60 s. Is it installed and running? See runner.log in the runner home." >&2
    [[ "${WK_STUB_SELFTEST_EXIT:-0}" == 6 ]] && echo "the runner token was rejected (401); run link again" >&2
    exit "${WK_STUB_SELFTEST_EXIT:-0}" ;;
  *) echo "stub: unknown subcommand $1" >&2; exit 2 ;;
esac
EOF
  chmod 755 "$1/bin/wonderkit-runner"
  printf '%s\n' "$2" >"$1/VERSION"
  mkdir -p "$1/runtime" "$1/assets"
  printf 'stub runtime\n' >"$1/runtime/README"
  printf 'stub assets\n' >"$1/assets/README"
}

# make_tarball <version> [subdir] [bad-sums]  → path of the tarball, served at
# $BASE_URL/<subdir>/wonderkit-runner-<version>-darwin-arm64.tar.gz
make_tarball() {
  local v="$1" sub="${2:-}" bad="${3:-}" d="$TMP/build-$1-${2:-root}-${3:-good}" out
  rm -rf "$d"; write_stub "$d" "$v"
  ( cd "$d" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort | xargs shasum -a 256 >SHA256SUMS )
  if [[ "$bad" == bad-sums ]]; then
    # Corrupt the recorded sum of the binary: the file is intact, the manifest lies.
    sed_inplace 's/^[0-9a-f]\{64\}  bin\/wonderkit-runner$/0000000000000000000000000000000000000000000000000000000000000000  bin\/wonderkit-runner/' "$d/SHA256SUMS"
  fi
  mkdir -p "$WWW/$sub"
  out="$WWW/${sub:+$sub/}wonderkit-runner-$v-darwin-arm64.tar.gz"
  ( cd "$d" && COPYFILE_DISABLE=1 "$TAR_CMD" "${TAR_FLAGS[@]}" -czf "$out" . )
  printf '%s' "$out"
}
sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# run_connect <home-root> <args...>  — stdout+stderr into $OUT, exit code into $CODE
OUT=""; CODE=0
run_connect() {
  local root="$1"; shift
  mkdir -p "$root"
  OUT=$(WK_CONNECT_HOME_ROOT="$root" WK_CONNECT_BASE_URL="$BASE_URL${BASE_SUB:+/$BASE_SUB}" \
        WK_STUB_LOG="$root/stub.log" WK_STUB_DOCTOR_JSON="${DOCTOR_JSON:-$STUB_DOCTOR_OK}" \
        bash "${CONNECT_SCRIPT:-$CONNECT}" "$@" 2>&1)
  CODE=$?
}
# CONNECT_TEST_VERBOSE=1 prints the transcript of a run (what the parent would see).
transcript() { [[ -n "${CONNECT_TEST_VERBOSE:-}" ]] && printf -- '--- transcript [%s] (exit %s)\n%s\n---\n' "$CURRENT" "$CODE" "$OUT"; return 0; }
stub_log() { cat "$1/stub.log" 2>/dev/null || true; }

GOOD_TGZ=$(make_tarball $CUR_VERSION)
GOOD_SHA=$(sha256_of "$GOOD_TGZ")
BAD_SUMS_TGZ=$(make_tarball $CUR_VERSION bad bad-sums)
BAD_SUMS_SHA=$(sha256_of "$BAD_SUMS_TGZ")

# ===========================================================================
CURRENT="1 wrong checksum"
H="$TMP/h1"
WK_CONNECT_SHA256="0000000000000000000000000000000000000000000000000000000000000000" run_connect "$H"
assert_eq 0 "$([[ $CODE -ne 0 ]] && echo 0 || echo 1)" "exit non-zero (got $CODE)"
assert_contains "$OUT" "checksum" "names the checksum"
assert_contains "$OUT" "/wonderkit:connect" "says what to do next"
assert_missing "$H/.wonderkit/versions/$CUR_VERSION" "nothing extracted"
assert_missing "$H/.wonderkit/runner" "runner not linked"
assert_eq "" "$(find "$H/.wonderkit" -name '*.tar.gz*' 2>/dev/null)" "no tarball left behind"
assert_eq "" "$(stub_log "$H")" "the stub never ran"

# ===========================================================================
CURRENT="2 correct checksum, phase 1"
H="$TMP/h2"
WK_CONNECT_SHA256="$GOOD_SHA" run_connect "$H"
transcript
assert_eq 0 "$CODE" "exit 0: $OUT"
assert_exists "$H/.wonderkit/versions/$CUR_VERSION/bin/wonderkit-runner" "extracted"
assert_eq "versions/$CUR_VERSION" "$(readlink "$H/.wonderkit/runner")" "runner is a symlink to the version"
assert_exists "$H/.wonderkit/runner/bin/wonderkit-runner" "binary reachable through the symlink"
RUNNER_LINK_H="$H/.wonderkit/runner"
assert_eq $'wonderkit-runner doctor --json --deep\nwonderkit-runner install --browser-only --root '"$RUNNER_LINK_H"$'\nwonderkit-runner link --start' "$(stub_log "$H")" "stub saw doctor --json --deep, install --browser-only, then link --start, under its own basename"
assert_contains "$OUT" "✓ Build browser ready" "browser line"
assert_contains "$OUT" "✓ Claude Code 2.1.318 · signed in" "claude line"
assert_contains "$OUT" "✓ macOS " "macOS line"
assert_contains "$OUT" "· sandbox enforcing" "sandbox"
assert_contains "$OUT" "✓ No admin policies blocking the builder" "policy line"
assert_contains "$OUT" "Opening your browser to link this Mac to Wonderkit…" "link --start output relayed"
assert_contains "$OUT" "Your code: ABCD-1234" "the code"
assert_not_contains "$OUT" "Linked to" "phase 1 does not claim phase 2's lines"
assert_eq "" "$(find "$H/.wonderkit" -name '*.part' -o -name '.extract-*' 2>/dev/null)" "no temp files left"
# Phase 1 again with the same version: reuses the verified install, no second download.
N_BEFORE=$(requests_logged)
WK_CONNECT_SHA256="$GOOD_SHA" run_connect "$H"
assert_eq 0 "$CODE" "re-run exit 0: $OUT"
assert_eq "$N_BEFORE" "$(requests_logged)" "no re-download for an intact version"
assert_eq "versions/$CUR_VERSION" "$(readlink "$H/.wonderkit/runner")" "runner still points at the version"

# ===========================================================================
CURRENT="3 non-Darwin uname"
H="$TMP/h3"
SHIM="$TMP/shim-linux"; mkdir -p "$SHIM"
printf '#!/bin/bash\ncase "$1" in -s) echo Linux;; -m) echo x86_64;; *) echo Linux;; esac\n' >"$SHIM/uname"; chmod +x "$SHIM/uname"
OUT=$(PATH="$SHIM:$PATH" WK_CONNECT_HOME_ROOT="$H" WK_CONNECT_BASE_URL="$BASE_URL" WK_CONNECT_SHA256="$GOOD_SHA" WK_STUB_LOG="$H/stub.log" WK_STUB_DOCTOR_JSON="$STUB_DOCTOR_OK" bash "$CONNECT" 2>&1); CODE=$?
assert_eq 2 "$CODE" "exit 2"
assert_contains "$OUT" "macOS only for now" "the macOS line"
assert_missing "$H/.wonderkit" "nothing written"

# ===========================================================================
CURRENT="3b Intel Mac with no x64 hash"
H="$TMP/h3b"
SHIM="$TMP/shim-intel"; mkdir -p "$SHIM"
printf '#!/bin/bash\ncase "$1" in -s) echo Darwin;; -m) echo x86_64;; *) /usr/bin/uname "$@";; esac\n' >"$SHIM/uname"; chmod +x "$SHIM/uname"
# A real Intel Mac: not Rosetta (hw.optional.arm64 is 0 there).
printf '#!/bin/bash\n[[ "$*" == "-n hw.optional.arm64" ]] && { echo 0; exit 0; }\nexec /usr/sbin/sysctl "$@"\n' >"$SHIM/sysctl"; chmod +x "$SHIM/sysctl"
OUT=$(PATH="$SHIM:$PATH" WK_CONNECT_HOME_ROOT="$H" WK_CONNECT_BASE_URL="$BASE_URL" WK_STUB_LOG="$H/stub.log" WK_STUB_DOCTOR_JSON="$STUB_DOCTOR_OK" bash "$CONNECT" 2>&1); CODE=$?
assert_eq 2 "$CODE" "exit 2"
assert_contains "$OUT" "Intel" "names Intel Macs"
assert_missing "$H/.wonderkit/versions" "nothing downloaded"
# ...but with a hash supplied the x64 tarball name is what it fetches.
X64_TGZ="$WWW/wonderkit-runner-$CUR_VERSION-darwin-x64.tar.gz"; cp "$GOOD_TGZ" "$X64_TGZ"
OUT=$(PATH="$SHIM:$PATH" WK_CONNECT_HOME_ROOT="$H" WK_CONNECT_BASE_URL="$BASE_URL" WK_CONNECT_SHA256="$GOOD_SHA" WK_STUB_LOG="$H/stub.log" WK_STUB_DOCTOR_JSON="$STUB_DOCTOR_OK" bash "$CONNECT" 2>&1); CODE=$?
assert_eq 0 "$CODE" "x64 path works with a hash: $OUT"
assert_contains "$(grep 'GET ' "$TMP/server.log")" "wonderkit-runner-$CUR_VERSION-darwin-x64.tar.gz" "fetched the x64 tarball"

# ===========================================================================
CURRENT="4 internal SHA256SUMS mismatch"
H="$TMP/h4"
mkdir -p "$H/.wonderkit/versions/old"; write_stub "$H/.wonderkit/versions/old" old
ln -s versions/old "$H/.wonderkit/runner"
BASE_SUB=bad WK_CONNECT_SHA256="$BAD_SUMS_SHA" run_connect "$H"
assert_eq 0 "$([[ $CODE -ne 0 ]] && echo 0 || echo 1)" "exit non-zero (got $CODE)"
assert_contains "$OUT" "SHA256SUMS" "names the internal manifest"
assert_eq "versions/old" "$(readlink "$H/.wonderkit/runner")" "runner NOT repointed"
assert_missing "$H/.wonderkit/versions/$CUR_VERSION" "the bad version is not kept"
assert_eq "old" "$(ls "$H/.wonderkit/versions")" "no extract dir left behind"
assert_eq "" "$(stub_log "$H")" "the stub never ran"

# ===========================================================================
CURRENT="5 --finish happy path"
H="$TMP/h5"
WK_CONNECT_SHA256="$GOOD_SHA" run_connect "$H"
assert_eq 0 "$CODE" "phase 1 exit 0"
run_connect "$H" --finish
transcript
assert_eq 0 "$CODE" "phase 2 exit 0: $OUT"
RUNNER_LINK_H="$H/.wonderkit/runner"
assert_eq $'wonderkit-runner doctor --json --deep\nwonderkit-runner install --browser-only --root '"$RUNNER_LINK_H"$'\nwonderkit-runner link --start\nwonderkit-runner link --finish --timeout 420\nwonderkit-runner install --root '"$RUNNER_LINK_H"$'\nwonderkit-runner selftest' "$(stub_log "$H")" "stub saw link --finish --timeout 420, install --root <symlink>, selftest in order"
assert_contains "$OUT" "✓ Linked to Ian's family" "family line from selftest (a real name already ends in 'family')"
assert_not_contains "$OUT" "family family" "no doubled word"
assert_contains "$OUT" "✓ Installed the Wonderkit builder (starts when you log in)" "installed line"
assert_contains "$OUT" "✓ Builder is online and waiting for builds" "online line"
assert_contains "$OUT" "All set. You can close this window — the builder keeps" "all set"
assert_contains "$OUT" "running in the background while your Mac is awake." "all set 2"
assert_contains "$OUT" "To try it, open the Builder page in the Wonderkit parent portal and run a test build." "try it"
assert_not_contains "$OUT" "runner-token" "the token path is not relayed"
# The three check lines come in the mock's order.
L1=$(printf '%s\n' "$OUT" | grep -n "✓ Linked to " | cut -d: -f1)
L2=$(printf '%s\n' "$OUT" | grep -n "Installed the Wonderkit builder" | cut -d: -f1)
L3=$(printf '%s\n' "$OUT" | grep -n "Builder is online" | cut -d: -f1)
assert_eq "yes" "$([[ -n $L1 && -n $L2 && -n $L3 && $L1 -lt $L2 && $L2 -lt $L3 ]] && echo yes || echo no)" "order Linked < Installed < Online ($L1,$L2,$L3)"
# A name without the word gets the mock's template; no name → the generic line.
for spec in "The Lins|✓ Linked to the The Lins family" "(no family)|✓ Linked to your Wonderkit family"; do
  rm -f "$H/stub.log"
  OUT=$(WK_CONNECT_HOME_ROOT="$H" WK_CONNECT_BASE_URL="$BASE_URL" WK_STUB_LOG="$H/stub.log" WK_STUB_DOCTOR_JSON="$STUB_DOCTOR_OK" WK_STUB_FAMILY="${spec%%|*}" bash "$CONNECT" --finish 2>&1); CODE=$?
  assert_eq 0 "$CODE" "exit 0 (${spec%%|*})"
  assert_contains "$OUT" "${spec#*|}" "family line for '${spec%%|*}'"
done

# ===========================================================================
CURRENT="6 link --finish exit 3 (expired)"
H="$TMP/h6"
WK_CONNECT_SHA256="$GOOD_SHA" run_connect "$H"
OUT=$(WK_CONNECT_HOME_ROOT="$H" WK_CONNECT_BASE_URL="$BASE_URL" WK_STUB_LOG="$H/stub.log" WK_STUB_DOCTOR_JSON="$STUB_DOCTOR_OK" WK_STUB_LINK_FINISH_EXIT=3 bash "$CONNECT" --finish 2>&1); CODE=$?
assert_eq 3 "$CODE" "exit 3"
assert_contains "$OUT" "The code expired — run /wonderkit:connect again" "expired line"
assert_not_contains "$(stub_log "$H")" "install --root" "the launchd install never ran"
assert_not_contains "$(stub_log "$H")" "selftest" "selftest never ran"
assert_not_contains "$OUT" "✓ Linked" "no success line"

CURRENT="6b other phase-2 failures"
for spec in "LINK_FINISH:4:Wonderkit isn't accepting new computers right now" "INSTALL:1:Couldn't install the Wonderkit builder" "SELFTEST:5:isn't online yet" "SELFTEST:6:Sign-in to Wonderkit was rejected"; do
  var=${spec%%:*}; rest=${spec#*:}; want_code=${rest%%:*}; want_text=${rest#*:}
  rm -f "$H/stub.log"
  OUT=$(env "WK_STUB_${var}_EXIT=$want_code" WK_CONNECT_HOME_ROOT="$H" WK_CONNECT_BASE_URL="$BASE_URL" WK_STUB_LOG="$H/stub.log" WK_STUB_DOCTOR_JSON="$STUB_DOCTOR_OK" bash "$CONNECT" --finish 2>&1); CODE=$?
  assert_eq "$want_code" "$CODE" "$var exit $want_code"
  assert_contains "$OUT" "$want_text" "$var line"
  assert_contains "$OUT" "/wonderkit:connect" "$var next step"
  assert_not_contains "$OUT" "All set" "$var: no all-set"
  assert_not_contains "$OUT" "Builder is online" "$var: no online line"
  if [[ $var == INSTALL ]]; then assert_not_contains "$(stub_log "$H")" "selftest" "selftest never ran after a failed install"; fi
done
# --finish without phase 1 first: a plain line, exit non-zero, nothing run.
H="$TMP/h6c"
run_connect "$H" --finish
assert_eq 0 "$([[ $CODE -ne 0 ]] && echo 0 || echo 1)" "exit non-zero (got $CODE)"
assert_contains "$OUT" "/wonderkit:connect" "says to run connect first"

CURRENT="6c browser install fails in phase 1"
H="$TMP/h6d"
OUT=$(WK_CONNECT_HOME_ROOT="$H" WK_CONNECT_BASE_URL="$BASE_URL" WK_CONNECT_SHA256="$GOOD_SHA" WK_STUB_LOG="$H/stub.log" WK_STUB_DOCTOR_JSON="$STUB_DOCTOR_OK" WK_STUB_BROWSER_EXIT=1 bash "$CONNECT" 2>&1); CODE=$?
assert_eq 1 "$CODE" "exit 1"
assert_contains "$OUT" "Couldn't set up the build browser" "browser failure line"
assert_contains "$OUT" "/wonderkit:connect" "next step"
assert_not_contains "$(stub_log "$H")" "link --start" "link never ran"

CURRENT="6d server strings are sanitized (fix 3a)"
H="$TMP/h6e"
WK_CONNECT_SHA256="$GOOD_SHA" run_connect "$H"
ESC=$'\033'
# familyName with ANSI + control chars + 100 chars: printed clean and ≤ 60.
LONGFAM="Ian${ESC}[31m's\a\r fam\tily $(printf 'x%.0s' $(seq 1 100))"
OUT=$(WK_CONNECT_HOME_ROOT="$H" WK_CONNECT_BASE_URL="$BASE_URL" WK_STUB_LOG="$H/stub.log" WK_STUB_DOCTOR_JSON="$STUB_DOCTOR_OK" WK_STUB_FAMILY="$LONGFAM" bash "$CONNECT" --finish 2>&1); CODE=$?
assert_eq 0 "$CODE" "exit 0"
FAMLINE=$(printf '%s\n' "$OUT" | grep '^✓ Linked to ')
control_bytes() { printf '%s' "$1" | LC_ALL=C tr -cd '\000-\011\013-\037\177' | wc -c | tr -d ' '; }   # newlines allowed
assert_eq 0 "$(control_bytes "$OUT")" "no control bytes in the output"
assert_not_contains "$OUT" "[31m" "ANSI sequence stripped"
assert_contains "$FAMLINE" "Ian's family" "family text kept"
P1='✓ Linked to the '; P2=' family'
assert_eq "yes" "$([[ ${#FAMLINE} -le $(( ${#P1} + 60 + ${#P2} )) ]] && echo yes || echo no)" "family name capped at 60 (line was ${#FAMLINE} chars)"
# A server/runner error line with escapes and 300 chars: clean and ≤ 200.
LONGERR="boom${ESC}[2J\a $(printf 'e%.0s' $(seq 1 300))"
OUT=$(WK_CONNECT_HOME_ROOT="$H" WK_CONNECT_BASE_URL="$BASE_URL" WK_STUB_LOG="$H/stub.log" WK_STUB_DOCTOR_JSON="$STUB_DOCTOR_OK" WK_STUB_INSTALL_EXIT=1 WK_STUB_INSTALL_ERR="$LONGERR" bash "$CONNECT" --finish 2>&1); CODE=$?
assert_eq 1 "$CODE" "install failure exit 1"
ERRLINE=$(printf '%s\n' "$OUT" | grep "Couldn't install")
assert_not_contains "$OUT" "[2J" "ANSI stripped from the error"
assert_eq 0 "$(control_bytes "$OUT")" "no control bytes in the error output"
P3="Couldn't install the Wonderkit builder: "
assert_eq "yes" "$([[ ${#ERRLINE} -le $(( ${#P3} + 200 )) ]] && echo yes || echo no)" "error text capped at 200 (line was ${#ERRLINE} chars)"
# The relayed `link --start` lines are cleaned too (the runner cleans them first; the script does again).
rm -f "$H/stub.log"
OUT=$(WK_CONNECT_HOME_ROOT="$H" WK_CONNECT_BASE_URL="$BASE_URL" WK_CONNECT_SHA256="$GOOD_SHA" WK_STUB_LOG="$H/stub.log" WK_STUB_DOCTOR_JSON="$STUB_DOCTOR_OK" WK_STUB_LINK_START_CODE_LINE="Your code: AB\033[31mCD-12\a34" bash "$CONNECT" 2>&1); CODE=$?
assert_eq 0 "$CODE" "exit 0"
assert_contains "$OUT" "Your code: ABCD-1234" "code line cleaned"
assert_not_contains "$OUT" "[31m" "ANSI stripped from the relayed line"

# ===========================================================================
CURRENT="7 placeholder hash without the override"
H="$TMP/h7"
# Tests 7 and 7c are about an UNRELEASED plugin, so they run a copy of
# connect.sh with the hashes reset to the placeholder — whether or not the
# real one has been pinned by bump-runner.sh. (Against a pinned copy, the
# no-override cases would download from GitHub; this suite never touches the
# network.)
UNRELEASED="$TMP/unreleased/connect.sh"
mkdir -p "$(dirname "$UNRELEASED")"
sed -e 's|^RUNNER_SHA256_ARM64=.*|RUNNER_SHA256_ARM64="REPLACE_AT_RELEASE"|' \
    -e 's|^RUNNER_SHA256_X64=.*|RUNNER_SHA256_X64="REPLACE_AT_RELEASE"|' "$CONNECT" > "$UNRELEASED"
assert_eq 2 "$(grep -c '^RUNNER_SHA256_[A-Z0-9]*="REPLACE_AT_RELEASE"$' "$UNRELEASED")" "unreleased copy has both placeholders"
N_BEFORE=$(requests_logged)
OUT=$(WK_CONNECT_HOME_ROOT="$H" WK_CONNECT_BASE_URL="$BASE_URL" bash "$UNRELEASED" 2>&1); CODE=$?
assert_eq 2 "$CODE" "exit 2"
assert_contains "$OUT" "release" "explains it is an unreleased plugin"
assert_eq "$N_BEFORE" "$(requests_logged)" "nothing downloaded"
assert_missing "$H/.wonderkit/versions" "nothing written"
# An override that is not a sha256 is refused too.
OUT=$(WK_CONNECT_HOME_ROOT="$H" WK_CONNECT_BASE_URL="$BASE_URL" WK_CONNECT_SHA256="abc" bash "$UNRELEASED" 2>&1); CODE=$?
assert_eq 2 "$CODE" "malformed override: exit 2"

CURRENT="7c the SHA override counts only with a loopback-http base (fix 3c/3d)"
# No base URL → the override is ignored → the placeholder pin refuses (nothing fetched).
for base in "" "https://example.invalid" "http://example.invalid" "http://127.0.0.1:@other.host/" "http://127.0.0.1.evil.host:80" "ftp://127.0.0.1:80"; do
  N_BEFORE=$(requests_logged)
  OUT=$(WK_CONNECT_HOME_ROOT="$H" WK_CONNECT_BASE_URL="$base" WK_CONNECT_SHA256="$GOOD_SHA" bash "$UNRELEASED" 2>&1); CODE=$?
  assert_eq 2 "$CODE" "base '$base': override ignored → placeholder refusal (got $CODE: $OUT)"
  assert_contains "$OUT" "release" "base '$base': the placeholder line"
  assert_eq "$N_BEFORE" "$(requests_logged)" "base '$base': nothing fetched"
  assert_missing "$H/.wonderkit/versions" "base '$base': nothing written"
done
# A loopback base with a port and a path still honours it (the fixture itself).
BASE_SUB="" WK_CONNECT_SHA256="$GOOD_SHA" run_connect "$TMP/h7c"
assert_eq 0 "$CODE" "loopback base honours the override: $OUT"

# ===========================================================================
CURRENT="7b doctor failure lines"
H="$TMP/h7b"
doctor_variant() {  # name json expected-text expected-code
  rm -f "$H/stub.log"
  DOCTOR_JSON="$2" WK_CONNECT_SHA256="$GOOD_SHA" run_connect "$H"
  assert_eq "$4" "$CODE" "$1: exit $4 (got $CODE): $OUT"
  assert_contains "$OUT" "$3" "$1: line"
  assert_not_contains "$(stub_log "$H")" "link --start" "$1: link never ran"
}
doctor_variant "claude missing" "${STUB_DOCTOR_OK/\"claude\":\"ok\"/\"claude\":\"missing\"}" "Install or update Claude Code, then run /wonderkit:connect again" 1
doctor_variant "claude outdated" "${STUB_DOCTOR_OK/\"claude\":\"ok\"/\"claude\":\"outdated\"}" "Install or update Claude Code, then run /wonderkit:connect again" 1
doctor_variant "logged out" "${STUB_DOCTOR_OK/\"claudeLogin\":\"ok\"/\"claudeLogin\":\"logged-out\"}" "Sign in to Claude Code (/login), then run /wonderkit:connect again" 1
doctor_variant "policy managed" "${STUB_DOCTOR_OK/\"policy\":\"ok\"/\"policy\":\"managed\"}" "admin polic" 1
doctor_variant "sandbox unavailable" "${STUB_DOCTOR_OK/\"sandbox\":\"ok\"/\"sandbox\":\"unavailable\"}" "sandbox" 1
# claudeLogin "error" (could not prove the login): proceeds, says "found" not "signed in".
rm -f "$H/stub.log"
DOCTOR_JSON="${STUB_DOCTOR_OK/\"claudeLogin\":\"ok\"/\"claudeLogin\":\"error\"}" WK_CONNECT_SHA256="$GOOD_SHA" run_connect "$H"
assert_eq 0 "$CODE" "login error: proceeds"
assert_contains "$OUT" "✓ Claude Code 2.1.318 · found" "login error: 'found'"
assert_not_contains "$OUT" "signed in" "login error: not 'signed in'"
assert_contains "$(stub_log "$H")" "link --start" "login error: link ran"
# Garbage from doctor: a plain line, not a stack trace.
rm -f "$H/stub.log"
DOCTOR_JSON="not json at all" WK_CONNECT_SHA256="$GOOD_SHA" run_connect "$H"
assert_eq 1 "$CODE" "doctor garbage: exit 1"
assert_contains "$OUT" "/wonderkit:connect" "doctor garbage: next step"

# ===========================================================================
CURRENT="8 update: swap, keep one, prune"
# Bumped copies of connect.sh via bump-runner.sh (the release tool) — real hashes, no override.
H="$TMP/h8"
bumped() {  # version → path of a connect.sh pinned to that version
  local v="$1" d="$TMP/bump-$1"
  # The plugin's real layout: scripts/ beside .claude-plugin/ (bump-runner.sh
  # also rewrites the manifest's version).
  mkdir -p "$d/scripts" "$d/.claude-plugin"; cp "$CONNECT" "$BUMP" "$d/scripts/"; cp "$MANIFEST" "$d/.claude-plugin/"
  local tgz; tgz=$(make_tarball "$v")
  bash "$d/scripts/bump-runner.sh" "$v" "$tgz" >"$d/bump.log" 2>&1 || { echo "bump-runner.sh failed: $(cat "$d/bump.log")" >&2; }
  printf '%s' "$d/scripts/connect.sh"
}
C1=$(bumped 0.0.1)
assert_contains "$(cat "$C1")" "RUNNER_VERSION=\"0.0.1\"" "bump rewrote the version"
assert_contains "$(cat "$C1")" "RUNNER_SHA256_ARM64=\"$(sha256_of "$WWW/wonderkit-runner-0.0.1-darwin-arm64.tar.gz")\"" "bump rewrote the arm64 hash"
assert_contains "$(cat "$C1")" "RUNNER_SHA256_X64=\"REPLACE_AT_RELEASE\"" "no x64 tarball → x64 stays the placeholder"
assert_eq "" "$(diff <(grep -v '^RUNNER_VERSION=\|^RUNNER_SHA256_' "$CONNECT") <(grep -v '^RUNNER_VERSION=\|^RUNNER_SHA256_' "$C1"))" "bump changed only the constant block"
# Claude Code caches an installed plugin by its manifest version: a runner bump
# that leaves plugin.json's version alone is never picked up by /plugin update
# (runner 0.1.1, 2026-11-06 — the old cached connect.sh kept installing 0.1.0).
M1="$(dirname "$(dirname "$C1")")/.claude-plugin/plugin.json"
assert_contains "$(cat "$M1")" '"version": "0.0.1"' "bump rewrote the plugin manifest's version"
assert_eq "" "$(diff <(grep -v '"version"' "$MANIFEST") <(grep -v '"version"' "$M1"))" "bump changed only the manifest's version line"
CONNECT_SCRIPT="$C1" run_connect "$H"
assert_eq 0 "$CODE" "0.0.1 phase 1: $OUT"
assert_eq "versions/0.0.1" "$(readlink "$H/.wonderkit/runner")" "runner → 0.0.1"
sleep 1.1   # distinct mtimes (1 s resolution is enough for the prune order)
C2=$(bumped 0.0.2)
CONNECT_SCRIPT="$C2" run_connect "$H"
assert_eq 0 "$CODE" "0.0.2 phase 1: $OUT"
assert_eq "versions/0.0.2" "$(readlink "$H/.wonderkit/runner")" "runner → 0.0.2"
assert_exists "$H/.wonderkit/versions/0.0.1" "0.0.1 kept"
sleep 1.1
C3=$(bumped 0.0.3)
CONNECT_SCRIPT="$C3" run_connect "$H"
assert_eq 0 "$CODE" "0.0.3 phase 1: $OUT"
assert_eq "versions/0.0.3" "$(readlink "$H/.wonderkit/runner")" "runner → 0.0.3"
assert_exists "$H/.wonderkit/versions/0.0.2" "0.0.2 kept"
assert_missing "$H/.wonderkit/versions/0.0.1" "0.0.1 pruned"
assert_eq $'0.0.2\n0.0.3' "$(ls "$H/.wonderkit/versions")" "exactly the two newest remain"
# Never the current one: two "newer" dirs (future mtimes) exist, so the just-installed
# version is not among the 2 newest by mtime — it must still survive the prune.
H="$TMP/h8b"
mkdir -p "$H/.wonderkit/versions/future-a" "$H/.wonderkit/versions/future-b" "$H/.wonderkit/versions/stale"
touch -t 203001010000 "$H/.wonderkit/versions/future-a"; touch -t 202901010000 "$H/.wonderkit/versions/future-b"; touch -t 202001010000 "$H/.wonderkit/versions/stale"
ln -s versions/stale "$H/.wonderkit/runner"
CONNECT_SCRIPT="$C3" run_connect "$H"
assert_eq 0 "$CODE" "install over seeded versions: $OUT"
assert_eq "versions/0.0.3" "$(readlink "$H/.wonderkit/runner")" "runner → 0.0.3"
assert_exists "$H/.wonderkit/versions/0.0.3" "the current version is never pruned"
assert_exists "$H/.wonderkit/versions/future-a" "newest kept"
assert_exists "$H/.wonderkit/versions/future-b" "second newest kept"
assert_missing "$H/.wonderkit/versions/stale" "the old one is pruned"
# Never the version launchd runs (fix 1): a plist naming versions/<v> keeps <v>
# through two phase-1 updates that never reach phase 2.
H="$TMP/h8c"
mkdir -p "$H/.wonderkit/versions/launchd-v" "$H/Library/LaunchAgents"
touch -t 202001010000 "$H/.wonderkit/versions/launchd-v"
cat >"$H/Library/LaunchAgents/dev.wonderkit.runner.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>Label</key><string>dev.wonderkit.runner</string>
<key>ProgramArguments</key><array><string>$H/.wonderkit/versions/launchd-v/bin/wonderkit-runner</string><string>run</string></array>
</dict></plist>
EOF
CONNECT_SCRIPT="$C1" run_connect "$H"
assert_eq 0 "$CODE" "0.0.1 over a launchd version: $OUT"
sleep 1.1
CONNECT_SCRIPT="$C2" run_connect "$H"
assert_eq 0 "$CODE" "0.0.2 over a launchd version: $OUT"
sleep 1.1
CONNECT_SCRIPT="$C3" run_connect "$H"
assert_eq 0 "$CODE" "0.0.3 over a launchd version: $OUT"
assert_exists "$H/.wonderkit/versions/launchd-v" "the version launchd runs survives three updates"
assert_eq "versions/0.0.3" "$(readlink "$H/.wonderkit/runner")" "runner → 0.0.3"
assert_missing "$H/.wonderkit/versions/0.0.1" "0.0.1 pruned"
assert_eq $'0.0.2\n0.0.3\nlaunchd-v' "$(ls "$H/.wonderkit/versions")" "newest two + launchd's"
assert_eq "yes" "$(grep -q 'launchd-v' "$H/Library/LaunchAgents/dev.wonderkit.runner.plist" && echo yes)" "the plist was only read, not rewritten"
# A plist naming the symlink path (what install --root writes) needs no extra exemption.
sed_inplace "s|$H/.wonderkit/versions/launchd-v/bin|$H/.wonderkit/runner/bin|" "$H/Library/LaunchAgents/dev.wonderkit.runner.plist"
sleep 1.1
C4=$(bumped 0.0.4)
CONNECT_SCRIPT="$C4" run_connect "$H"
assert_eq 0 "$CODE" "0.0.4: $OUT"
assert_eq $'0.0.3\n0.0.4' "$(ls "$H/.wonderkit/versions")" "with a symlink-path plist only the newest two remain"
# bump-runner.sh refuses a tarball whose name does not carry the version.
D="$TMP/bump-bad"; mkdir -p "$D/scripts" "$D/.claude-plugin"; cp "$CONNECT" "$BUMP" "$D/scripts/"; cp "$MANIFEST" "$D/.claude-plugin/"
OUT=$(bash "$D/scripts/bump-runner.sh" 9.9.9 "$GOOD_TGZ" 2>&1); CODE=$?
assert_eq 0 "$([[ $CODE -ne 0 ]] && echo 0 || echo 1)" "bump refuses a mismatched tarball name (got $CODE)"
assert_eq "" "$(diff "$CONNECT" "$D/scripts/connect.sh")" "and leaves the script untouched"
assert_eq "" "$(diff "$MANIFEST" "$D/.claude-plugin/plugin.json")" "and leaves the manifest untouched"
# No manifest beside scripts/ → refuse before touching connect.sh (a release
# that pins the runner but not the plugin version is the bug above).
D="$TMP/bump-nomanifest"; mkdir -p "$D/scripts"; cp "$CONNECT" "$BUMP" "$D/scripts/"
OUT=$(bash "$D/scripts/bump-runner.sh" 0.0.9 "$(make_tarball 0.0.9)" 2>&1); CODE=$?
assert_eq 2 "$CODE" "bump with no plugin manifest exits 2: $OUT"
assert_eq "" "$(diff "$CONNECT" "$D/scripts/connect.sh")" "and leaves the script untouched"
# The shipped plugin: its manifest version IS the pinned runner version, so
# every runner release changes what /plugin update sees.
assert_contains "$(cat "$MANIFEST")" "\"version\": \"$CUR_VERSION\"" "plugin.json version matches connect.sh's RUNNER_VERSION ($CUR_VERSION)"

# ===========================================================================
CURRENT="9 containment"
# The plugin never writes into the runner's home (token, sessions, logs) itself.
for h in "$TMP"/h2 "$TMP"/h5; do
  assert_missing "$h/Library" "no ~/Library under $h"
done
LEFT=""
for f in "${TMPDIR:-/tmp}"/wk-connect-err.* "${TMPDIR:-/tmp}"/wk-connect-doc.* "${TMPDIR:-/tmp}"/wk-connect-self.*; do [[ -e "$f" ]] && LEFT="$LEFT $f"; done
assert_eq "" "$LEFT" "no wk-connect temp files left in TMPDIR"
# The script never calls launchctl / open / claude itself: only through the stub.
assert_eq "" "$(grep -v '^[[:space:]]*#' "$CONNECT" | grep -n 'launchctl\|^[[:space:]]*open \|claude -p\|claude plugin' || true)" "no direct launchctl/open/claude call in connect.sh"

# ===========================================================================
echo
echo "connect.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
