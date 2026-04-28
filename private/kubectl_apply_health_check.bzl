"""kubectl_apply_health_check — readiness probe for `kubectl_apply` services.

Re-runs the same wait checks as the install rule but with a non-blocking
`--timeout=0s` (so it returns immediately whether ready or not). itest
calls this on its own polling cadence between SIGTERM-able service
starts.
"""

def _flag_repeated(flag, values):
    if not values:
        return ""
    return " ".join(["{} {}".format(flag, _sh_quote(v)) for v in values])

def _sh_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"

def _impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._tmpl,
        output = out,
        substitutions = {
            "{LAUNCHER}":           ctx.executable._launcher.short_path,
            "{KUBECONFIG_ENV}":     ctx.attr.kubeconfig_env,
            "{NAMESPACE}":          ctx.attr.namespace,
            "{WAIT_DEPLOY_FLAGS}":  _flag_repeated("--wait-deployment", ctx.attr.wait_for_deployments),
            "{WAIT_ROLLOUT_FLAGS}": _flag_repeated("--wait-rollout", ctx.attr.wait_for_rollouts),
            "{WAIT_CRD_FLAGS}":     _flag_repeated("--wait-crd", ctx.attr.wait_for_crds),
        },
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [ctx.executable._launcher])
    runfiles = runfiles.merge(ctx.attr._launcher[DefaultInfo].default_runfiles)
    return [DefaultInfo(executable = out, runfiles = runfiles)]

kubectl_apply_health_check = rule(
    implementation = _impl,
    attrs = {
        "namespace": attr.string(
            doc = "Namespace for the Deployment/rollout waits. CRDs are " +
                  "cluster-scoped so namespace doesn't apply to them.",
        ),
        "kubeconfig_env": attr.string(default = "KUBECONFIG"),
        "wait_for_deployments": attr.string_list(
            doc = "Same shape as `kubectl_apply.wait_for_deployments`. " +
                  "Pass the same values as the paired install rule.",
        ),
        "wait_for_rollouts": attr.string_list(
            doc = "Same shape as `kubectl_apply.wait_for_rollouts`.",
        ),
        "wait_for_crds": attr.string_list(
            doc = "Same shape as `kubectl_apply.wait_for_crds`.",
        ),
        "_launcher": attr.label(
            default = "//private:launcher",
            executable = True,
            cfg = "exec",
        ),
        "_tmpl": attr.label(
            default = "//private:health_check.sh.tmpl",
            allow_single_file = True,
        ),
    },
    executable = True,
)
