#!/usr/bin/env bash
# Copies the current session's .jsonl transcript to the archive dir.
# Silent on success; prints to stderr on failure. Never fails the session end.

ARCHIVE_DIR="${CLAUDE_ARCHIVE_DIR:-$HOME/claude-archive}"

mkdir -p "$ARCHIVE_DIR" 2>/dev/null || { echo "archive-session: cannot create $ARCHIVE_DIR" >&2; exit 0; }

TRANSCRIPT=$(jq -r '.transcript_path // empty' 2>/dev/null)

if [ -z "$TRANSCRIPT" ]; then
    exit 0
fi

if [ ! -f "$TRANSCRIPT" ]; then
    echo "archive-session: transcript not found: $TRANSCRIPT" >&2
    exit 0
fi

cp -u "$TRANSCRIPT" "$ARCHIVE_DIR/" 2>&1 || echo "archive-session: cp failed" >&2

exit 0
