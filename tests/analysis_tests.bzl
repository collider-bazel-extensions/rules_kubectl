"""Analysis-time tests. Verify rules instantiate cleanly and expose
DefaultInfo without invoking kubectl at analysis time."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_kubectl//:defs.bzl", "kubectl_apply", "kubectl_apply_health_check")

def _has_executable_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(
        env,
        target[DefaultInfo].files_to_run.executable != None,
        "expected target to expose an executable",
    )
    return analysistest.end(env)

_has_executable_test = analysistest.make(_has_executable_impl)

def kubectl_apply_test_suite(name):
    kubectl_apply(
        name = name + "_subject",
        manifests = ["manifest.yaml"],
        tags = ["manual"],
    )
    _has_executable_test(name = name + "_executable", target_under_test = ":" + name + "_subject")

    # Cover the multi-namespace YAML path: apply_namespace_flag = False.
    kubectl_apply(
        name = name + "_multi_ns_subject",
        manifests = ["manifest.yaml"],
        namespace = "primary-ns",
        apply_namespace_flag = False,
        tags = ["manual"],
    )
    _has_executable_test(
        name = name + "_multi_ns_executable",
        target_under_test = ":" + name + "_multi_ns_subject",
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_executable",
            ":" + name + "_multi_ns_executable",
        ],
    )

def kubectl_apply_health_check_test_suite(name):
    kubectl_apply_health_check(
        name = name + "_subject",
        tags = ["manual"],
    )
    _has_executable_test(name = name + "_executable", target_under_test = ":" + name + "_subject")
    native.test_suite(name = name, tests = [":" + name + "_executable"])
