# postgres-resource

PostgreSQL 16 for services that need a `postgres/v1` resource. One Postgres is installed for the whole deployment (or the operator points at a database they already run). Each service that needs a database gets its own database and its own login, with rights only on that database. The administrator login stays with `keystonectl` and is never given to a service.

The package does not publish port `5432`. Consumers reach the server as `postgres-db` on the `keystone-resources` network. It has no MCP facade, so it is not registered with keystone-mcp and does not join `keystone-mcp-upstreams`.

This package does not use the Keystone-MCP directory database. That database belongs to Keystone-MCP itself.

## One database and one user per consumer

For a consumer package named `docs-service`, provisioning creates:

- database `docs_service`
- role `docs_service`, with `LOGIN` only (no superuser, `CREATEDB`, `CREATEROLE`, replication, or `BYPASSRLS`)

The consumer owns the database. On PostgreSQL 15 and newer that ownership is what grants `CREATE` on the `public` schema, so the service can run its own migrations. `PUBLIC` is not allowed to connect to the consumer database, and not to the other databases on the server either, so one service cannot open another's database.

Removing a service does not drop its database or role. `service remove` leaves the data in place.

## Calling `provision.sh`

`keystonectl` runs the script once per consumer, in a one-shot container of the same `postgres:16-alpine` image as the server (so `psql` matches the server). The package directory is mounted at `/pkg`. Administrator credentials are passed as environment variables (`-e NAME` with no `=`). The consumer password is a mode-`600` file, never a command argument.

```bash
docker run --rm --network keystone-resources \
  -e POSTGRES_USER -e POSTGRES_PASSWORD \
  -v <package directory>:/pkg:ro \
  -v <secret directory, mode 700>:/out \
  --entrypoint /bin/sh postgres:16-alpine@sha256:<digest> \
  /pkg/provision.sh --consumer docs-service --secret-file /out/docs-service.secret \
    --host postgres-db --port 5432 --database docs_service --extensions pgcrypto,pg_trgm
```

| Argument | Meaning | Default |
|---|---|---|
| `--consumer` | Consumer package name | required |
| `--host`, `--port` | Provider address on `keystone-resources`; copied into the result | required; `5432` |
| `--database` | Database and role; the package name with `-` replaced by `_` | required |
| `--secret-file` | Where to read or write the consumer password | required |
| `--extensions` | Comma-separated names from the consumer's `needs[].extensions` | empty |
| `--sslmode` | Value stored for the consumer | `disable` |
| `--ready-timeout` | Seconds to wait until the server accepts TCP connections | `60` |

Stdout is one JSON line and nothing else. The password is not in it:

```json
{"interface":"postgres/v1","host":"postgres-db","port":5432,"database":"docs_service","user":"docs_service","sslmode":"disable","password_file":"/out/docs-service.secret","extensions":["pgcrypto","pg_trgm"]}
```

`keystonectl` reads the password from `password_file` and builds `url` from the fields. Exit codes: `0` done, `2` bad arguments or environment, `3` the server is unreachable, the administrator password does not match the volume, or the database belongs to another role.

The consumer password is 32–128 hexadecimal characters (48 when this script generates it), so it does not need escaping in a URL. It is passed to `psql` on stdin. It is never a `psql` argument.

## Both forms of `postgres/v1`

A consumer's `bind_env` may ask for a single `url`, for the separate fields `host`, `port`, `database`, `user`, `password`, and `sslmode`, or for both. This package always returns the fields. `keystonectl` assembles `url` as `postgresql://<user>:<percent-encoded-password>@<host>:<port>/<database>?sslmode=<sslmode>`. Inside the resource network `sslmode` is `disable`.

## Where secrets live

`keystonectl` generates `POSTGRES_PASSWORD` and stores it in `packages/postgres.env` (mode `600`). The consumer password is stored in `packages/<consumer>.env`, or in `packages/<consumer>.postgres.env` when only some of that service's containers need the database.

Do not put these values on a command line, in logs, or in `--json` output.

## Extensions

Extensions listed by the consumer are created in its database by the administrator account. The role itself is not a superuser, and several extensions require one.

PostgreSQL's `contrib` extensions in this image are available, including `pgcrypto`, `uuid-ossp`, `pg_trgm`, `citext`, and `hstore`. **`pgvector` is not in 1.0.0.** An unknown extension fails provisioning.

## Versions and upgrades

The PostgreSQL major version is part of the package major version. Moving from 16 to 17 means dumping and loading the data (`pg_dumpall`). The package does not do that automatically. A 1.x package upgrade only changes the digest of the same major version.

Backups of the volume are the operator's job. For example:

```bash
docker compose exec -T postgres-db pg_dump -U keystone_admin postgres > backup.sql
```

Run that with the administrator password in the environment (`PGPASSWORD`), not on the command line. The dump contains data; keep the file private.

## Administrator password

**The administrator password is set once, on the first start of the data volume.**

After that, the volume remembers it. Changing `POSTGRES_PASSWORD` in `packages/postgres.env` does not change the password inside the volume, and the server will reject the new value. To change it, run `ALTER ROLE` inside the database. Do not edit the env file and expect the server to follow.

## Health check

The server is healthy when `pg_isready -h 127.0.0.1 -p 5432 -U keystone_admin` succeeds. The check uses TCP. During the first initialization the server answers on its Unix socket before it listens on `5432`, so a socket check reports ready too early.

`-U` is `keystone_admin`, the role this package creates (`POSTGRES_USER`). The image's Unix user is `postgres`; this package does not create a database role with that name. If you change `POSTGRES_USER`, change `-U` in the health check to the same name.
