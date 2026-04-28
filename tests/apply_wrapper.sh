#!/usr/bin/env bash
# Sources the kind cluster's env file under `set -a` so KUBECONFIG/KUBECTL
# cross the `exec` boundary into the apply_bin.
set -euo pipefail

CLUSTER_NAME="cluster"

if [[ -z "${RUNFILES_DIR:-}" ]]; then
  if [[ -d "${0}.runfiles" ]]; then RUNFILES_DIR="${0}.runfiles"
  elif [[ -d "$(dirname "$0").runfiles" ]]; then RUNFILES_DIR="$(dirname "$0").runfiles"
  fi
  export RUNFILES_DIR
fi
APPLY_BIN="${RUNFILES_DIR}/_main/tests/apply_bin.sh"
[[ -x "$APPLY_BIN" ]] || { echo "wrapper: apply_bin not at $APPLY_BIN" >&2; exit 1; }

env_file="$TEST_TMPDIR/${CLUSTER_NAME}.env"
deadline=$(( $(date +%s) + 60 ))
while [[ ! -f "$env_file" ]]; do
  if (( $(date +%s) >= deadline )); then
    echo "apply_wrapper: kind env file never appeared at $env_file" >&2
    exit 1
  fi
  sleep 1
done

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

exec "$APPLY_BIN"
