#!/bin/sh
# AgentMenu hook. Installed into ~/.claude/settings.json.
# Claude Code sends the hook payload as JSON on stdin and WAITS for this to
# exit, so it must be fast and must never return non-zero. A monitoring tool
# must never be able to break the agent it monitors.
#
# Pure POSIX sh, no interpreter dependency (Fix 6): /usr/bin/python3 is a
# stub that does not run on a Mac without Xcode Command Line Tools installed
# -- exactly the machine a DMG gets handed to. Field extraction of the
# payload (session_id, cwd, tool, summary) used to happen right here with
# python's json module; it now happens Swift-side in SpoolEvent, which has a
# real JSON parser. This script's only job is to capture the raw payload
# verbatim and wrap it in a small, versioned envelope.
EVENT="${1:-permission-required}"
DIR="$HOME/.agentmenu/events"
mkdir -p "$DIR" 2>/dev/null
chmod 700 "$DIR" 2>/dev/null   # holds tool inputs: commands, paths, prompts (spec S2)

PAYLOAD=$(cat)
[ -n "$PAYLOAD" ] || PAYLOAD='{}'

TS=$(date +%s)
RAND=$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
[ -n "$RAND" ] || RAND=$$
OUT="$DIR/$TS-cc-$RAND.json"
TMP="$OUT.tmp"

# Atomic write: temp file then rename, so the watcher can never observe a
# half-written file.
printf '{"v":2,"agent":"claude-code","event":"%s","ts":%s,"payload":%s}' \
    "$EVENT" "$TS" "$PAYLOAD" > "$TMP" 2>/dev/null && mv "$TMP" "$OUT" 2>/dev/null

exit 0
