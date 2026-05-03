"use strict";

// Snap Assist for KDE Plasma 6
// When a window is quick-tiled to one half, automatically tiles the only other
// visible window on that screen to the opposite half (like Windows 11).
// If there are multiple other windows, does nothing — use snap-assist-pick.sh
// with a keyboard shortcut (e.g. Meta+Shift+Left) for the manual picker flow.

var assistBusy = false;

function onGeometryChanged(window) {
    if (assistBusy) return;

    var mode = window.quickTileMode;
    if (mode !== KWin.QuickTileFlag.Left && mode !== KWin.QuickTileFlag.Right) return;

    var candidates = workspace.windowList().filter(function (w) {
        if (w === window) return false;
        if (w.minimized) return false;
        if (!w.normalWindow) return false;
        if (w.screen !== window.screen) return false;
        if (!w.onAllDesktops) {
            var onCurrent = w.desktops.some(function (d) {
                return d === workspace.currentDesktop;
            });
            if (!onCurrent) return false;
        }
        // Only consider windows not already tiled to some half
        return w.quickTileMode === KWin.QuickTileFlag.None;
    });

    if (candidates.length !== 1) return;

    assistBusy = true;
    candidates[0].quickTileMode = (mode === KWin.QuickTileFlag.Left)
        ? KWin.QuickTileFlag.Right
        : KWin.QuickTileFlag.Left;

    setTimeout(function () { assistBusy = false; }, 400);
}

function connectWindow(w) {
    w.frameGeometryChanged.connect(function () { onGeometryChanged(w); });
}

workspace.windowList().forEach(connectWindow);
workspace.windowAdded.connect(connectWindow);
