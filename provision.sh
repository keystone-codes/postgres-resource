#!/bin/sh
# Provision one database and one login for a postgres/v1 consumer.
# Secrets are read from the environment (admin) or a mode-600 file (consumer)
# and are handed to psql only through PGPASSWORD or stdin.
set -eu
set -f

fail2() {
  printf '%s\n' "$1" >&2
  exit 2
}

fail3() {
  printf '%s\n' "$1" >&2
  exit 3
}

step() {
  printf '%s\n' "$1" >&2
}

matches() {
  printf '%s\n' "$1" | grep -Eq -- "$2"
}

show_psql_err() {
  if [ ! -s "$PS_ERR" ]; then
    return 0
  fi
  if [ -n "${password:-}" ]; then
    grep -v -F -e "$password" -e "$POSTGRES_PASSWORD" "$PS_ERR" >&2 || true
  else
    grep -v -F -e "$POSTGRES_PASSWORD" "$PS_ERR" >&2 || true
  fi
}

clear_psql_tmp() {
  if [ -n "${PS_OUT:-}" ]; then
    rm -f "$PS_OUT"
  fi
  if [ -n "${PS_ERR:-}" ]; then
    rm -f "$PS_ERR"
  fi
  PS_OUT=
  PS_ERR=
}

PS_OUT=
PS_ERR=
trap clear_psql_tmp EXIT

run_psql() {
  clear_psql_tmp
  PS_OUT=$(mktemp)
  PS_ERR=$(mktemp)
  set +e
  psql "$@" >"$PS_OUT" 2>"$PS_ERR"
  PS_STATUS=$?
  set -e
}

file_mode() {
  if stat -c %a "$1" >/dev/null 2>&1; then
    stat -c %a "$1"
  else
    stat -f %OLp "$1"
  fi
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

consumer=
host=
port=5432
database=
secret_file=
extensions=
sslmode=disable
ready_timeout=60

while [ "$#" -gt 0 ]; do
  case "$1" in
    --consumer|--host|--port|--database|--secret-file|--sslmode|--ready-timeout)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        fail2 "missing value for $1"
      fi
      case "$1" in
        --consumer) consumer=$2 ;;
        --host) host=$2 ;;
        --port) port=$2 ;;
        --database) database=$2 ;;
        --secret-file) secret_file=$2 ;;
        --sslmode) sslmode=$2 ;;
        --ready-timeout) ready_timeout=$2 ;;
      esac
      shift 2
      ;;
    --extensions)
      if [ "$#" -lt 2 ]; then
        fail2 "missing value for --extensions"
      fi
      extensions=$2
      shift 2
      ;;
    *)
      fail2 "unknown argument"
      ;;
  esac
done

if [ -z "$consumer" ] || [ -z "$host" ] || [ -z "$database" ] || [ -z "$secret_file" ]; then
  fail2 "consumer, host, database, and secret-file are required"
fi

if ! matches "$consumer" '^[a-z][a-z0-9-]{0,61}[a-z0-9]$'; then
  fail2 "invalid consumer name"
fi

expected_db=$(printf '%s\n' "$consumer" | tr '-' '_')
if [ "$database" != "$expected_db" ] || ! matches "$database" '^[a-z_][a-z0-9_]{0,62}$'; then
  fail2 "database must equal the consumer name with '-' replaced by '_'"
fi

if ! matches "$port" '^[0-9]{1,5}$'; then
  fail2 "invalid port"
fi
port_num=$port
if [ "$port_num" -lt 1 ] || [ "$port_num" -gt 65535 ]; then
  fail2 "invalid port"
fi

if ! matches "$ready_timeout" '^[0-9]{1,5}$' || [ "$ready_timeout" -lt 1 ]; then
  fail2 "invalid ready-timeout"
fi

case "$sslmode" in
  disable|allow|prefer|require|verify-ca|verify-full) ;;
  *) fail2 "invalid sslmode" ;;
esac

if [ -n "$extensions" ]; then
  old_ifs=$IFS
  IFS=','
  # shellcheck disable=SC2086
  set -- $extensions
  IFS=$old_ifs
  for ext do
    if ! matches "$ext" '^[a-z0-9_]+$'; then
      fail2 "invalid extension name"
    fi
  done
fi

if [ -z "${POSTGRES_USER-}" ] || [ -z "${POSTGRES_PASSWORD-}" ]; then
  fail2 "POSTGRES_USER and POSTGRES_PASSWORD must be set"
fi

if ! command -v psql >/dev/null 2>&1 || ! command -v pg_isready >/dev/null 2>&1; then
  fail3 "psql and pg_isready are required"
fi

export PGHOST="$host" PGPORT="$port" PGUSER="$POSTGRES_USER"
export PGPASSWORD="$POSTGRES_PASSWORD" PGDATABASE=postgres PGCONNECT_TIMEOUT=5

step "waiting for ${host}:${port}"
elapsed=0
while [ "$elapsed" -lt "$ready_timeout" ]; do
  if pg_isready -h "$host" -p "$port" -t 1 >/dev/null 2>&1; then
    break
  fi
  elapsed=$((elapsed + 1))
  if [ "$elapsed" -ge "$ready_timeout" ]; then
    fail3 "Postgres at ${host}:${port} is not ready after ${ready_timeout}s"
  fi
  sleep 1
done

step "checking admin login"
run_psql -Atc 'select 1'
if [ "$PS_STATUS" -ne 0 ]; then
  if grep -q 'password authentication failed' "$PS_ERR"; then
    fail3 "admin password does not match the password stored in the data volume; do not change POSTGRES_PASSWORD after the first start"
  fi
  show_psql_err
  fail3 "admin login failed"
fi

secret_dir=$(dirname "$secret_file")
if [ ! -d "$secret_dir" ]; then
  fail2 "secret file directory does not exist"
fi

password=
if [ -s "$secret_file" ]; then
  mode=$(file_mode "$secret_file")
  case "$mode" in
    600|0600) ;;
    *) fail2 "secret file must be mode 600" ;;
  esac
  IFS= read -r password <"$secret_file" || true
  if ! matches "$password" '^[0-9a-f]{32,128}$'; then
    fail2 "secret file must hold 32-128 hex characters"
  fi
else
  if ! command -v od >/dev/null 2>&1 || ! command -v tr >/dev/null 2>&1; then
    fail2 "pass a pre-generated secret file"
  fi
  password=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
  if ! matches "$password" '^[0-9a-f]{48}$'; then
    fail2 "pass a pre-generated secret file"
  fi
  umask 077
  printf '%s\n' "$password" >"$secret_file"
  chmod 600 "$secret_file"
fi

step "creating role and database ${database}"
run_psql -v ON_ERROR_STOP=1 -X -q -v role="$database" -v db="$database" <<EOF
\\set pw '${password}'
\\ir /pkg/provision.sql
EOF
if [ "$PS_STATUS" -ne 0 ]; then
  if grep -q 'division by zero' "$PS_ERR"; then
    fail3 "database ${database} exists and is owned by another role"
  fi
  show_psql_err
  fail3 "psql failed while creating the role and database"
fi

if [ -n "$extensions" ]; then
  old_ifs=$IFS
  IFS=','
  # shellcheck disable=SC2086
  set -- $extensions
  IFS=$old_ifs
  for ext do
    step "checking extension ${ext}"
    # psql does not interpolate :'var' inside -c, so the query is stdin.
    run_psql -v ON_ERROR_STOP=1 -X -At -v ext="$ext" <<EOF
SELECT 1 FROM pg_available_extensions WHERE name = :'ext'
EOF
    if [ "$PS_STATUS" -ne 0 ]; then
      show_psql_err
      fail3 "psql failed while checking extension ${ext}"
    fi
    found=$(cat "$PS_OUT")
    if [ "$found" != "1" ]; then
      fail2 "extension ${ext} is not available in this image"
    fi
    step "creating extension ${ext}"
    run_psql -v ON_ERROR_STOP=1 -X -q -d "$database" -v ext="$ext" <<EOF
SELECT format('CREATE EXTENSION IF NOT EXISTS %I', :'ext') \\gexec
EOF
    if [ "$PS_STATUS" -ne 0 ]; then
      show_psql_err
      fail3 "psql failed while creating extension ${ext}"
    fi
  done
fi

step "checking consumer login"
set +e
got=$(PGUSER="$database" PGPASSWORD="$password" PGDATABASE="$database" psql -Atc "select current_user, current_database(), has_schema_privilege('public','CREATE')" 2>"$PS_ERR")
PS_STATUS=$?
set -e
if [ "$PS_STATUS" -ne 0 ] || [ "$got" != "${database}|${database}|t" ]; then
  show_psql_err
  fail3 "consumer login check failed"
fi

ext_json='['
if [ -n "$extensions" ]; then
  first=1
  old_ifs=$IFS
  IFS=','
  # shellcheck disable=SC2086
  set -- $extensions
  IFS=$old_ifs
  for ext do
    if [ "$first" -eq 0 ]; then
      ext_json="${ext_json},"
    fi
    first=0
    ext_json="${ext_json}\"$(json_escape "$ext")\""
  done
fi
ext_json="${ext_json}]"

printf '{"interface":"postgres/v1","host":"%s","port":%s,"database":"%s","user":"%s","sslmode":"%s","password_file":"%s","extensions":%s}\n' \
  "$(json_escape "$host")" \
  "$port" \
  "$(json_escape "$database")" \
  "$(json_escape "$database")" \
  "$(json_escape "$sslmode")" \
  "$(json_escape "$secret_file")" \
  "$ext_json"
