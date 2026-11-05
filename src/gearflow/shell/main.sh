#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    printf 'ERROR: gearflow requires Bash 4.4 or newer.\n' >&2
    exit 1
fi

GEARFLOW_SHELL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GEARFLOW_PYTHON="${GEARFLOW_PYTHON:-python3}"
# Also support source checkouts and direct sourcing in offline tests.
export PYTHONPATH="${GEARFLOW_SHELL_DIR}/../..${PYTHONPATH:+:$PYTHONPATH}"

for module in common git spec upstream layout prepare girar build state workflow publish cli; do
    # shellcheck source=/dev/null
    source "$GEARFLOW_SHELL_DIR/$module.sh"
done
unset module

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
