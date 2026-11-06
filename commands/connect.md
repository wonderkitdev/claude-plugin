---
description: Connect this Mac to your Wonderkit family so your kids' creations build on your own Claude plan
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/connect.sh:*)
disable-model-invocation: true
---

Connect this Mac to Wonderkit. Do exactly these three steps, in this one turn, and nothing else — no other commands, and no reading or editing of files.

1. Run with the Bash tool, timeout 600000:

   `bash ${CLAUDE_PLUGIN_ROOT}/scripts/connect.sh`

   Show the parent its output exactly as printed, word for word. If it exited non-zero, stop here — the output already says what to do next.

2. Tell the parent: a browser window has opened (or use the address shown above) — sign in to Wonderkit as a parent and confirm the code. Do not wait for a reply; go straight to step 3, which waits for the confirmation.

3. Run with the Bash tool, timeout 600000:

   `bash ${CLAUDE_PLUGIN_ROOT}/scripts/connect.sh --finish`

   Show the parent its output exactly as printed, word for word.
