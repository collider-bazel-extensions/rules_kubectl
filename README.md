# rules_kubectl

`kubectl apply` as an [`rules_itest`](https://github.com/dzbarsky/rules_itest)
service for Bazel test compositions. Two rules:

- **`kubectl_apply`** — long-running install service. Applies one or
  more manifests, optionally creates a namespace, optionally waits for
  Deployments / rollouts / CRDs, then idles until SIGTERM. Drops into
  `itest_service.exe`.
- **`kubectl_apply_health_check`** — readiness probe. Re-runs the
  configured waits with `--timeout=0s` (non-blocking poll). Drops into
  `itest_service.health_check`.

The reusable building block that the per-operator rule sets
(`rules_certmanager`, `rules_capsule`, `rules_cilium`, `rules_argocd`)
each open-code in their `*_install` rule today. Pair it with
[`rules_helm`](https://github.com/collider-bazel-extensions/rules_helm)
to render a helm chart and apply the output, all inside one
`bazel test`.

**Pinned versions:** none — there's no kubectl binary to pin. The
launcher resolves `$KUBECTL` env (set by `rules_kind`'s per-cluster env
file) > `kubectl` on PATH > fail.

**Supported platforms (v0.1):** any platform where bash + python3 +
kubectl can run. Validated on Linux x86\_64 in CI.

---

## Contents

- [Installation](#installation) (Bzlmod-only)
- [Quickstart](#quickstart)
- [Composition with rules_helm](#composition-with-rules_helm)
- [Rules](#rules)
  - [kubectl\_apply](#kubectl_apply)
  - [kubectl\_apply\_health\_check](#kubectl_apply_health_check)
- [Hermeticity exceptions](#hermeticity-exceptions)
- [Contributing](#contributing)

---

## Installation

```python
bazel_dep(name = "rules_kubectl", version = "0.2.0")
```

That's it — no extension, no toolchain registration, no `use_repo`.
`rules_kubectl` is **Bzlmod-only** in v0.1. Until it lands in BCR,
consume via `archive_override` or a git pin pointing at a tag.

---

## Quickstart

```python
load("@rules_itest//:itest.bzl", "itest_service", "service_test")
load("@rules_kind//:defs.bzl", "kind_cluster", "kind_health_check")
load("@rules_kubectl//:defs.bzl", "kubectl_apply", "kubectl_apply_health_check")
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

# 1. The cluster.
kind_cluster(name = "cluster", k8s_version = "1.35")
kind_health_check(name = "cluster_health", cluster = ":cluster")
itest_service(name = "kind_svc", exe = ":cluster", health_check = ":cluster_health")

# 2. Apply a manifest as an itest service.
kubectl_apply(
    name = "app_bin",
    manifests = ["app.yaml"],
    namespace = "production",
    create_namespace = True,
    wait_for_deployments = ["my-app"],
)
kubectl_apply_health_check(
    name = "app_health_bin",
    namespace = "production",
    wait_for_deployments = ["my-app"],
)

# 3. Wrap with sh_binary to source the kind cluster's env file (so
#    KUBECONFIG / KUBECTL cross the `exec` boundary into app_bin).
sh_binary(
    name = "app_wrapper",
    srcs = ["wrapper.sh"],
    data = [":app_bin"],
)
sh_binary(
    name = "app_health_wrapper",
    srcs = ["health_wrapper.sh"],
    data = [":app_health_bin"],
)
itest_service(
    name = "app_svc",
    exe = ":app_wrapper",
    deps = [":kind_svc"],
    health_check = ":app_health_wrapper",
)
```

The wrapper script template is in `tests/apply_wrapper.sh` — it just
sources `$TEST_TMPDIR/cluster.env` under `set -a` and `exec`s the
inner binary. Same shape every operator rule's smoke test uses.

---

## Composition with rules_helm

The most common consumer flow:

```python
load("@rules_helm//:defs.bzl", "helm_template")
load("@rules_kubectl//:defs.bzl", "kubectl_apply")

filegroup(name = "chart_files", srcs = glob(["chart/**"]))

helm_template(
    name = "rendered",
    chart = [":chart_files"],
    values = ["values-prod.yaml"],
    namespace = "production",
)

kubectl_apply(
    name = "app_bin",
    manifests = [":rendered"],   # <-- helm_template's output IS a YAML file
    namespace = "production",
    create_namespace = True,
    wait_for_deployments = ["my-app"],
)
```

That's a complete "build a chart, apply it, wait for it" pipeline — all
inputs sha-pinned, no host helm or kubectl version pinning required.

---

## Rules

### `kubectl_apply`

Long-running install. `bazel run //my:apply_bin` or use under
`itest_service`.

```python
kubectl_apply(
    name = "app_bin",
    manifests = ["app.yaml", "extras.yaml"],
    namespace = "production",
    create_namespace = True,           # apply Namespace/<ns> first
    server_side = True,                # default: --server-side --validate=false
    kubeconfig_env = "KUBECONFIG",
    wait_for_deployments = ["my-app", "my-other"],
    wait_for_rollouts = ["sts/my-statefulset"],
    wait_for_crds = ["foos.example.com"],
    wait_timeout = "300s",
    retry_attempts = 2,
)
```

**Attributes:**

| Attribute | Type | Default | Description |
|---|---|---|---|
| `manifests` | `label_list` of `.yaml`/`.yml` | required | One or more YAML files. Applied in order via repeated `-f`. |
| `namespace` | `string` | `""` | Passed to `kubectl apply -n` and to wait commands. Per-resource `metadata.namespace` in the manifest takes precedence. |
| `apply_namespace_flag` | `bool` | `True` | Pass `-n <namespace>` to `kubectl apply`. Set `False` for **multi-namespace YAML**. See [Multi-namespace manifests](#multi-namespace-manifests). |
| `create_namespace` | `bool` | `False` | Apply `Namespace/<namespace>` first, idempotent. |
| `server_side` | `bool` | `True` | `--server-side=true --validate=false`. |
| `kubeconfig_env` | `string` | `"KUBECONFIG"` | Env var holding the kubeconfig path. |
| `wait_for_deployments` | `string_list` | `[]` | Deployment names; runs `kubectl wait deploy/<n> --for=condition=Available`. |
| `wait_for_rollouts` | `string_list` | `[]` | `kind/name` strings; runs `kubectl rollout status`. |
| `wait_for_crds` | `string_list` | `[]` | CRD names; runs `kubectl get crd`. |
| `wait_timeout` | `string` | `"300s"` | Per-wait timeout. |
| `retry_attempts` | `int` | `2` | Retries on apply failure with 5s sleep. |

#### Multi-namespace manifests

Some upstream installs (Tekton's `release.yaml`, KEDA's `keda-operator-auth-reader` RoleBinding, etc.) carry resources across more than one namespace in a single YAML file. kubectl rejects this when `-n` is passed:

```
the namespace from the provided object 'kube-system' does not match the namespace 'keda'
```

Set `apply_namespace_flag = False` to drop the `-n` flag from the apply call. Each resource's own `metadata.namespace` then stands. The `namespace` attribute is still used as the default for the wait commands (Deployment / rollout names you list there are looked up in `<namespace>`):

```python
kubectl_apply(
    name = "tekton_install_bin",
    manifests = ["@rules_tekton//private/manifests:tekton.yaml"],
    namespace = "tekton-pipelines",
    apply_namespace_flag = False,                        # <-- multi-ns
    wait_for_deployments = [
        "tekton-pipelines-controller",
        "tekton-pipelines-webhook",
    ],
)
```

### `kubectl_apply_health_check`

Pair with the install above. Same wait shape, with `--timeout=0s`.

```python
kubectl_apply_health_check(
    name = "app_health_bin",
    namespace = "production",
    wait_for_deployments = ["my-app", "my-other"],
    wait_for_rollouts = ["sts/my-statefulset"],
    wait_for_crds = ["foos.example.com"],
)
```

The attributes mirror `kubectl_apply`'s — pass the same values.

---

## Hermeticity exceptions

| Component | Status | Notes |
|---|---|---|
| Manifests | Fully hermetic. Whatever you pass via `manifests` is Bazel-tracked. | |
| `kubectl` | **Not vendored.** Resolved at runtime: `$KUBECTL` > `kubectl` on PATH > fail. | Cluster providers like `rules_kind` already export a matched-version `$KUBECTL` via their per-cluster env file. Pinning here would conflict. |
| Target cluster | Out of scope — bring your own. | |
| Manifest-image network | The cluster's nodes pull container images at runtime. Pre-load with `kind_cluster.images` if you need offline. | |

---

## Contributing

PRs welcome. Conventions match the sibling rule sets:

- New rules need an analysis test in `tests/analysis_tests.bzl`.
- `MODULE.bazel.lock` is intentionally not committed.

### Help wanted: macOS validation

The launcher is platform-independent (bash + python3 + kubectl), but no
one has run the smoke test on Darwin. A pasted log from a green
`bazel test //tests:smoke_test` on macOS would unblock the macOS
support claim.
