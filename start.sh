#!/bin/sh
set -e
cd "$(dirname "$0")"
if ! command -v dart >/dev/null 2>&1; then
  echo "Dart was not found on PATH."
  echo "Install the Dart SDK, then run this file again. This launcher does not download packages."
  exit 1
fi
exec dart run "$(pwd)/packages/ayu_manager/bin/ayu_manager.dart" --root "$(pwd)/run"
