#!/usr/bin/env bash
# =============================================================================
#  KDE Plasma look-and-feel backup
#
#  Run from the root of your linux-setup repo:
#    bash kde-backup.sh
#
#  This dumps the config files needed to reproduce your Plasma look & feel
#  (theme, colors, fonts, panel layout, shortcuts, terminal profile) into a
#  `kde-config/` directory next to setup.sh. Commit and push that directory
#  to GitHub. setup.sh will fetch and restore it on the new machine.
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RESET='\033[0m'
log()  { echo -e "${GREEN}[✔]${RESET} $*"; }
info() { echo -e "${BLUE}[➜]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${REPO_DIR}/kde-config"

# Files relative to $HOME — look-and-feel only
FILES=(
  ".config/kdeglobals"
  ".config/kwinrc"
  ".config/kwinrulesrc"
  ".config/plasmarc"
  ".config/plasmashellrc"
  ".config/plasma-org.kde.plasma.desktop-appletsrc"
  ".config/kglobalshortcutsrc"
  ".config/khotkeysrc"
  ".config/kcminputrc"
  ".config/kxkbrc"
  ".config/kactivitymanagerdrc"
  ".config/dolphinrc"
  ".config/konsolerc"
  ".config/krunnerrc"
  ".config/kscreenlockerrc"
  ".config/ksmserverrc"
  ".config/kwalletrc"
)

# Whole directories to copy (Konsole profiles live here)
DIRS=(
  ".local/share/konsole"
)

info "Backing up KDE look-and-feel config to ${DEST}/"

# Wipe any previous backup so removed files don't linger
rm -rf "$DEST"
mkdir -p "$DEST"

copied=0; missing=0

for rel in "${FILES[@]}"; do
  src="${HOME}/${rel}"
  if [[ -f "$src" ]]; then
    dst="${DEST}/${rel}"
    mkdir -p "$(dirname "$dst")"
    cp -p "$src" "$dst"
    ((copied++))
  else
    warn "Skipped (not found): ~/${rel}"
    ((missing++))
  fi
done

for rel in "${DIRS[@]}"; do
  src="${HOME}/${rel}"
  if [[ -d "$src" ]]; then
    dst="${DEST}/${rel}"
    mkdir -p "$(dirname "$dst")"
    cp -rp "$src" "$dst"
    ((copied++))
  else
    warn "Skipped (not found): ~/${rel}/"
    ((missing++))
  fi
done

# Capture currently-active Plasma look-and-feel package name (best-effort)
if command -v lookandfeeltool >/dev/null 2>&1; then
  current_lnf="$(lookandfeeltool --list 2>/dev/null | grep -E '^\*' | awk '{print $2}' || true)"
  if [[ -n "${current_lnf:-}" ]]; then
    echo "$current_lnf" > "${DEST}/active-look-and-feel.txt"
    info "Recorded active look-and-feel: ${current_lnf}"
  fi
fi

log "Backup complete: ${copied} item(s) copied, ${missing} missing/skipped"
echo
echo "Next steps:"
echo "  cd ${REPO_DIR}"
echo "  git add kde-config/"
echo "  git commit -m 'Add KDE look-and-feel backup'"
echo "  git push origin main"
