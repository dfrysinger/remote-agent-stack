#!/usr/bin/env bash

set -euo pipefail

MODE=""
WRAPPER=""
SCREEN_WRAPPER=""
BIN_DIR="/usr/local/bin"

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)
      [ $# -ge 2 ] || { echo "--mode requires a value" >&2; exit 2; }
      MODE="$2"; shift 2 ;;
    --wrapper)
      [ $# -ge 2 ] || { echo "--wrapper requires a path" >&2; exit 2; }
      WRAPPER="$2"; shift 2 ;;
    --screen-wrapper)
      [ $# -ge 2 ] || { echo "--screen-wrapper requires a path" >&2; exit 2; }
      SCREEN_WRAPPER="$2"; shift 2 ;;
    --bin-dir)
      [ $# -ge 2 ] || { echo "--bin-dir requires a path" >&2; exit 2; }
      BIN_DIR="$2"; shift 2 ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

case "$MODE" in check|install|uninstall) ;; *) echo "invalid --mode" >&2; exit 2 ;; esac
[ -n "$WRAPPER" ] || { echo "--wrapper is required" >&2; exit 2; }
[ -n "$SCREEN_WRAPPER" ] || { echo "--screen-wrapper is required" >&2; exit 2; }

managed_names="agent-stack copilot-agent claude-agent codex-agent agent-screen"
retired_names="ca cc co ss remote-agent remote-screen"

target_for() {
  case "$1" in
    agent-screen) printf '%s\n' "$SCREEN_WRAPPER" ;;
    remote-screen) printf '%s\n' "$(dirname "$SCREEN_WRAPPER")/remote-screen" ;;
    ss) printf '%s\n' "$(dirname "$SCREEN_WRAPPER")/ss" ;;
    *) printf '%s\n' "$WRAPPER" ;;
  esac
}

is_owned() {
  local path="$1" name="$2"
  [ -L "$path" ] && [ "$(readlink "$path")" = "$(target_for "$name")" ]
}

describe_foreign() {
  local path="$1"
  if [ -L "$path" ]; then
    printf '%s symlinks to %s' "$path" "$(readlink "$path")"
  else
    printf '%s exists and is not an owned symlink' "$path"
  fi
}

if [ "$MODE" = "check" ] || [ "$MODE" = "install" ]; then
  preflight_status=0
  for name in $managed_names; do
    path="$BIN_DIR/$name"
    if [ -e "$path" ] || [ -L "$path" ]; then
      if ! is_owned "$path" "$name"; then
        echo "refusing to overwrite foreign command: $(describe_foreign "$path")" >&2
        preflight_status=1
      fi
    fi
  done
  [ "$preflight_status" -eq 0 ] || exit "$preflight_status"
fi

if [ "$MODE" = "check" ]; then
  for name in $managed_names; do
    path="$BIN_DIR/$name"
    if is_owned "$path" "$name"; then
      echo "owned: $path"
    else
      echo "install: $path -> $(target_for "$name")"
    fi
  done
  for name in $retired_names; do
    path="$BIN_DIR/$name"
    if is_owned "$path" "$name"; then
      echo "remove retired owned alias: $path"
    elif [ -e "$path" ] || [ -L "$path" ]; then
      echo "preserve foreign retired command: $(describe_foreign "$path")"
    fi
  done
  exit 0
fi

if [ "$MODE" = "install" ]; then
  mkdir -p "$BIN_DIR"
  for name in $managed_names; do
    path="$BIN_DIR/$name"
    rm -f "$path"
    target="$(target_for "$name")"
    ln -s "$target" "$path"
    echo "installed $path -> $target"
  done
  for name in $retired_names; do
    path="$BIN_DIR/$name"
    if is_owned "$path" "$name"; then
      rm -f "$path"
      echo "removed retired owned alias $path"
    elif [ -e "$path" ] || [ -L "$path" ]; then
      echo "preserved foreign retired command: $(describe_foreign "$path")"
    fi
  done
  exit 0
fi

for name in $managed_names $retired_names; do
  path="$BIN_DIR/$name"
  if is_owned "$path" "$name"; then
    rm -f "$path"
    echo "removed $path"
  elif [ -e "$path" ] || [ -L "$path" ]; then
    echo "preserved foreign command: $(describe_foreign "$path")"
  fi
done
