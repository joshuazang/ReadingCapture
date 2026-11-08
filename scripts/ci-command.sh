#!/bin/bash
set -euo pipefail
task_log="$(mktemp)"
trap 'rm -f "$task_log"' EXIT
if "$@" > "$task_log" 2>&1; then
  cat "$task_log"
else
  task_exit=$?
  cat "$task_log"
  python3 - "$task_log" <<'PY'
import pathlib,sys
lines=pathlib.Path(sys.argv[1]).read_text(errors='replace').splitlines()[-60:]
message='\n'.join(lines).replace('%','%25').replace('\r','%0D').replace('\n','%0A')
print('::error title=Native package diagnostic::'+message)
PY
  exit "$task_exit"
fi
