#!/usr/bin/env bash
# Asserts the rule under test actually applied the manifest. By the time
# this runs, kubectl_apply has already exited zero (the install path
# blocks on `kubectl wait deploy/hello --for=condition=Available`), so
# the Deployment is guaranteed Available. The assertions below confirm
# the *right* objects landed — proves manifest plumbing + namespace
# handling, not just that kubectl exited 0.
set -euo pipefail

CLUSTER_NAME="cluster"
env_file="$TEST_TMPDIR/${CLUSTER_NAME}.env"
[[ -f "$env_file" ]] || { echo "missing kind env file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$env_file"

KCTL=("$KUBECTL" --kubeconfig="$KUBECONFIG")

echo "smoke_test: namespace 'smoke' exists"
"${KCTL[@]}" get ns smoke -o name

echo "smoke_test: Deployment hello in smoke is Available"
status=$("${KCTL[@]}" -n smoke get deploy hello \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')
if [[ "$status" != "True" ]]; then
  echo "smoke_test: FAIL — Deployment hello is not Available (got $status)" >&2
  "${KCTL[@]}" -n smoke get deploy hello -o yaml >&2
  exit 1
fi

echo "smoke_test: OK — manifest applied + Deployment Available"
