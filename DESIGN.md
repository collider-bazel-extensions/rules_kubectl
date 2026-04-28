# rules_kubectl — design decisions

`kubectl_apply` and `kubectl_apply_health_check`: a long-running
`itest_service`-shaped rule that applies one or more YAML manifests to
a cluster and a matching readiness probe. The reusable building block
that all the per-operator rule sets (`rules_certmanager`, `rules_capsule`,
`rules_cilium`, `rules_argocd`) currently each open-code in their own
`*_install` rule.

Family: same as the operator rules (long-running install service that
itest can manage), distinct from the build-time CLI wrappers
(`rules_helm`, `rules_opa`).

## Decided

| # | Decision | Choice | Source |
|---|---|---|---|
| 1 | Bzlmod / WORKSPACE | **Bzlmod-only at v0.1.** | Sibling-family precedent |
| 2 | No vendored kubectl | The launcher resolves `$KUBECTL` env > `kubectl` on PATH > fail. **No toolchain, no module extension.** Reason: kubectl version should match the cluster's API server version, and the cluster provider (`rules_kind`) already exports `$KUBECTL` pointing at a matched binary. Pinning kubectl in rules_kubectl would either mismatch under cluster providers that bring their own, or duplicate rules_kind's per-version downloads. | rules_certmanager / rules_capsule precedent |
| 3 | Public surface | `kubectl_apply` (long-running install, drops into `itest_service.exe`) + `kubectl_apply_health_check` (probe, drops into `itest_service.health_check`). No convenience macro that emits `itest_service` for the consumer — match the per-operator convention where consumers wire `itest_service(deps = […])` themselves. | All operator-rule siblings |
| 4 | Manifest input shape | `manifests = label_list(allow_files = ['.yaml', '.yml'])`. Multiple manifests are applied in order via repeated `-f` to a single `kubectl apply`. Common consumer flow: feed the output of `helm_template` (`rules_helm`) directly. | Helm-friendly |
| 5 | Wait shape | Three orthogonal lists: `wait_for_deployments` (`kubectl wait deploy --for=condition=Available`), `wait_for_rollouts` (`kubectl rollout status <kind/name>`), `wait_for_crds` (`kubectl get crd <name>`). Install runs them with `--timeout=<wait_timeout>` (default 300s) before idling. Health check re-runs them with `--timeout=0s` (non-blocking poll). | Covers the wait shapes used by every operator rule we've shipped |
| 6 | Namespace handling | Two attrs: `namespace` (passed to `kubectl apply -n <ns>` and to all wait commands), `create_namespace` (apply a `Namespace/<ns>` resource first, idempotent). The latter is for manifests that don't include their own Namespace (Argo CD's `install.yaml`, e.g.). | Argo CD-driven |
| 7 | Server-side apply | `server_side = True` by default. Most non-trivial operator manifests need SSA (Cilium's chart, e.g., uses fields the CR client-side validator doesn't know). Consumers who actively need client-side can opt out. | Pragmatic |
| 8 | Retry behavior | `retry_attempts` defaults to 2. The retry sleeps 5s and tries again; useful for early-cluster API-server warm-up races. | Same value as every operator rule |
| 9 | Toolchain type | **None.** No toolchain emitted — this rule has no platform-specific binaries. | Simplest viable |
| 10 | Hermeticity | The rule is hermetic with respect to inputs (manifests are Bazel-tracked), but **not** with respect to kubectl (host kubectl or `$KUBECTL` env). That's the same trade rules_certmanager / rules_capsule made: hermetic kubectl is a multi-version problem better solved by the cluster provider. | Sibling-family policy |
| 11 | MODULE deps (consumer-visible) | `bazel_skylib`, `platforms`, `rules_python` (the launcher is python). `rules_kind`/`rules_itest`/`rules_shell` are dev-only for the smoke. | Sibling-family |
| 12 | Naming | snake_case rules, `MixedCaseInfo` providers (none in v0.1; could add a `KubectlApplyInfo` later if downstream rules want introspection), `UPPER_SNAKE` constants. | All siblings |
| 13 | Default test tags | Smoke is `["manual", "no-sandbox", "requires-network"]`. | rules_kind precedent |

## Notes

- The launcher (`private/launcher.py`) is a near-superset of the per-operator launchers in rules_certmanager / rules_capsule / rules_cilium / rules_argocd. The natural follow-up is to have those rule sets switch to `kubectl_apply` (with manifest = `<their committed manifest>`, `wait_for_deployments = […]`, etc.) and shrink to just version pinning + per-operator render flags.
- The smoke composition is the minimum that proves the rule end-to-end: kind cluster → `kubectl_apply` of a tiny `Namespace + Deployment` manifest → assertion that the Deployment is Available. Real consumers will plug in `helm_template` outputs and richer wait lists.

## v0.1.0 status (planning)

| Area | State |
|---|---|
| MODULE.bazel (Bzlmod-only) | planned |
| `kubectl_apply`, `kubectl_apply_health_check` rules | planned |
| `launcher.py` (env, kubectl exec, namespace pre-create, waits, SIGTERM) | planned |
| Analysis tests | planned |
| In-tree smoke (kind + Namespace + Deployment + assertion) | planned |
| End-to-end `bazel test` runtime | planned (validated under CI Docker; macOS pending) |

## Deferred (not v0.1.0)

- **`KubectlApplyInfo` provider** — would let downstream rules introspect the applied manifest set. No consumer asks for this yet.
- **Custom waits beyond Deployments / StatefulSets / CRDs** — e.g. arbitrary `--for=jsonpath=...` predicates. Add a `wait_args = [string_list]` escape hatch when needed.
- **Cleanup-on-shutdown** — `kubectl_apply`'s SIGTERM handler currently just exits. Add an option to `kubectl delete -f <manifests>` on SIGTERM if a consumer wants ephemeral installs.
- **`kubectl_diff` test rule** — golden-file manifest tests against a live cluster. Useful but its own design.
- **Migrating the operator rule sets to depend on rules_kubectl** — biggest payoff of the project, but a separate refactor PR per project.
