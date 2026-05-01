"""kubectl_apply — long-running install service for `rules_itest` compositions.

Applies one or more manifests to the cluster pointed at by the
configured kubeconfig env var, optionally creates the namespace first,
then blocks on the configured waits before idling. On SIGTERM it exits
cleanly so itest can tear the composition down.

Pair with `kubectl_apply_health_check` (separate rule) for the itest
service's `health_check` attribute.
"""

def _flag_repeated(flag, values):
    if not values:
        return ""
    return " ".join(["{} {}".format(flag, _sh_quote(v)) for v in values])

def _sh_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"

def _impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".sh")
    manifests = ctx.files.manifests
    if not manifests:
        fail("kubectl_apply {}: manifests must be non-empty".format(ctx.label))

    manifest_flags = _flag_repeated("--manifests", [m.short_path for m in manifests])
    wait_deploy_flags = _flag_repeated("--wait-deployment", ctx.attr.wait_for_deployments)
    wait_rollout_flags = _flag_repeated("--wait-rollout", ctx.attr.wait_for_rollouts)
    wait_crd_flags = _flag_repeated("--wait-crd", ctx.attr.wait_for_crds)

    ctx.actions.expand_template(
        template = ctx.file._tmpl,
        output = out,
        substitutions = {
            "{LAUNCHER}":         ctx.executable._launcher.short_path,
            "{KUBECONFIG_ENV}":   ctx.attr.kubeconfig_env,
            "{NAMESPACE}":        ctx.attr.namespace,
            "{APPLY_NS_FLAG}":    "" if ctx.attr.apply_namespace_flag else "--no-apply-namespace-flag",
            "{CREATE_NS_FLAG}":   "--create-namespace" if ctx.attr.create_namespace else "",
            "{SERVER_SIDE_FLAG}": "--server-side" if ctx.attr.server_side else "",
            "{WAIT_TIMEOUT}":     ctx.attr.wait_timeout,
            "{RETRY_ATTEMPTS}":   str(ctx.attr.retry_attempts),
            "{MANIFEST_FLAGS}":   manifest_flags,
            "{WAIT_DEPLOY_FLAGS}":  wait_deploy_flags,
            "{WAIT_ROLLOUT_FLAGS}": wait_rollout_flags,
            "{WAIT_CRD_FLAGS}":     wait_crd_flags,
        },
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [ctx.executable._launcher] + manifests)
    runfiles = runfiles.merge(ctx.attr._launcher[DefaultInfo].default_runfiles)
    return [DefaultInfo(executable = out, runfiles = runfiles)]

kubectl_apply = rule(
    implementation = _impl,
    attrs = {
        "manifests": attr.label_list(
            allow_files = [".yaml", ".yml"],
            mandatory = True,
            doc = "One or more YAML manifests to apply, in order. Each is " +
                  "passed to `kubectl apply` via `-f`. Use this for " +
                  "checked-in YAML files OR for the output of " +
                  "`helm_template` (or any rule producing a YAML file).",
        ),
        "namespace": attr.string(
            doc = "Sets `--namespace` on the apply call. Per-resource " +
                  "namespaces hard-coded in the manifest take precedence; " +
                  "this only affects resources without a namespace set. " +
                  "Also used as the default namespace for the wait " +
                  "commands (Deployments / rollouts).",
        ),
        "apply_namespace_flag": attr.bool(
            default = True,
            doc = "Pass `-n <namespace>` to `kubectl apply`. Set to " +
                  "`False` for **multi-namespace YAML** — manifests " +
                  "where individual resources carry their own " +
                  "`metadata.namespace` covering more than one " +
                  "namespace, or a mix of namespaced + non-default " +
                  "namespaces. kubectl rejects multi-namespace YAML " +
                  "when `-n` is set (\"the namespace from the provided " +
                  "object 'X' does not match the namespace 'Y'\"); " +
                  "dropping the flag lets each resource's own " +
                  "namespace stand. The `namespace` attribute is " +
                  "still used for the wait commands.",
        ),
        "create_namespace": attr.bool(
            default = False,
            doc = "Apply a `Namespace/<namespace>` resource before the " +
                  "manifests (idempotent). Useful for manifests that " +
                  "don't include their own Namespace.",
        ),
        "server_side": attr.bool(
            default = True,
            doc = "Pass `--server-side=true --validate=false`. Default on " +
                  "because most non-trivial operator manifests need SSA.",
        ),
        "kubeconfig_env": attr.string(
            default = "KUBECONFIG",
            doc = "Env var holding the kubeconfig path. Under " +
                  "`rules_kind` + `rules_itest` you typically point this " +
                  "at the cluster's env file's `KUBECONFIG`.",
        ),
        "wait_for_deployments": attr.string_list(
            doc = "Deployment names (without kind prefix) in the " +
                  "configured namespace. The launcher runs " +
                  "`kubectl wait deploy/<name> --for=condition=Available` " +
                  "for each before idling.",
        ),
        "wait_for_rollouts": attr.string_list(
            doc = '`kind/name` strings (e.g. "sts/argocd-application-controller", ' +
                  '"deploy/cilium-operator"). Each is passed to ' +
                  '`kubectl rollout status`.',
        ),
        "wait_for_crds": attr.string_list(
            doc = "Fully-qualified CRD names (e.g. `applications.argoproj.io`). " +
                  "The launcher runs `kubectl get crd <name>` for each " +
                  "before idling.",
        ),
        "wait_timeout": attr.string(
            default = "300s",
            doc = "Timeout passed to each `kubectl wait` / `kubectl " +
                  "rollout status` call.",
        ),
        "retry_attempts": attr.int(
            default = 2,
            doc = "How many times to retry the apply on failure. Set to 1 " +
                  "for no retry. Useful when the cluster's API server is " +
                  "still warming up.",
        ),
        "_launcher": attr.label(
            default = "//private:launcher",
            executable = True,
            cfg = "exec",
        ),
        "_tmpl": attr.label(
            default = "//private:install.sh.tmpl",
            allow_single_file = True,
        ),
    },
    executable = True,
)
