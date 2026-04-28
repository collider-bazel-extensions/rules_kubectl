"""Public API for rules_kubectl."""

load("//private:kubectl_apply.bzl", _kubectl_apply = "kubectl_apply")
load("//private:kubectl_apply_health_check.bzl", _kubectl_apply_health_check = "kubectl_apply_health_check")

kubectl_apply = _kubectl_apply
kubectl_apply_health_check = _kubectl_apply_health_check
