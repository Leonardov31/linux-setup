#!/usr/bin/env bash
# snap-assist-pick.sh — Windows 11-style snap picker for KDE Plasma 6
#
# Tiles the current window to one side, opens a rofi window switcher so you
# can pick which window fills the opposite half, then tiles it.
#
# Usage: snap-assist-pick.sh [left|right]   (default: left)
#
# Assign to a keyboard shortcut in System Settings → Keyboard → Add shortcut:
#   Meta+Shift+Left  →  /home/<user>/.local/bin/snap-assist-pick.sh left
#   Meta+Shift+Right →  /home/<user>/.local/bin/snap-assist-pick.sh right

DIRECTION="${1:-left}"

QDBUS=$(command -v qdbus6 2>/dev/null || command -v qdbus-qt6 2>/dev/null || command -v qdbus 2>/dev/null)
[[ -z "$QDBUS" ]] && { echo "qdbus not found" >&2; exit 1; }

case "$DIRECTION" in
    left)  "$QDBUS" org.kde.KWin /KWin slotWindowQuickTileLeft ;;
    right) "$QDBUS" org.kde.KWin /KWin slotWindowQuickTileRight ;;
    *)
        echo "Usage: $0 [left|right]" >&2
        exit 1
        ;;
esac

sleep 0.2

OPPOSITE="$([ "$DIRECTION" = "left" ] && echo "right" || echo "left")"

# rofi -show window is synchronous: blocks until user picks a window (focusing it)
rofi -show window -p "Snap $OPPOSITE >"

sleep 0.1

case "$OPPOSITE" in
    right) "$QDBUS" org.kde.KWin /KWin slotWindowQuickTileRight ;;
    left)  "$QDBUS" org.kde.KWin /KWin slotWindowQuickTileLeft ;;
esac
