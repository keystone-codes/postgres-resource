"""Docker checks for provision.sh. Secrets stay in mode-600 files and the process environment."""

from __future__ import annotations

import json
import os
import re
import secrets
import shutil
import stat
import subprocess
import tempfile
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import quote

import psycopg
import pytest

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "keystone-service.yaml"

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(shutil.which("docker") is None, reason="docker is not available"),
]


@dataclass
class ManifestBits:
    image: str
    user: str
    health: list[str]
    interval: str
    start_period: str


@dataclass
class Server:
    image: str
    user: str
    network: str
    name: str
    port: int
    out: Path
    env_file: Path
    admin_password: str = field(repr=False)
    child_env: dict[str, str] = field(repr=False)


@dataclass
class Provisioned:
    payload: dict[str, object]
    password: str
    stdout: str
    stderr: str


def _redact(text: str, *hidden: str) -> str:
    for secret in hidden:
        if secret:
            text = text.replace(secret, "***")
    return text


def _absent(blob: str, secret: str) -> None:
    if secret and secret in blob:
        raise AssertionError("a secret appeared in process arguments or output")


def load_manifest() -> ManifestBits:
    text = MANIFEST.read_text(encoding="utf-8")
    images = re.findall(r"image:\s*(postgres:16-alpine@sha256:[0-9a-f]{64})", text)
    if len(images) != 2 or images[0] != images[1]:
        raise AssertionError("containers and provision must pin one postgres:16-alpine digest")
    image = images[0]
    if image.startswith("postgres:16@") or ":latest" in image or image.endswith(":latest"):
        raise AssertionError("image must be postgres:16-alpine pinned by digest")
    user_match = re.search(r"name: POSTGRES_USER\n\s+default: (\S+)", text)
    health_match = re.search(
        r"command: \[pg_isready, -h, 127\.0\.0\.1, -p, \"5432\", -U, (\S+)\]",
        text,
    )
    interval_match = re.search(r"interval: (\d+s)", text)
    start_match = re.search(r"start_period: (\d+s)", text)
    if not user_match or not health_match or not interval_match or not start_match:
        raise AssertionError("manifest is missing the admin user or the TCP health check")
    user = user_match.group(1)
    health_user = health_match.group(1)
    if health_user != user:
        raise AssertionError("health check user must be the role the package creates")
    if user == "postgres":
        raise AssertionError("health check must not assume the image's default postgres role")
    health = ["pg_isready", "-h", "127.0.0.1", "-p", "5432", "-U", user]
    return ManifestBits(image, user, health, interval_match.group(1), start_match.group(1))


def _run(
    args: list[str],
    *,
    env: dict[str, str] | None = None,
    hidden: tuple[str, ...] = (),
) -> subprocess.CompletedProcess[str]:
    for secret in hidden:
        _absent(" ".join(args), secret)
    result = subprocess.run(args, env=env, text=True, capture_output=True)
    blob = result.stdout + result.stderr
    for secret in hidden:
        _absent(blob, secret)
    return result


def _write_env(path: Path, lines: str) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, lines.encode("utf-8"))
    finally:
        os.close(fd)
    os.chmod(path, 0o600)
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode != 0o600:
        raise AssertionError("admin env file must be mode 600")


def _wait_healthy(name: str, secret: str, timeout: float = 90) -> None:
    deadline = time.monotonic() + timeout
    last = "missing"
    while time.monotonic() < deadline:
        result = subprocess.run(
            ["docker", "inspect", "-f", "{{.State.Health.Status}}", name],
            text=True,
            capture_output=True,
        )
        last = (result.stdout or result.stderr).strip()
        if last == "healthy":
            return
        time.sleep(1)
    logs = subprocess.run(["docker", "logs", name], text=True, capture_output=True)
    detail = _redact(logs.stdout + logs.stderr, secret)
    raise AssertionError(f"container did not become healthy ({last}): {detail[-2000:]}")


def _published_port(name: str) -> int:
    result = subprocess.run(
        ["docker", "port", name, "5432"],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0 or not result.stdout.strip():
        raise AssertionError("postgres port was not published for the host-side probe")
    return int(result.stdout.strip().splitlines()[0].rsplit(":", 1)[1])


@pytest.fixture(scope="module")
def server() -> Server:
    bits = load_manifest()
    suffix = uuid.uuid4().hex[:8]
    network = f"ks-pkg-p04-{suffix}"
    volume = f"ks-pkg-p04-data-{suffix}"
    name = f"ks-pkg-p04-db-{suffix}"
    admin_password = secrets.token_hex(24)
    tmp = Path(tempfile.mkdtemp(prefix=f"ks-pkg-p04-{suffix}-"))
    os.chmod(tmp, 0o700)
    out = tmp / "out"
    out.mkdir(mode=0o700)
    os.chmod(out, 0o700)
    env_file = tmp / "admin.env"
    _write_env(
        env_file,
        (
            f"POSTGRES_USER={bits.user}\n"
            f"POSTGRES_PASSWORD={admin_password}\n"
            "POSTGRES_DB=postgres\n"
            f"PGPASSWORD={admin_password}\n"
        ),
    )
    child_env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": os.environ.get("HOME", ""),
        "POSTGRES_USER": bits.user,
        "POSTGRES_PASSWORD": admin_password,
    }
    created = {"network": False, "volume": False, "container": False}
    try:
        network_result = _run(["docker", "network", "create", network], hidden=(admin_password,))
        if network_result.returncode != 0:
            raise AssertionError(_redact(network_result.stderr, admin_password))
        created["network"] = True
        volume_result = _run(["docker", "volume", "create", volume], hidden=(admin_password,))
        if volume_result.returncode != 0:
            raise AssertionError(_redact(volume_result.stderr, admin_password))
        created["volume"] = True
        health_cmd = " ".join(bits.health)
        start = _run(
            [
                "docker",
                "run",
                "-d",
                "--name",
                name,
                "--network",
                network,
                "--env-file",
                str(env_file),
                "-v",
                f"{volume}:/var/lib/postgresql/data",
                "-p",
                "127.0.0.1::5432",
                "--health-cmd",
                health_cmd,
                "--health-interval",
                bits.interval,
                "--health-timeout",
                "5s",
                "--health-start-period",
                bits.start_period,
                "--health-retries",
                "5",
                bits.image,
            ],
            hidden=(admin_password,),
        )
        if start.returncode != 0:
            raise AssertionError(_redact(start.stderr, admin_password))
        created["container"] = True
        _wait_healthy(name, admin_password)
        yield Server(
            image=bits.image,
            user=bits.user,
            admin_password=admin_password,
            network=network,
            name=name,
            port=_published_port(name),
            out=out,
            env_file=env_file,
            child_env=child_env,
        )
    finally:
        if created["container"]:
            subprocess.run(["docker", "rm", "-f", name], capture_output=True)
        if created["volume"]:
            subprocess.run(["docker", "volume", "rm", volume], capture_output=True)
        if created["network"]:
            subprocess.run(["docker", "network", "rm", network], capture_output=True)
        shutil.rmtree(tmp, ignore_errors=True)


def build_url(host: str, port: int, database: str, user: str, password: str, sslmode: str) -> str:
    """Same shape keystonectl builds: quote(password, safe='')."""
    return (
        f"postgresql://{quote(user, safe='')}:{quote(password, safe='')}"
        f"@{host}:{port}/{database}?sslmode={sslmode}"
    )


def run_provision(server: Server, consumer: str, extensions: str = "") -> Provisioned:
    database = consumer.replace("-", "_")
    command = [
        "docker",
        "run",
        "--rm",
        # The image's postgres user would own the mode-600 file, which the operator cannot read.
        "--user",
        f"{os.getuid()}:{os.getgid()}",
        "--network",
        server.network,
        "-e",
        "POSTGRES_USER",
        "-e",
        "POSTGRES_PASSWORD",
        "-v",
        f"{ROOT}:/pkg:ro",
        "-v",
        f"{server.out}:/out",
        "--entrypoint",
        "/bin/sh",
        server.image,
        "/pkg/provision.sh",
        "--consumer",
        consumer,
        "--secret-file",
        f"/out/{consumer}.secret",
        "--host",
        server.name,
        "--port",
        "5432",
        "--database",
        database,
        "--extensions",
        extensions,
    ]
    result = _run(command, env=server.child_env, hidden=(server.admin_password,))
    secret_path = server.out / f"{consumer}.secret"
    password = (
        secret_path.read_text(encoding="utf-8").splitlines()[0] if secret_path.is_file() else ""
    )
    _absent(result.stdout + result.stderr, password)
    _absent(" ".join(command), password)
    if result.returncode != 0:
        detail = _redact(result.stderr, server.admin_password, password)
        raise AssertionError(f"provision exited {result.returncode}: {detail}")
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    if len(lines) != 1:
        raise AssertionError("provision stdout was not a single JSON line")
    payload = json.loads(lines[0])
    for key in (
        "interface",
        "host",
        "port",
        "database",
        "user",
        "sslmode",
        "password_file",
        "extensions",
    ):
        if key not in payload:
            raise AssertionError(f"provision JSON is missing {key}")
    return Provisioned(payload, password, result.stdout, result.stderr)


def connect(server: Server, *, user: str, password: str, database: str) -> psycopg.Connection:
    return psycopg.connect(
        host="127.0.0.1",
        port=server.port,
        user=user,
        password=password,
        dbname=database,
        sslmode="disable",
        connect_timeout=10,
    )


def test_two_consumers_are_isolated(server: Server) -> None:
    first = run_provision(server, "iso-a")
    second = run_provision(server, "iso-b")
    assert first.payload["database"] == "iso_a"
    assert first.payload["user"] == "iso_a"
    assert second.payload["database"] == "iso_b"
    secret_mode = stat.S_IMODE((server.out / "iso-a.secret").stat().st_mode)
    if secret_mode != 0o600:
        raise AssertionError("consumer secret file must be mode 600")
    with connect(server, user="iso_a", password=first.password, database="iso_a") as conn:
        conn.execute("CREATE TABLE marker (id int)")
        conn.commit()
    try:
        connect(server, user="iso_a", password=first.password, database="iso_b")
    except psycopg.Error as exc:
        if "permission denied" not in _redact(str(exc), first.password).lower():
            raise AssertionError("expected permission denied for the other database") from None
    else:
        raise AssertionError("iso_a connected to iso_b")
    try:
        connect(server, user="iso_a", password=first.password, database="postgres")
    except psycopg.Error as exc:
        if "permission denied" not in _redact(str(exc), first.password).lower():
            raise AssertionError("expected permission denied for the postgres database") from None
    else:
        raise AssertionError("iso_a connected to the postgres database")
    with connect(server, user="iso_a", password=first.password, database="iso_a") as conn:
        conn.autocommit = True
        try:
            conn.execute("CREATE DATABASE should_fail")
        except psycopg.Error as exc:
            if "permission denied" not in _redact(str(exc), first.password).lower():
                raise AssertionError("expected permission denied for CREATE DATABASE") from None
        else:
            raise AssertionError("iso_a created a database")


def test_rerun_is_idempotent(server: Server) -> None:
    first = run_provision(server, "rerun-svc")
    with connect(server, user="rerun_svc", password=first.password, database="rerun_svc") as conn:
        conn.execute("CREATE TABLE rerun_marker (id int)")
        conn.execute("INSERT INTO rerun_marker VALUES (7)")
        conn.commit()
    second = run_provision(server, "rerun-svc")
    assert second.payload == first.payload
    assert second.password == first.password
    with connect(server, user="rerun_svc", password=first.password, database="rerun_svc") as conn:
        row = conn.execute("SELECT id FROM rerun_marker").fetchone()
        assert row is not None
        assert row[0] == 7


def test_url_and_fields_forms_both_connect(server: Server) -> None:
    got = run_provision(server, "url-svc")
    payload = got.payload
    canonical = build_url(
        str(payload["host"]),
        int(payload["port"]),
        str(payload["database"]),
        str(payload["user"]),
        got.password,
        str(payload["sslmode"]),
    )
    # Docker Desktop does not route the container IP. The URL keystonectl stores
    # uses the network hostname; the host-side probe uses the published port.
    reachable = build_url(
        "127.0.0.1",
        server.port,
        str(payload["database"]),
        str(payload["user"]),
        got.password,
        str(payload["sslmode"]),
    )
    assert canonical == build_url(
        server.name,
        5432,
        "url_svc",
        "url_svc",
        got.password,
        "disable",
    )
    with psycopg.connect(reachable, connect_timeout=10) as conn:
        assert conn.execute("SELECT 1").fetchone() == (1,)
    with connect(
        server,
        user=str(payload["user"]),
        password=got.password,
        database=str(payload["database"]),
    ) as conn:
        assert conn.execute("SELECT current_user").fetchone() == ("url_svc",)


def test_extensions_created(server: Server) -> None:
    got = run_provision(server, "ext-svc", extensions="pgcrypto")
    assert got.payload["extensions"] == ["pgcrypto"]
    with connect(server, user="ext_svc", password=got.password, database="ext_svc") as conn:
        generated = conn.execute("SELECT gen_random_uuid()").fetchone()
        assert generated is not None
        assert generated[0]
        installed = conn.execute(
            "SELECT extname FROM pg_extension WHERE extname = 'pgcrypto'"
        ).fetchone()
        assert installed == ("pgcrypto",)


def test_wrong_admin_password_exits_3(server: Server) -> None:
    bad = secrets.token_hex(24)
    env = dict(server.child_env)
    env["POSTGRES_PASSWORD"] = bad
    command = [
        "docker",
        "run",
        "--rm",
        "--user",
        f"{os.getuid()}:{os.getgid()}",
        "--network",
        server.network,
        "-e",
        "POSTGRES_USER",
        "-e",
        "POSTGRES_PASSWORD",
        "-v",
        f"{ROOT}:/pkg:ro",
        "-v",
        f"{server.out}:/out",
        "--entrypoint",
        "/bin/sh",
        server.image,
        "/pkg/provision.sh",
        "--consumer",
        "bad-admin",
        "--secret-file",
        "/out/bad-admin.secret",
        "--host",
        server.name,
        "--port",
        "5432",
        "--database",
        "bad_admin",
        "--extensions",
        "",
    ]
    result = _run(command, env=env, hidden=(server.admin_password, bad))
    assert result.returncode == 3
    if "volume" not in result.stderr:
        raise AssertionError("missing volume hint for a wrong admin password")


def test_secret_not_in_container_logs(server: Server) -> None:
    got = run_provision(server, "log-svc")
    _absent(got.stdout + got.stderr, server.admin_password)
    _absent(got.stdout + got.stderr, got.password)
    assert got.payload["interface"] == "postgres/v1"


def test_healthcheck_waits_for_init() -> None:
    bits = load_manifest()
    suffix = uuid.uuid4().hex[:8]
    network = f"ks-pkg-p04-hc-{suffix}"
    volume = f"ks-pkg-p04-hcdata-{suffix}"
    name = f"ks-pkg-p04-hcdb-{suffix}"
    admin_password = secrets.token_hex(24)
    tmp = Path(tempfile.mkdtemp(prefix=f"ks-pkg-p04-hc-{suffix}-"))
    os.chmod(tmp, 0o700)
    env_file = tmp / "admin.env"
    _write_env(
        env_file,
        (
            f"POSTGRES_USER={bits.user}\n"
            f"POSTGRES_PASSWORD={admin_password}\n"
            "POSTGRES_DB=postgres\n"
            f"PGPASSWORD={admin_password}\n"
        ),
    )
    created = {"network": False, "volume": False, "container": False}
    try:
        if _run(["docker", "network", "create", network]).returncode != 0:
            raise AssertionError("could not create the healthcheck network")
        created["network"] = True
        if _run(["docker", "volume", "create", volume]).returncode != 0:
            raise AssertionError("could not create the healthcheck volume")
        created["volume"] = True
        start = _run(
            [
                "docker",
                "run",
                "-d",
                "--name",
                name,
                "--network",
                network,
                "--env-file",
                str(env_file),
                "-v",
                f"{volume}:/var/lib/postgresql/data",
                "--health-cmd",
                " ".join(bits.health),
                "--health-interval",
                bits.interval,
                "--health-timeout",
                "5s",
                "--health-start-period",
                bits.start_period,
                "--health-retries",
                "5",
                bits.image,
            ],
            hidden=(admin_password,),
        )
        if start.returncode != 0:
            raise AssertionError(_redact(start.stderr, admin_password))
        created["container"] = True
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            status = subprocess.run(
                ["docker", "inspect", "-f", "{{.State.Health.Status}}", name],
                text=True,
                capture_output=True,
            )
            if status.stdout.strip() != "healthy":
                time.sleep(1)
                continue
            ready = _run(
                [
                    "docker",
                    "run",
                    "--rm",
                    "--network",
                    network,
                    "--entrypoint",
                    "pg_isready",
                    bits.image,
                    "-h",
                    name,
                    "-p",
                    "5432",
                    "-U",
                    bits.user,
                    "-t",
                    "2",
                ]
            )
            if ready.returncode != 0:
                raise AssertionError("container became healthy before TCP accepted connections")
            checked = _run(
                [
                    "docker",
                    "run",
                    "--rm",
                    "--network",
                    network,
                    "--env-file",
                    str(env_file),
                    "--entrypoint",
                    "psql",
                    bits.image,
                    "-h",
                    name,
                    "-p",
                    "5432",
                    "-U",
                    bits.user,
                    "-d",
                    "postgres",
                    "-Atc",
                    "select 1",
                ],
                hidden=(admin_password,),
            )
            if checked.returncode != 0 or checked.stdout.strip() != "1":
                raise AssertionError(
                    "psql -h failed immediately after the container became healthy: "
                    + _redact(checked.stderr, admin_password)
                )
            return
        raise AssertionError("timed out waiting for a TCP health check on a fresh volume")
    finally:
        if created["container"]:
            subprocess.run(["docker", "rm", "-f", name], capture_output=True)
        if created["volume"]:
            subprocess.run(["docker", "volume", "rm", volume], capture_output=True)
        if created["network"]:
            subprocess.run(["docker", "network", "rm", network], capture_output=True)
        shutil.rmtree(tmp, ignore_errors=True)
