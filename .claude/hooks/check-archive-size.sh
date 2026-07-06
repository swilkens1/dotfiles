#!/usr/bin/env bash
# Warns to stderr when the archive dir exceeds a size threshold.
# Silent when under threshold. Never fails the session start.

ARCHIVE_DIR="${CLAUDE_ARCHIVE_DIR:-$HOME/claude-archive}"
THRESHOLD_MB=500

[ -d "$ARCHIVE_DIR" ] || exit 0

SIZE_MB=$(du -sm "$ARCHIVE_DIR" 2>/dev/null | awk '{print $1}')

if [ -z "$SIZE_MB" ] || [ "$SIZE_MB" -le "$THRESHOLD_MB" ]; then
    exit 0
fi

{
    echo ""
    echo "=========================================================="
    echo "  Claude archive dir is ${SIZE_MB} MB (threshold ${THRESHOLD_MB} MB)"
    echo "  Location: $ARCHIVE_DIR"
    echo "  5 largest files:"
    find "$ARCHIVE_DIR" -type f -printf '%s\t%TY-%Tm-%Td\t%p\n' 2>/dev/null \
        | sort -rn | head -5 \
        | awk '{ mb = $1 / 1048576; printf "    %6.1f MB  %s  %s\n", mb, $2, $3 }'
    echo "  Delete files you no longer need to free space."
    echo "=========================================================="
    echo ""
} >&2

exit 0
