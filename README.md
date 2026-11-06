# Wonderkit Claude Code plugin

`/wonderkit:connect` installs Wonderkit's builder runner on a parent's Mac and
links it to their family, so their kids' creations build on the parent's own
Claude plan (personal Claude Code builder, spec 2026-11-04 §2).

This directory is published as its own public repo (`wonderkitdev/claude-plugin`
— the same constant as `apps/web/public/portal/builder.js` `PLUGIN_REPO`), with
the runner tarball attached to a GitHub Release. Parents install it with the
three commands the parent portal shows:

```
/plugin marketplace add wonderkitdev/claude-plugin
/plugin install wonderkit@wonderkit
/wonderkit:connect
```

## Layout

| path | what |
|---|---|
| `.claude-plugin/plugin.json` | plugin manifest (name `wonderkit`) |
| `.claude-plugin/marketplace.json` | the marketplace (name `wonderkit`) listing this plugin at `./` |
| `commands/connect.md` | `/wonderkit:connect`: runs `scripts/connect.sh` twice and relays its output verbatim; nothing else |
| `scripts/connect.sh` | the installer, two phases (below) |
| `scripts/bump-runner.sh` | pins a runner release's version + tarball hashes into `connect.sh` |
| `test/connect.test.sh` | plain-bash tests against a local fixture server and a stub runner |

## What `/wonderkit:connect` does

Claude Code's Bash tool caps a call at 10 minutes and shows output only when
the call ends, so the command runs the script twice:

**Phase 1** — `connect.sh`:
1. macOS and processor checks (macOS only for now; Apple Silicon, Intel when an x64 build is pinned).
2. Downloads `wonderkit-runner-<version>-darwin-<arch>.tar.gz` from the
   plugin repo's release `runner-v<version>` (`curl -fsSL --proto '=https' --tlsv1.2`),
   verifies it against the SHA-256 pinned **in this plugin** (the trust root is the
   plugin repo, not the download host), extracts it to `~/.wonderkit/versions/<version>/`,
   verifies the package's own `SHA256SUMS`, then points the `~/.wonderkit/runner`
   symlink at it (atomic swap). At most the two newest versions are kept, never
   the current one. Re-running with the same version reuses an intact copy.
3. `wonderkit-runner doctor --json --deep` — Claude Code found and signed in
   (one tiny Haiku call on the parent's plan), the macOS sandbox enforcing
   (a probe under `sandbox-exec`, since every build's Bash runs inside it),
   no admin policy.
4. `wonderkit-runner install --browser-only --root ~/.wonderkit/runner` — the
   build browser (Chromium, a one-time ~150 MB download), fetched here so
   phase 2 stays inside the Bash tool's 10 min cap.
5. `wonderkit-runner link --start` — prints the link code, opens the browser
   to the parent portal, saves the pending link under the runner's home.

**Phase 2** — `connect.sh --finish`:
1. `wonderkit-runner link --finish --timeout 420` — waits up to 7 minutes for
   the parent's confirmation and writes the runner token (`0600`).
2. `wonderkit-runner install --root ~/.wonderkit/runner` — the launchd agent;
   the plist names the **symlink** path, so launchd always starts the current
   version (Chromium is only fetched if still missing).
3. `wonderkit-runner selftest` — waits until the server sees the runner online,
   then prints the success lines.

The runner's own home — token, sessions, logs — is
`~/Library/Application Support/Wonderkit`; the plugin never writes there itself
(it reads the installed plist to learn which version launchd names, and never
prunes that one). The package lives under `~/.wonderkit` because the runner
refuses paths with spaces. `~/.wonderkit/connect.log` keeps the runner's
stderr from each run.

Everything the server or the runner says that is relayed to the parent (the
family name, the link lines, error text) is stripped of control and ANSI
characters and capped in length first — the output lands in Claude's context
verbatim. The link page's address is shown only when it is the Wonderkit
base URL's own https origin; otherwise the parent is pointed at the portal's
Builder page.

Every failure is one plain line plus the next step (exit codes: 2 unsupported
platform / unreleased plugin, 3 link code expired, 4 Wonderkit not accepting
new computers, 5 builder not online, 6 token rejected, 1 anything else).

## Releasing a runner

1. Build the package: `cd services/builder-runner && bun scripts/package.ts --arch arm64 --out dist/pkg`.
2. Pin it: `bash packages/claude-plugin/scripts/bump-runner.sh <version> dist/pkg/wonderkit-runner-<version>-darwin-arm64.tar.gz`
   (add the x64 tarball as a third argument when one exists).
3. Publish the plugin repo with the rewritten `connect.sh`, and attach the
   tarball(s) to a GitHub Release tagged `runner-v<version>`, under their exact names.

Until a release is pinned, `connect.sh` refuses to run (the hashes read
`REPLACE_AT_RELEASE`).

## Tests

```
bash packages/claude-plugin/test/connect.test.sh
```

Runs entirely under a temp directory: a `python3 -m http.server` fixture on a
loopback port serves stub tarballs whose `bin/wonderkit-runner` records its
arguments and exits with codes the test controls. It never touches
`~/.wonderkit`, `~/Library`, launchd, a browser, the network or `claude`.

Test-only env overrides in `connect.sh`: `WK_CONNECT_BASE_URL` (the fixture
server; the only way an `http://127.0.0.1` download is allowed — parsed as
exactly `http://127.0.0.1[:port][/path]`), `WK_CONNECT_SHA256` (the expected
tarball hash in place of the pinned one; honoured only together with such a
loopback base, ignored otherwise) and `WK_CONNECT_HOME_ROOT` (in place of `~`).

Validate the manifests with `claude plugin validate packages/claude-plugin`.
