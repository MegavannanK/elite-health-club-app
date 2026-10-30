#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "$#" -eq 0 ]; then
  set -- -d web-server --web-hostname localhost --web-port 3000
fi
exec flutter run --dart-define-from-file=config/dev.json "$@"
