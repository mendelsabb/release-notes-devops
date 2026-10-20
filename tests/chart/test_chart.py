"""Policy tests for the Helm chart, rendered exactly as Argo CD renders it."""

import shutil
import subprocess
from pathlib import Path

import pytest
import yaml

pytestmark = [
    pytest.mark.chart,
    pytest.mark.skipif(shutil.which("helm") is None, reason="helm not installed"),
]

ROOT = Path(__file__).resolve().parents[2]
CHART = ROOT / "helm/release-notes"
DIGEST = "sha256:" + "a" * 64


def render(env: str, *extra: str) -> dict[tuple[str, str], dict]:
    env_dir = ROOT / "gitops/environments" / env
    out = subprocess.run(
        ["helm", "template", "release-notes", str(CHART), "--namespace", env,
         "-f", str(env_dir / "values.yaml"), "-f", str(env_dir / "image.yaml"),
         "--set", f"image.digest={DIGEST}", *extra],
        check=True, capture_output=True, text=True,
    ).stdout  # fmt: skip
    docs = [d for d in yaml.safe_load_all(out) if d]
    return {(d["kind"], d["metadata"]["name"]): d for d in docs}


@pytest.fixture(scope="module", params=["dev", "prod"])
def env(request):
    return request.param


@pytest.fixture(scope="module")
def objs(env):
    return render(env)


def app_container(objs):
    return objs[("Deployment", "release-notes")]["spec"]["template"]["spec"]["containers"][0]


def test_no_secrets_are_rendered(objs):
    # Credentials come from a pre-existing Secret, never from Git.
    assert not [k for k in objs if k[0] == "Secret"]
    env_vars = {e["name"]: e for e in app_container(objs)["env"]}
    ref = env_vars["DATABASE_PASSWORD"]["valueFrom"]["secretKeyRef"]
    assert ref == {"name": "release-notes-db", "key": "password"}
    assert "PASSWORD" not in str(objs[("ConfigMap", "release-notes-config")]["data"])


def test_image_is_pinned_by_digest(objs):
    assert app_container(objs)["image"].endswith("@" + DIGEST)
    job = objs[("Job", "release-notes-migrate")]["spec"]["template"]["spec"]["containers"][0]
    assert job["image"] == app_container(objs)["image"]
    db = objs[("StatefulSet", "release-notes-db")]["spec"]["template"]["spec"]["containers"][0]
    assert "@sha256:" in db["image"]


def test_probes_have_distinct_semantics(objs):
    c = app_container(objs)
    assert c["readinessProbe"]["httpGet"]["path"] == "/ready"  # checks the DB
    assert c["livenessProbe"]["httpGet"]["path"] == "/health"  # does not
    assert c["readinessProbe"]["timeoutSeconds"] <= c["readinessProbe"]["periodSeconds"]


def test_resources_requests_and_limits(objs):
    for kind, name in [("Deployment", "release-notes"), ("StatefulSet", "release-notes-db")]:
        for c in objs[(kind, name)]["spec"]["template"]["spec"]["containers"]:
            assert {"cpu", "memory"} <= c["resources"]["requests"].keys()
            assert "memory" in c["resources"]["limits"]


def test_security_context(objs):
    pod = objs[("Deployment", "release-notes")]["spec"]["template"]["spec"]
    sc = app_container(objs)["securityContext"]
    assert sc["runAsNonRoot"] and sc["readOnlyRootFilesystem"]
    assert sc["allowPrivilegeEscalation"] is False
    assert sc["capabilities"]["drop"] == ["ALL"]
    assert pod["automountServiceAccountToken"] is False
    assert {"name": "tmp", "mountPath": "/tmp"} in app_container(objs)["volumeMounts"]


def test_graceful_shutdown_budget(objs):
    pod = objs[("Deployment", "release-notes")]["spec"]["template"]["spec"]
    pre_stop = app_container(objs)["lifecycle"]["preStop"]["sleep"]["seconds"]
    drain = int(objs[("ConfigMap", "release-notes-config")]["data"]["GRACEFUL_TIMEOUT"])
    # preStop runs inside the grace period; SIGKILL must not cut the drain short.
    assert pod["terminationGracePeriodSeconds"] > pre_stop + drain


def test_zero_downtime_strategy(objs):
    spec = objs[("Deployment", "release-notes")]["spec"]
    assert spec["strategy"]["rollingUpdate"] == {"maxSurge": 1, "maxUnavailable": 0}
    assert spec["progressDeadlineSeconds"] > 0


def test_argo_sync_ordering(objs):
    def wave(kind, name):
        return int(objs[(kind, name)]["metadata"]["annotations"]["argocd.argoproj.io/sync-wave"])

    job = objs[("Job", "release-notes-migrate")]["metadata"]["annotations"]
    assert job["argocd.argoproj.io/hook"] == "Sync"
    assert wave("StatefulSet", "release-notes-db") < wave("Job", "release-notes-migrate")
    assert wave("Job", "release-notes-migrate") < wave("Deployment", "release-notes")


def test_database_not_exposed_and_restricted(objs):
    assert objs[("Service", "release-notes-db")]["spec"]["clusterIP"] == "None"
    policy = objs[("NetworkPolicy", "release-notes-db")]["spec"]
    assert policy["policyTypes"] == ["Ingress"]
    assert policy["ingress"][0]["ports"] == [{"port": 5432, "protocol": "TCP"}]


def test_dev_environment():
    objs = render("dev")
    assert objs[("Deployment", "release-notes")]["spec"]["replicas"] == 1
    assert objs[("ConfigMap", "release-notes-config")]["data"]["LOG_LEVEL"] == "DEBUG"
    assert ("HorizontalPodAutoscaler", "release-notes") not in objs


def test_prod_environment():
    objs = render("prod")
    deploy = objs[("Deployment", "release-notes")]
    # Replica count is owned by the HPA, so Argo CD and the HPA never fight over it.
    assert "replicas" not in deploy["spec"]
    hpa = objs[("HorizontalPodAutoscaler", "release-notes")]["spec"]
    assert hpa["minReplicas"] >= 2
    assert objs[("PodDisruptionBudget", "release-notes")]["spec"]["minAvailable"] == 1
    assert deploy["spec"]["minReadySeconds"] > 0
    assert objs[("ConfigMap", "release-notes-config")]["data"]["LOG_LEVEL"] == "INFO"


def test_rendering_fails_without_an_image():
    result = subprocess.run(
        ["helm", "template", "x", str(CHART), "--set", "image.digest=", "--set", "image.tag="],
        capture_output=True, text=True,
    )  # fmt: skip
    assert result.returncode != 0
    assert "image.digest or image.tag must be set" in result.stderr
