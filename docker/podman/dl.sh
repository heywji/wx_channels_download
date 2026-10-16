#!/bin/sh
# Pick a recently watched video and download it. See wxdl.py for details.
# Usage: ./dl.sh [-r] [-n COUNT] [INDEX]
exec python3 -I "$(cd "$(dirname "$0")" && pwd)/wxdl.py" "$@"
