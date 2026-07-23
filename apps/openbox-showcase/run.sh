#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$APP_DIR/../.." && pwd)

started_service=0
service_pid=
if ! curl --silent --fail http://127.0.0.1:7070/healthz >/dev/null; then
  set --
  for name in OPENAI_API_KEY ANTHROPIC_API_KEY GOOGLE_API_KEY GITHUB_TOKEN GH_TOKEN ${OPENBOX_ALLOW_ENV:-}; do
    if printenv "$name" >/dev/null 2>&1; then
      set -- "$@" --allow-env "$name"
    fi
  done
  swift run --package-path "$REPO_DIR" openbox serve "$@" &
  service_pid=$!
  started_service=1
  until curl --silent --fail http://127.0.0.1:7070/healthz >/dev/null; do
    kill -0 "$service_pid"
    sleep 1
  done
fi

cleanup() {
  if [ "$started_service" -eq 1 ]; then
    kill "$service_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

swift build --package-path "$APP_DIR" --product OpenBoxShowcase
BIN_DIR=$(swift build --package-path "$APP_DIR" --show-bin-path)
REPO_BIN_DIR=$(swift build --package-path "$REPO_DIR" --show-bin-path)
APP_BUNDLE="$APP_DIR/.build/OpenBoxShowcase.app"
DEMO_WORKSPACE="$APP_DIR/.build/demo-workspace"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
if ! git -C "$DEMO_WORKSPACE" rev-parse --git-dir >/dev/null 2>&1; then
  git init -q "$DEMO_WORKSPACE"
  touch "$DEMO_WORKSPACE/hello.txt"
fi
cp "$BIN_DIR/OpenBoxShowcase" "$APP_BUNDLE/Contents/MacOS/OpenBoxShowcase"
cp "$REPO_BIN_DIR/openbox" "$APP_BUNDLE/Contents/MacOS/openbox"
cp "$APP_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
open -W -n "$APP_BUNDLE" --args "$DEMO_WORKSPACE"
