#!/usr/bin/env bash
set -euo pipefail

tools_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_dir="${1:-$tools_dir/..}"
source_dir="$(cd -- "$source_dir" && pwd)"
python="${PYTHON:-python3}"
output="${GEARFLOW_DIST_DIR:-$source_dir/dist}"
work="${GEARFLOW_BUILD_DIR:-$source_dir/build/binary}"

[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || {
    printf 'This build target requires Linux x86_64.\n' >&2
    exit 1
}

"$python" -m PyInstaller \
    --noconfirm --clean --onefile --noupx \
    --name gearflow-linux-x86_64 \
    --paths "$source_dir/src" \
    --add-data "$source_dir/src/gearflow/shell:gearflow/shell" \
    --add-data "$source_dir/LICENSE:." \
    --distpath "$output" --workpath "$work" --specpath "$work" \
    "$tools_dir/frozen_main.py"
