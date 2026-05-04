#!/usr/bin/env bash
# =============================================================================
#  Ubuntu 26.04 LTS Setup Script
#  Run with: bash <(curl -fsSL https://raw.githubusercontent.com/Leonardov31/linux-setup/main/setup.sh)
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${GREEN}[✔]${RESET} $*"; }
info() { echo -e "${BLUE}[➜]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
die()  { echo -e "${RED}[✘]${RESET} $*" >&2; exit 1; }

# ── Preflight ─────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] && die "Run this script as your regular user (not root). sudo will be used internally."
command -v apt-get &>/dev/null || die "This script requires apt-get (Ubuntu/Debian)."

CURRENT_USER="$(whoami)"
ARCH="$(uname -m)"

# ── Banner / consent ──────────────────────────────────────────────────────────
cat <<EOF

${BOLD}Ubuntu 26.04 LTS Setup Script${RESET}
This will install:
  • Fish shell (and set it as default)
  • Google Chrome, 1Password (+ CLI + SSH agent config), Pritunl VPN
  • asdf (Go binary, v0.16+) with Node.js LTS
  • Flutter (snap, stable channel)
  • Docker (and add ${CURRENT_USER} to the docker group)
  • Android SDK (cmdline-tools, platform-tools, android-36)
  • Zed editor, Claude Code, GitHub Copilot CLI
  • GNOME look-and-feel (if a backup exists in the repo)

It will use ${BOLD}sudo${RESET} for system package installs and shell change.
Setting up for user: ${BOLD}${CURRENT_USER}${RESET}  (arch: ${ARCH})

EOF
read -r -p "Press Enter to continue, or Ctrl-C to abort... " _

# ── Base prerequisites ────────────────────────────────────────────────────────
info "Updating package lists and installing base prerequisites (git, curl, tar, jq)..."
sudo apt-get update -y
sudo apt-get install -y git curl tar jq unzip wget ca-certificates gnupg lsb-release software-properties-common
log "Base prerequisites installed"

# Fish conf.d dir is referenced by many sections — create once up front
FISH_CONF_DIR="${HOME}/.config/fish/conf.d"
mkdir -p "$FISH_CONF_DIR"

# =============================================================================
#  1. FISH SHELL
# =============================================================================
info "Installing Fish shell..."
sudo apt-get install -y fish

FISH_PATH="$(command -v fish)"
if ! grep -qF "$FISH_PATH" /etc/shells; then
  echo "$FISH_PATH" | sudo tee -a /etc/shells > /dev/null
fi

# Defer the actual `chsh` to the end of the script, so a partial failure
# doesn't leave the user with Fish + a broken Fish config on next login.
log "Fish installed (${FISH_PATH}) — default shell will be set at the end"

# =============================================================================
#  2. GOOGLE CHROME
# =============================================================================
info "Installing Google Chrome..."
curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
  | sudo gpg --dearmor -o /usr/share/keyrings/google-chrome-keyring.gpg

echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome-keyring.gpg] \
http://dl.google.com/linux/chrome/deb/ stable main" \
  | sudo tee /etc/apt/sources.list.d/google-chrome.list > /dev/null

sudo apt-get update -y
sudo apt-get install -y google-chrome-stable
log "Google Chrome installed"

# =============================================================================
#  3. 1PASSWORD
# =============================================================================
info "Installing 1Password..."
curl -sS https://downloads.1password.com/linux/keys/1password.asc \
  | sudo gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] \
https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" \
  | sudo tee /etc/apt/sources.list.d/1password.list > /dev/null

sudo mkdir -p /etc/debsig/policies/AC2D62742012EA22
curl -sS https://downloads.1password.com/linux/debian/debsig/1password.pol \
  | sudo tee /etc/debsig/policies/AC2D62742012EA22/1password.pol > /dev/null
sudo mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22
curl -sS https://downloads.1password.com/linux/keys/1password.asc \
  | sudo gpg --dearmor --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg

sudo apt-get update -y
sudo apt-get install -y 1password 1password-cli
log "1Password + CLI installed"

# ── 1Password SSH Agent ───────────────────────────────────────────────────────
info "Configuring 1Password SSH agent..."

# 1Password's SSH agent socket location on Linux. Note: the path advertised
# in older docs (/run/user/$UID/1password/agent.sock) does not match where
# 1Password Linux actually creates the socket — it lives at ~/.1password/agent.sock.
OP_SSH_SOCKET="${HOME}/.1password/agent.sock"

# SSH config: prefer 1Password agent for github.com (and similar dev hosts)
# only — NOT `Host *`, which would break system keys, CI runners, etc.
mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"
SSH_CONFIG="${HOME}/.ssh/config"
SSH_MARK_BEGIN="# >>> 1password-ssh-agent (managed by setup.sh) >>>"
SSH_MARK_END="# <<< 1password-ssh-agent <<<"

if ! grep -qF "$SSH_MARK_BEGIN" "$SSH_CONFIG" 2>/dev/null; then
  cat >> "$SSH_CONFIG" <<EOF

${SSH_MARK_BEGIN}
# Use 1Password's SSH agent for common Git/dev hosts.
# To override on a specific host, declare it BEFORE this block in this file
# (ssh applies the FIRST matching IdentityAgent it sees).
Host github.com gitlab.com bitbucket.org *.github.com
  IdentityAgent ${OP_SSH_SOCKET}
${SSH_MARK_END}
EOF
  chmod 600 "$SSH_CONFIG"
fi

# NOTE: We intentionally do NOT export SSH_AUTH_SOCK globally in Fish.
# A global export breaks every SSH attempt before 1Password is running.
# The `IdentityAgent` directive above handles per-host routing safely.

warn "1Password SSH agent configured. Make sure to:"
warn "  1. Open 1Password → Settings → Developer → enable SSH Agent"
warn "  2. Enable 'Use the SSH agent' for each key you want available"
log "1Password SSH agent config written"

# =============================================================================
#  4. ASDF (Go binary, v0.16+) + Node.js plugin
# =============================================================================
info "Installing asdf version manager (Go binary)..."

# Map uname -m → asdf release arch
case "$ARCH" in
  x86_64)  ASDF_ARCH="amd64" ;;
  aarch64) ASDF_ARCH="arm64" ;;
  *)       die "Unsupported architecture for asdf: $ARCH" ;;
esac

# Get the latest release tag (e.g. "v0.18.0")
ASDF_TAG="$(curl -fsSL https://api.github.com/repos/asdf-vm/asdf/releases/latest \
              | jq -r '.tag_name')"
[[ -n "$ASDF_TAG" && "$ASDF_TAG" != "null" ]] || die "Could not determine latest asdf release"
ASDF_VERSION="${ASDF_TAG#v}"

# Install the asdf binary into ~/.local/bin
mkdir -p "${HOME}/.local/bin"
ASDF_TARBALL="asdf-${ASDF_TAG}-linux-${ASDF_ARCH}.tar.gz"
ASDF_URL="https://github.com/asdf-vm/asdf/releases/download/${ASDF_TAG}/${ASDF_TARBALL}"

info "Downloading ${ASDF_TARBALL}..."
curl -fsSL "$ASDF_URL" | tar -xz -C "${HOME}/.local/bin" asdf
chmod +x "${HOME}/.local/bin/asdf"

# asdf data dir (where plugins, installs, and shims live)
export ASDF_DATA_DIR="${HOME}/.asdf"
mkdir -p "${ASDF_DATA_DIR}"

# Make asdf usable for the rest of THIS bash script
export PATH="${ASDF_DATA_DIR}/shims:${HOME}/.local/bin:${PATH}"

# Verify
asdf --version
log "asdf ${ASDF_VERSION} installed at ${HOME}/.local/bin/asdf"

# Fish integration: PATH + completions
cat > "${FISH_CONF_DIR}/asdf.fish" <<'EOF'
# asdf version manager (Go binary, v0.16+)
set -gx ASDF_DATA_DIR "$HOME/.asdf"
fish_add_path "$ASDF_DATA_DIR/shims" "$HOME/.local/bin"
EOF

# Generate Fish completions
mkdir -p "${HOME}/.config/fish/completions"
asdf completion fish > "${HOME}/.config/fish/completions/asdf.fish" 2>/dev/null || \
  warn "Could not generate asdf Fish completions (non-fatal)"

# ── Node.js via asdf ──────────────────────────────────────────────────────────
info "Installing asdf Node.js plugin..."
asdf plugin add nodejs https://github.com/asdf-vm/asdf-nodejs.git 2>/dev/null || \
  warn "nodejs plugin already added, skipping"

info "Installing latest LTS Node.js via asdf..."
asdf install nodejs lts
asdf set -u nodejs lts
asdf reshim nodejs

NODE_VERSION="$(asdf current nodejs 2>/dev/null | awk 'NR==1 {print $2}')"
log "Node.js ${NODE_VERSION:-(LTS)} set as default in \$HOME"

# =============================================================================
#  5. DOCKER
# =============================================================================
info "Installing Docker..."

# Remove any old conflicting packages
sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

sudo systemctl enable --now docker
sudo usermod -aG docker "$CURRENT_USER"
log "Docker installed and enabled (log out/in for group membership to apply)"

# =============================================================================
#  6. ANDROID SDK (Command-line tools)
# =============================================================================
info "Installing Android SDK dependencies (JDK 21)..."

# Ubuntu 26.04 ships OpenJDK 21 LTS, which is fully compatible with recent
# Android Gradle Plugin versions. JDK 21 is the recommended LTS choice for
# Android development. If your project's Gradle wrapper is too old to handle
# JDK 21, bump its `distributionUrl` in gradle/wrapper/gradle-wrapper.properties
# to gradle 8.0+.
sudo apt-get install -y openjdk-21-jdk openjdk-21-jre

# Locate the JDK 21 install root (e.g. /usr/lib/jvm/java-21-openjdk-amd64)
JAVA_HOME_PATH="$(dirname "$(dirname "$(readlink -f "$(which javac)")")")"
[[ -d "$JAVA_HOME_PATH" ]] || die "Could not locate JDK 21 install root"
export JAVA_HOME="$JAVA_HOME_PATH"
export PATH="${JAVA_HOME}/bin:${PATH}"
log "JAVA_HOME pinned to ${JAVA_HOME}"

ANDROID_HOME="${HOME}/Android/Sdk"
CMDLINE_TOOLS_DIR="${ANDROID_HOME}/cmdline-tools"
mkdir -p "$CMDLINE_TOOLS_DIR"

# NOTE: Google's "_latest.zip" filename is misleading — this URL pins a
# specific build (11076708). Bump periodically by checking
# https://developer.android.com/studio#command-line-tools-only
info "Downloading Android command-line tools (pinned build 11076708)..."
CMDTOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
CMDTOOLS_ZIP="/tmp/cmdline-tools.zip"
curl -fsSL "$CMDTOOLS_URL" -o "$CMDTOOLS_ZIP"
unzip -q -o "$CMDTOOLS_ZIP" -d "$CMDLINE_TOOLS_DIR"
rm -f "$CMDTOOLS_ZIP"

# Google ships the tools as "cmdline-tools/"; sdkmanager expects "latest/" layout.
# Fail loudly if the source dir isn't where we expect.
if [[ -d "${CMDLINE_TOOLS_DIR}/cmdline-tools" ]]; then
  rm -rf "${CMDLINE_TOOLS_DIR}/latest"
  mv "${CMDLINE_TOOLS_DIR}/cmdline-tools" "${CMDLINE_TOOLS_DIR}/latest"
elif [[ ! -d "${CMDLINE_TOOLS_DIR}/latest" ]]; then
  die "Unexpected Android cmdline-tools zip layout under ${CMDLINE_TOOLS_DIR}"
fi

export ANDROID_HOME
export PATH="${CMDLINE_TOOLS_DIR}/latest/bin:${ANDROID_HOME}/platform-tools:${PATH}"

info "Accepting Android SDK licenses..."
yes | sdkmanager --licenses > /dev/null || \
  warn "sdkmanager --licenses returned non-zero (may be benign)"

info "Installing Android SDK components..."
sdkmanager --install \
  "platform-tools" \
  "platforms;android-36" \
  "build-tools;36.0.0" \
  "emulator" \
  "system-images;android-36;google_apis;x86_64"

log "Android SDK installed at ${ANDROID_HOME}"

# Fish: persist Android environment using fish_add_path (cleaner than $PATH heredoc)
cat > "${FISH_CONF_DIR}/android.fish" <<EOF
# Android SDK
set -gx ANDROID_HOME "${ANDROID_HOME}"
set -gx JAVA_HOME "${JAVA_HOME_PATH}"
fish_add_path "${CMDLINE_TOOLS_DIR}/latest/bin"
fish_add_path "${ANDROID_HOME}/platform-tools"
fish_add_path "${ANDROID_HOME}/emulator"
fish_add_path "${JAVA_HOME_PATH}/bin"
EOF

# =============================================================================
#  7. FLUTTER (via snap)
# =============================================================================
info "Installing Flutter via snap..."

# Flutter Linux desktop dependencies (Ubuntu/Debian package names)
sudo apt-get install -y \
  clang cmake ninja-build libgtk-3-dev \
  libgl1-mesa-dev libglu1-mesa-dev \
  libx11-dev libxcomposite-dev libxcursor-dev \
  libxdamage-dev libxext-dev libxfixes-dev \
  libxi-dev libxrandr-dev libxrender-dev \
  libxtst-dev libatspi2.0-dev

# snapd is pre-installed on Ubuntu but ensure it's present
sudo apt-get install -y snapd

sudo snap install flutter --classic

# Make flutter available for the rest of this script
export PATH="/snap/bin:${PATH}"

# Fish: ensure /snap/bin is on PATH (Ubuntu's system Fish config usually covers
# this, but be explicit so the conf.d setup is self-contained)
cat > "${FISH_CONF_DIR}/snap.fish" <<'EOF'
# Snap binaries
fish_add_path "/snap/bin"
EOF

# Point Flutter at the Android SDK
flutter config --android-sdk "$ANDROID_HOME" --no-analytics

# Accept Flutter's copy of Android licenses (don't mask stderr — surface real errors)
yes | flutter doctor --android-licenses > /dev/null || \
  warn "flutter doctor --android-licenses returned non-zero (may be benign)"

log "Flutter (stable) installed via snap and configured"

# Point Flutter at Google Chrome for web dev
CHROME_PATH="$(command -v google-chrome-stable 2>/dev/null || command -v google-chrome 2>/dev/null || true)"
if [[ -n "$CHROME_PATH" ]]; then
  cat > "${FISH_CONF_DIR}/flutter-chrome.fish" <<EOF
# Flutter web: use Google Chrome as CHROME_EXECUTABLE
set -gx CHROME_EXECUTABLE "${CHROME_PATH}"
EOF
  export CHROME_EXECUTABLE="$CHROME_PATH"
  log "CHROME_EXECUTABLE set to ${CHROME_PATH} for Flutter web"
fi

info "Running flutter doctor (informational; non-fatal)..."
flutter doctor || true

# =============================================================================
#  8. ZED EDITOR
# =============================================================================
info "Installing Zed editor..."
curl -fsSL https://zed.dev/install.sh | sh

cat > "${FISH_CONF_DIR}/zed.fish" <<'EOF'
# Zed editor
fish_add_path "$HOME/.local/bin"
EOF
log "Zed editor installed"

# =============================================================================
#  9. CLAUDE CODE (native installer — no Node.js required)
# =============================================================================
info "Installing Claude Code (native installer)..."
curl -fsSL https://claude.ai/install.sh | bash

# Binary lands at ~/.claude/bin/claude or ~/.local/bin/claude
cat > "${FISH_CONF_DIR}/claude-code.fish" <<'EOF'
# Claude Code
fish_add_path "$HOME/.claude/bin"
fish_add_path "$HOME/.local/bin"
EOF
log "Claude Code installed (auto-updates in the background)"

# =============================================================================
#  10. GITHUB COPILOT CLI (no Node.js required)
# =============================================================================
info "Installing GitHub Copilot CLI..."
curl -fsSL https://gh.io/copilot-install | bash

cat > "${FISH_CONF_DIR}/copilot.fish" <<'EOF'
# GitHub Copilot CLI
fish_add_path "$HOME/.local/bin"
EOF
export PATH="${HOME}/.local/bin:${PATH}"
log "GitHub Copilot CLI installed (requires a paid GitHub Copilot subscription)"

# =============================================================================
#  11. GNOME TOP BAR — Auto-hide on window overlap (Hide Top Bar extension)
# =============================================================================
info "Installing Hide Top Bar GNOME extension (intellihide)..."

# Resolve the running GNOME Shell version (major.minor, e.g. "48.0")
GNOME_VER="$(gnome-shell --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1)"
EXT_UUID="hidetopbar@mathieu.bidon.ca"
EXT_DEST="${HOME}/.local/share/gnome-shell/extensions/${EXT_UUID}"

# Query extensions.gnome.org for the version-matched download URL
EXT_DOWNLOAD_URL="$(curl -fsSL \
  "https://extensions.gnome.org/extension-info/?uuid=${EXT_UUID}&shell_version=${GNOME_VER}" \
  | jq -r '"https://extensions.gnome.org" + .download_url')"

if [[ -z "$EXT_DOWNLOAD_URL" || "$EXT_DOWNLOAD_URL" == "https://extensions.gnome.orgnull" ]]; then
  warn "Could not fetch Hide Top Bar for GNOME ${GNOME_VER} — install manually: extensions.gnome.org/extension/545"
else
  mkdir -p "$EXT_DEST"
  curl -fsSL "$EXT_DOWNLOAD_URL" | unzip -q -o - -d "$EXT_DEST"

  # Enable the extension (takes effect after the shell restarts on next login)
  gnome-extensions enable "$EXT_UUID" 2>/dev/null || \
    warn "Could not enable extension yet — it will activate after next login"

  # Intellihide: hide the bar only when a window overlaps it, reveal on mouse hover
  gsettings set org.gnome.shell.extensions.hidetopbar enable-intellihide true
  gsettings set org.gnome.shell.extensions.hidetopbar enable-active-window true
  gsettings set org.gnome.shell.extensions.hidetopbar mouse-sensitive true

  log "Hide Top Bar installed — top bar will hide when a window touches it (active after next login)"
fi

# =============================================================================
#  12. MONITOR BRIGHTNESS (ddcutil + GNOME extension)
# =============================================================================
info "Setting up monitor brightness control..."

# ddcutil — hardware DDC/CI brightness/contrast for external monitors (I2C)
sudo apt-get install -y ddcutil

# i2c-dev kernel module is required by ddcutil; load it now and persist across reboots
sudo modprobe i2c-dev
echo "i2c-dev" | sudo tee /etc/modules-load.d/i2c-dev.conf > /dev/null

# Modern udev rule: give the logged-in user (via logind uaccess) access to
# /dev/i2c-* without needing a separate i2c group
echo 'KERNEL=="i2c-[0-9]*", TAG+="uaccess"' \
  | sudo tee /etc/udev/rules.d/45-ddcutil-i2c.rules > /dev/null
sudo udevadm control --reload-rules
sudo udevadm trigger

# GNOME extension: "Brightness control using ddcutil" (ID 2645)
# Adds per-monitor brightness sliders inside the quick-settings panel
BRIGHTNESS_EXT_UUID="display-brightness-ddcutil@themightydeity.github.com"
BRIGHTNESS_EXT_DEST="${HOME}/.local/share/gnome-shell/extensions/${BRIGHTNESS_EXT_UUID}"

BRIGHTNESS_DOWNLOAD_URL="$(curl -fsSL \
  "https://extensions.gnome.org/extension-info/?uuid=${BRIGHTNESS_EXT_UUID}&shell_version=${GNOME_VER}" \
  | jq -r '"https://extensions.gnome.org" + .download_url')"

if [[ -z "$BRIGHTNESS_DOWNLOAD_URL" || "$BRIGHTNESS_DOWNLOAD_URL" == "https://extensions.gnome.orgnull" ]]; then
  warn "Could not fetch brightness extension for GNOME ${GNOME_VER} — install manually: extensions.gnome.org/extension/2645"
else
  mkdir -p "$BRIGHTNESS_EXT_DEST"
  curl -fsSL "$BRIGHTNESS_DOWNLOAD_URL" | unzip -q -o - -d "$BRIGHTNESS_EXT_DEST"
  gnome-extensions enable "$BRIGHTNESS_EXT_UUID" 2>/dev/null || \
    warn "Brightness extension will activate after next login"
  log "GNOME brightness extension installed (sliders in quick-settings panel)"
fi

log "Monitor brightness control ready — log out/in for udev rules and module to apply"

# =============================================================================
#  13. PRITUNL VPN CLIENT
# =============================================================================
info "Installing Pritunl VPN client..."

# Fetch the Pritunl signing key from Ubuntu's keyserver and store it in the
# modern signed-by location (avoids the deprecated apt-key command)
gpg --batch --keyserver hkp://keyserver.ubuntu.com \
  --recv-keys 7568D9BB55FF9E5287D586017AE645C0CF8E292A 2>/dev/null
gpg --batch --export 7568D9BB55FF9E5287D586017AE645C0CF8E292A \
  | sudo tee /usr/share/keyrings/pritunl-keyring.gpg > /dev/null

echo "deb [signed-by=/usr/share/keyrings/pritunl-keyring.gpg] \
https://repo.pritunl.com/stable/apt $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/pritunl.list > /dev/null

sudo apt-get update -y
sudo apt-get install -y pritunl-client-electron
log "Pritunl VPN client installed"

# =============================================================================
#  FINALIZE: Set Fish as default shell
# =============================================================================
# Done last so a mid-script failure doesn't leave the user logged into a
# Fish shell with a half-written ~/.config/fish/conf.d.
info "Setting Fish as default shell..."
sudo chsh -s "$FISH_PATH" "$CURRENT_USER"
log "Default shell set to ${FISH_PATH}"

# =============================================================================
#  DONE
# =============================================================================
echo
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║         Setup complete! 🎉                   ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${RESET}"
echo
echo -e "  ${BOLD}Next steps:${RESET}"
echo -e "  1. ${YELLOW}Log out and back in${RESET} — required for:"
echo -e "     • Fish to be your default shell"
echo -e "     • Docker group membership"
echo -e "     • Android/Flutter/asdf PATH vars"
echo -e "     • Hide Top Bar extension (top bar auto-hides on window overlap)"
echo -e "     • Monitor brightness control (udev i2c rules + ddcutil)"
echo -e "  2. Open ${BOLD}1Password${RESET} → Settings → Developer → enable SSH Agent"
echo -e "     (only github.com / gitlab.com / bitbucket.org are routed by default —"
echo -e "      edit ~/.ssh/config to add more hosts)"
echo -e "  3. Authenticate ${BOLD}Claude Code${RESET}:   ${BLUE}claude${RESET}  (requires Pro / Max / Console)"
echo -e "  4. Authenticate ${BOLD}Copilot CLI${RESET}:   ${BLUE}copilot${RESET} then ${BLUE}/login${RESET}  (requires Copilot subscription)"
echo -e "  5. Verify Node.js:  ${BLUE}node --version${RESET}"
echo -e "  6. Verify Docker:   ${BLUE}docker run hello-world${RESET}"
echo -e "  7. Verify Flutter:  ${BLUE}flutter doctor${RESET}"
echo -e "  8. Verify Android:  ${BLUE}sdkmanager --list_installed${RESET}"
echo -e "  9. Verify Zed:      ${BLUE}zed --version${RESET}"
echo -e " 10. ${YELLOW}Android Studio${RESET} (optional GUI IDE):"
echo -e "     ${BLUE}flatpak install flathub com.google.AndroidStudio${RESET}"
echo -e " 11. Open ${BOLD}Pritunl${RESET} and add your VPN profile URI"
echo
