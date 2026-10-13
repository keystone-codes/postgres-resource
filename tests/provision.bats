#!/usr/bin/env bats

# tests/psql and tests/pg_isready are the fakes, so this directory wins on PATH.

setup() {
  REPO="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SCRIPT="${REPO}/provision.sh"
  export PATH="${BATS_TEST_DIRNAME}:${PATH}"
  export FAKE_PKG_ROOT="$REPO"
  export FAKE_PSQL_LOG="${BATS_TEST_TMPDIR}/psql.log"
  export FAKE_PSQL_STDIN="${BATS_TEST_TMPDIR}/psql.stdin"
  export FAKE_PSQL_ENV="${BATS_TEST_TMPDIR}/psql.env"
  export FAKE_PSQL_SCENARIO=ok
  export FAKE_PG_ISREADY_SCENARIO=ok
  export POSTGRES_USER=keystone_admin
  export POSTGRES_PASSWORD='admin-test-password'
  STDOUT="${BATS_TEST_TMPDIR}/stdout"
  STDERR="${BATS_TEST_TMPDIR}/stderr"
  SECRET="${BATS_TEST_TMPDIR}/docs-service.secret"
}

invoke() {
  status=0
  sh "$SCRIPT" "$@" >"$STDOUT" 2>"$STDERR" || status=$?
  stdout=$(cat "$STDOUT")
  stderr=$(cat "$STDERR")
}

base_args() {
  printf '%s\n' \
    --consumer docs-service \
    --secret-file "$SECRET" \
    --host postgres-db \
    --port 5432 \
    --database docs_service
}

assert_absent() {
  haystack=$1
  needle=$2
  if printf '%s' "$haystack" | grep -F -q -- "$needle"; then
    echo "a secret appeared in argv or output" >&2
    exit 1
  fi
}

mode_of() {
  stat -f %OLp "$1" 2>/dev/null || stat -c %a "$1"
}

@test "creates role, database, grants and prints json" {
  # shellcheck disable=SC2046
  invoke $(base_args)
  [ "$status" -eq 0 ]
  [ "$stdout" = "{\"interface\":\"postgres/v1\",\"host\":\"postgres-db\",\"port\":5432,\"database\":\"docs_service\",\"user\":\"docs_service\",\"sslmode\":\"disable\",\"password_file\":\"${SECRET}\",\"extensions\":[]}" ]
  grep -F -q '\ir /pkg/provision.sql' "$FAKE_PSQL_STDIN"
  grep -F -q 'CREATE ROLE' "$FAKE_PSQL_STDIN"
  grep -F -q 'ALTER ROLE' "$FAKE_PSQL_STDIN"
  grep -F -q 'CREATE DATABASE' "$FAKE_PSQL_STDIN"
  grep -F -q 'OWNER' "$FAKE_PSQL_STDIN"
  grep -F -q 'REVOKE ALL ON DATABASE' "$FAKE_PSQL_STDIN"
  grep -F -q 'FROM PUBLIC' "$FAKE_PSQL_STDIN"
  grep -F -q 'GRANT ALL ON DATABASE' "$FAKE_PSQL_STDIN"
}

@test "secrets never appear in argv or output" {
  # shellcheck disable=SC2046
  invoke $(base_args)
  [ "$status" -eq 0 ]
  password=$(head -n 1 "$SECRET")
  combined="${stdout}${stderr}$(cat "$FAKE_PSQL_LOG")"
  assert_absent "$combined" "$POSTGRES_PASSWORD"
  assert_absent "$combined" "$password"
  grep -F -q -- "$password" "$FAKE_PSQL_STDIN"
  awk -v secret="$password" '
    /^---$/ { if (block != "") { blocks[++n] = block } block = ""; next }
    { block = block $0 "\n" }
    END {
      if (block != "") { blocks[++n] = block }
      found = 0
      for (i = 1; i <= n; i++) {
        if (blocks[i] ~ /current_user/ && index(blocks[i], secret) > 0) { found = 1 }
        if (blocks[i] !~ /current_user/ && index(blocks[i], secret) > 0) { exit 2 }
      }
      if (!found) { exit 3 }
    }
  ' "$FAKE_PSQL_ENV"
}

@test "writes password file with mode 600" {
  [ ! -e "$SECRET" ]
  # shellcheck disable=SC2046
  invoke $(base_args)
  [ "$status" -eq 0 ]
  [ "$(mode_of "$SECRET")" = "600" ]
  password=$(head -n 1 "$SECRET")
  printf '%s\n' "$password" | grep -Eq '^[0-9a-f]{48}$'
  case "$stdout" in
    *'"host":"postgres-db"'*'"database":"docs_service"'*) ;;
    *) echo "json missing host or database" >&2; exit 1 ;;
  esac
}

@test "reuses existing secret file" {
  umask 077
  printf '%s\n' '0123456789abcdef0123456789abcdef' >"$SECRET"
  cp "$SECRET" "${SECRET}.bak"
  # shellcheck disable=SC2046
  invoke $(base_args)
  [ "$status" -eq 0 ]
  cmp "$SECRET" "${SECRET}.bak"
  grep -F -q -- '0123456789abcdef0123456789abcdef' "$FAKE_PSQL_STDIN"
}

@test "rejects bad secret file" {
  umask 077
  printf '%s\n' 'p@ss' >"$SECRET"
  # shellcheck disable=SC2046
  invoke $(base_args)
  [ "$status" -eq 2 ]
  assert_absent "${stdout}${stderr}" 'p@ss'
  case "$stderr" in
    *"secret file must hold 32-128 hex characters"*) ;;
    *) echo "missing secret file error" >&2; exit 1 ;;
  esac
}

@test "rejects bad consumer names" {
  long=$(printf '%64s' '' | tr ' ' 'a')
  for name in Docs a -x x-- "$long"; do
    status=0
    sh "$SCRIPT" \
      --consumer "$name" \
      --secret-file "$SECRET" \
      --host postgres-db \
      --port 5432 \
      --database docs_service \
      >"$STDOUT" 2>"$STDERR" || status=$?
    [ "$status" -eq 2 ]
  done
  [ ! -s "$FAKE_PSQL_LOG" ]
}

@test "requires admin credentials in environment" {
  unset POSTGRES_PASSWORD
  # shellcheck disable=SC2046
  invoke $(base_args)
  [ "$status" -eq 2 ]
  case "$stderr" in
    *POSTGRES_PASSWORD*) ;;
    *) echo "missing admin credential error" >&2; exit 1 ;;
  esac
}

@test "fails with 3 when provider is not ready" {
  export FAKE_PG_ISREADY_SCENARIO=not_ready
  status=0
  sh "$SCRIPT" \
    --consumer docs-service \
    --secret-file "$SECRET" \
    --host postgres-db \
    --port 5432 \
    --database docs_service \
    --ready-timeout 2 \
    >"$STDOUT" 2>"$STDERR" || status=$?
  [ "$status" -eq 3 ]
  stderr=$(cat "$STDERR")
  case "$stderr" in
    *"Postgres at postgres-db:5432 is not ready after 2s"*) ;;
    *) echo "missing not ready message" >&2; exit 1 ;;
  esac
}

@test "wrong admin password exits 3 with volume hint" {
  export FAKE_PSQL_SCENARIO=auth_fail
  # shellcheck disable=SC2046
  invoke $(base_args)
  [ "$status" -eq 3 ]
  case "$stderr" in
    *volume*) ;;
    *) echo "missing volume hint" >&2; exit 1 ;;
  esac
  case "$stderr" in
    *POSTGRES_PASSWORD*) ;;
    *) echo "missing password hint" >&2; exit 1 ;;
  esac
  assert_absent "${stdout}${stderr}" "$POSTGRES_PASSWORD"
}

@test "foreign owner exits 3" {
  export FAKE_PSQL_SCENARIO=foreign_owner
  # shellcheck disable=SC2046
  invoke $(base_args)
  [ "$status" -eq 3 ]
  case "$stderr" in
    *"database docs_service exists and is owned by another role"*) ;;
    *) echo "missing foreign owner message" >&2; exit 1 ;;
  esac
  assert_absent "${stdout}${stderr}" "$POSTGRES_PASSWORD"
}

@test "extensions are validated and created" {
  # shellcheck disable=SC2046
  invoke $(base_args) --extensions pgcrypto,pg_trgm
  [ "$status" -eq 0 ]
  [ "$(grep -c -F 'CREATE EXTENSION IF NOT EXISTS' "$FAKE_PSQL_STDIN")" -eq 2 ]
  [ "$(grep -c -F -- '-d docs_service' "$FAKE_PSQL_LOG")" -eq 2 ]
  [ "$stdout" = "{\"interface\":\"postgres/v1\",\"host\":\"postgres-db\",\"port\":5432,\"database\":\"docs_service\",\"user\":\"docs_service\",\"sslmode\":\"disable\",\"password_file\":\"${SECRET}\",\"extensions\":[\"pgcrypto\",\"pg_trgm\"]}" ]

  export FAKE_PSQL_SCENARIO=missing_extension
  : >"$FAKE_PSQL_LOG"
  : >"$FAKE_PSQL_STDIN"
  status=0
  sh "$SCRIPT" \
    --consumer docs-service \
    --secret-file "$SECRET" \
    --host postgres-db \
    --port 5432 \
    --database docs_service \
    --extensions vector \
    >"$STDOUT" 2>"$STDERR" || status=$?
  [ "$status" -eq 2 ]
  stderr=$(cat "$STDERR")
  case "$stderr" in
    *"extension vector is not available in this image"*) ;;
    *) echo "missing extension error" >&2; exit 1 ;;
  esac

  : >"$FAKE_PSQL_LOG"
  status=0
  sh "$SCRIPT" \
    --consumer docs-service \
    --secret-file "$SECRET" \
    --host postgres-db \
    --port 5432 \
    --database docs_service \
    --extensions 'x;drop' \
    >"$STDOUT" 2>"$STDERR" || status=$?
  [ "$status" -eq 2 ]
  [ ! -s "$FAKE_PSQL_LOG" ]
}
