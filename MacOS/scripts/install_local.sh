#!/usr/bin/env bash
# Build Audio Finder from source, install it for the current user, and open it.
# No Apple Developer account is required for this local-only build.

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Xcode is required. Install it, select it with xcode-select, and try again." >&2
  exit 1
fi

PROJECT_ROOT="$(pwd)"
BUILD_ROOT="$PROJECT_ROOT/build/LocalInstall"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
INSTALL_DIRECTORY="${AUDIO_FINDER_INSTALL_DIR:-$HOME/Applications}"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/AudioFinder.app"
INSTALLED_APP="$INSTALL_DIRECTORY/AudioFinder.app"
BACKUP_APP=""

restore_previous_app() {
  if [[ -n "$BACKUP_APP" && -e "$BACKUP_APP" && ! -e "$INSTALLED_APP" ]]; then
    mv "$BACKUP_APP" "$INSTALLED_APP"
    echo "The previous installation was restored."
  fi
}

trap restore_previous_app ERR INT TERM

SIGNING_ARGUMENTS=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
if [[ -n "${AUDIO_FINDER_TEAM_ID:-}" ]]; then
  SIGNING_ARGUMENTS=(CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$AUDIO_FINDER_TEAM_ID")
fi

echo "Building Audio Finder…"
xcodebuild \
  -project AudioFinder.xcodeproj \
  -scheme AudioFinder \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  build \
  "${SIGNING_ARGUMENTS[@]}"

if [[ ! -d "$BUILT_APP" ]]; then
  echo "Build succeeded, but the app bundle was not found at $BUILT_APP" >&2
  exit 1
fi

app_is_running() {
  [[ "$(osascript -e 'application id "app.audiofinder.mac" is running' 2>/dev/null || true)" == "true" ]]
}

if app_is_running; then
  echo "Closing the running copy of Audio Finder…"
  osascript -e 'tell application id "app.audiofinder.mac" to quit' >/dev/null 2>&1 || true
  for _ in {1..20}; do
    if ! app_is_running; then
      break
    fi
    sleep 0.1
  done
fi

if app_is_running; then
  echo "Audio Finder is still running. Quit it from the menu bar, then run this installer again." >&2
  exit 1
fi

mkdir -p "$INSTALL_DIRECTORY"

if [[ -e "$INSTALLED_APP" ]]; then
  mkdir -p "$HOME/.Trash"
  BACKUP_APP="$HOME/.Trash/AudioFinder previous $(date +%Y%m%d-%H%M%S)-$$.app"
  echo "Moving the previous installation to the Trash…"
  mv "$INSTALLED_APP" "$BACKUP_APP"
fi

echo "Installing to ${INSTALLED_APP}…"
ditto "$BUILT_APP" "$INSTALLED_APP"

BACKUP_APP=""
trap - ERR INT TERM

if [[ "${AUDIO_FINDER_SKIP_OPEN:-0}" == "1" ]]; then
  echo "Skipping launch because AUDIO_FINDER_SKIP_OPEN=1."
else
  echo "Opening Audio Finder…"
  open "$INSTALLED_APP"
fi

echo "Installed. Use the speaker icon in the menu bar, or reopen Audio Finder from Applications."
echo "Launch at login can be enabled from Welcome or Settings."
