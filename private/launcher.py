#!/usr/bin/env python3
"""Runtime launcher for kubectl_apply / kubectl_apply_health_check.

Same role as launcher.py in the operator rule sets. Owns:
- env setup (KUBECONFIG resolution, kubectl resolution honoring $KUBECTL)
- optional namespace pre-create
- apply pass with retry
- waits (Deployments Available / rollouts complete / CRDs registered)
- SIGTERM/SIGINT forwarding so itest can stop the long-running install
  service cleanly

Designed to be reusable: the per-version operator rule sets
(rules_certmanager, rules_capsule, rules_cilium, rules_argocd) each carry
a near-identical copy of this logic today — when those projects move to
depend on rules_kubectl, this becomes the canonical implementation.
"""

from __future__ import annotations

import argparse
import os
import shutil
import signal
import subprocess
import sys
import time


def _resolve_runfiles(rel: str) -> str:
    rfd = os.environ.get("RUNFILES_DIR") or os.environ.get("TEST_SRCDIR")
    if not rfd:
        return rel
    candidate = os.path.join(rfd, "_main", rel)
    if os.path.exists(candidate):
        return candidate
    candidate = os.path.join(rfd, rel)
    if os.path.exists(candidate):
        return candidate
    return rel


def _kubeconfig_from_env(name: str) -> str | None:
    if name and os.environ.get(name):
        return os.environ[name]
    if os.environ.get("KUBECONFIG"):
        return os.environ["KUBECONFIG"]
    return None


def _resolve_kubectl() -> str | None:
    """Resolve `kubectl`. Prefer `$KUBECTL` (set by `rules_kind`'s per-cluster
    env file, which points at the kubectl that shipped with the cluster's
    toolchain — same version as the API server). Fall back to whatever's
    on PATH."""
    cand = os.environ.get("KUBECTL")
    if cand and os.path.isfile(cand) and os.access(cand, os.X_OK):
        return cand
    return shutil.which("kubectl")


def _run(cmd: list[str], env: dict[str, str], stdin: bytes | None = None,
         capture: bool = False) -> tuple[int, str]:
    print("rules_kubectl: " + " ".join(cmd), file=sys.stderr, flush=True)
    if capture:
        cp = subprocess.run(cmd, env=env, input=stdin, capture_output=True)
        return cp.returncode, cp.stdout.decode("utf-8", errors="replace")
    return subprocess.run(cmd, env=env, input=stdin).returncode, ""


def _ensure_namespace(kubectl: str, kubeconfig: str, ns: str,
                      env: dict[str, str]) -> int:
    """Apply a Namespace/<ns> resource, idempotent. Useful for manifests
    that don't include a Namespace of their own (Argo CD's install.yaml,
    e.g.)."""
    yaml = f"apiVersion: v1\nkind: Namespace\nmetadata:\n  name: {ns}\n".encode()
    rc, _ = _run([kubectl, "--kubeconfig", kubeconfig, "apply", "-f", "-"],
                 env, stdin=yaml)
    return rc


def _apply(kubectl: str, kubeconfig: str, manifests: list[str], namespace: str,
           server_side: bool, retry_attempts: int, env: dict[str, str]) -> int:
    cmd = [kubectl, "--kubeconfig", kubeconfig, "apply"]
    if namespace:
        cmd.extend(["-n", namespace])
    if server_side:
        cmd.extend(["--server-side=true", "--validate=false"])
    for m in manifests:
        cmd.extend(["-f", m])

    last_rc = 1
    for attempt in range(1, max(retry_attempts, 1) + 1):
        last_rc, _ = _run(cmd, env)
        if last_rc == 0:
            return 0
        if attempt < retry_attempts:
            print(
                f"rules_kubectl: apply attempt {attempt} failed; retrying after 5s.",
                file=sys.stderr,
            )
            time.sleep(5)
    return last_rc


def _do_waits(kubectl: str, kubeconfig: str, namespace: str, timeout: str,
              wait_deployments: list[str], wait_rollouts: list[str],
              wait_crds: list[str], env: dict[str, str]) -> int:
    """Run all configured waits. Returns 0 only if every wait succeeded."""
    base = [kubectl, "--kubeconfig", kubeconfig]

    # CRD checks: no namespace; just `get crd <name>`.
    for crd in wait_crds:
        rc, _ = _run(base + ["get", "crd", crd, "-o", "name"], env)
        if rc != 0:
            return rc

    # Deployment Available waits.
    for dep in wait_deployments:
        rc, _ = _run(
            base + (["-n", namespace] if namespace else []) +
            ["wait", f"deploy/{dep}", "--for=condition=Available",
             f"--timeout={timeout}"],
            env,
        )
        if rc != 0:
            return rc

    # StatefulSet/Deployment rollouts. Caller passes "kind/name" (e.g.
    # "sts/argocd-application-controller").
    for ro in wait_rollouts:
        rc, _ = _run(
            base + (["-n", namespace] if namespace else []) +
            ["rollout", "status", ro, f"--timeout={timeout}"],
            env,
        )
        if rc != 0:
            return rc

    return 0


def _install(args, env: dict[str, str]) -> int:
    kubectl = _resolve_kubectl()
    if not kubectl:
        print(
            "rules_kubectl: kubectl not found. Set $KUBECTL (e.g. via "
            "rules_kind's env file) or put kubectl on $PATH.",
            file=sys.stderr,
        )
        return 127

    kubeconfig = _kubeconfig_from_env(args.kubeconfig_env)
    if not kubeconfig:
        print(
            f"rules_kubectl: no kubeconfig — set ${args.kubeconfig_env} or $KUBECONFIG.",
            file=sys.stderr,
        )
        return 2
    env["KUBECONFIG"] = kubeconfig

    manifests = [_resolve_runfiles(m) for m in args.manifests]
    for m in manifests:
        if not os.path.isfile(m):
            print(f"rules_kubectl: manifest not in runfiles: {m}",
                  file=sys.stderr)
            return 2

    if args.create_namespace and args.namespace:
        rc = _ensure_namespace(kubectl, kubeconfig, args.namespace, env)
        if rc != 0:
            return rc

    rc = _apply(kubectl, kubeconfig, manifests, args.namespace,
                args.server_side, args.retry_attempts, env)
    if rc != 0:
        return rc

    rc = _do_waits(kubectl, kubeconfig, args.namespace, args.wait_timeout,
                   args.wait_deployments, args.wait_rollouts,
                   args.wait_crds, env)
    if rc != 0:
        return rc

    print("rules_kubectl: applied + ready; sleeping until SIGTERM",
          file=sys.stderr, flush=True)
    while True:
        time.sleep(3600)


def _health_check(args, env: dict[str, str]) -> int:
    kubectl = _resolve_kubectl()
    if not kubectl:
        print(
            "rules_kubectl: kubectl not found. Set $KUBECTL or put kubectl on $PATH.",
            file=sys.stderr,
        )
        return 127

    kubeconfig = _kubeconfig_from_env(args.kubeconfig_env)
    if not kubeconfig:
        print(
            f"rules_kubectl: no kubeconfig — set ${args.kubeconfig_env} or $KUBECONFIG.",
            file=sys.stderr,
        )
        return 2
    env["KUBECONFIG"] = kubeconfig

    # Health check uses --timeout=0s for an immediate, non-blocking poll —
    # itest re-runs the health_check on its own schedule.
    return _do_waits(kubectl, kubeconfig, args.namespace, "0s",
                     args.wait_deployments, args.wait_rollouts,
                     args.wait_crds, env)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["install", "health_check"], required=True)
    ap.add_argument("--manifests", action="append", default=[],
                    help="Repeated. Manifest YAML file paths (install mode).")
    ap.add_argument("--namespace", default="")
    ap.add_argument("--create-namespace", action="store_true",
                    help="Apply Namespace/<namespace> before manifests "
                         "(install mode). Idempotent.")
    ap.add_argument("--server-side", action="store_true",
                    help="Pass --server-side=true --validate=false to apply.")
    ap.add_argument("--kubeconfig-env", default="KUBECONFIG")
    ap.add_argument("--wait-deployment", action="append", default=[],
                    dest="wait_deployments")
    ap.add_argument("--wait-rollout", action="append", default=[],
                    dest="wait_rollouts",
                    help='Like "sts/<name>" or "deploy/<name>"; passed to '
                         '`kubectl rollout status`.')
    ap.add_argument("--wait-crd", action="append", default=[],
                    dest="wait_crds")
    ap.add_argument("--wait-timeout", default="300s")
    ap.add_argument("--retry-attempts", type=int, default=2)
    args = ap.parse_args(argv[1:])

    env = os.environ.copy()

    if args.mode == "install":
        proc_func = lambda: _install(args, env)
    else:
        proc_func = lambda: _health_check(args, env)

    def handle(_signum, _frame):
        sys.exit(143)

    signal.signal(signal.SIGTERM, handle)
    signal.signal(signal.SIGINT, handle)

    return proc_func() or 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
