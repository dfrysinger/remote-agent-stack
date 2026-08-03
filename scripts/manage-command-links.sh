#!/usr/bin/env bash

set -euo pipefail

MODE=""
WRAPPER=""
BIN_DIR="/usr/local/bin"

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)
      [ $# -ge 2 ] || { echo "--mode requires a value" >&2; exit 2; }
      MODE="$2"; shift 2 ;;
    --wrapper)
      [ $# -ge 2 ] || { echo "--wrapper requires a path" >&2; exit 2; }
      WRAPPER="$2"; shift 2 ;;
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

managed_names="remote-agent copilot-agent claude-agent codex-agent"
retired_names="ca cc co"

is_owned() {
  [ -L "$1" ] && [ "$(readlink "$1")" = "$WRAPPER" ]
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
      if ! is_owned "$path"; then
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
    if is_owned "$path"; then
      echo "owned: $path"
    else
      echo "install: $path -> $WRAPPER"
    fi
  done
  for name in $retired_names; do
    path="$BIN_DIR/$name"
    if is_owned "$path"; then
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
    ln -s "$WRAPPER" "$path"
    echo "installed $path -> $WRAPPER"
  done
  for name in $retired_names; do
    path="$BIN_DIR/$name"
    if is_owned "$path"; then
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
  if is_owned "$path"; then
    rm -f "$path"
    echo "removed $path"
  elif [ -e "$path" ] || [ -L "$path" ]; then
    echo "preserved foreign command: $(describe_foreign "$path")"
  fi
done
