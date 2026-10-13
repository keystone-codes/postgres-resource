-- Session variables: role, db, and pw. provision.sh sets pw from stdin.
-- Names and the password are substituted by psql; this file never sees them
-- as shell words.

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS', :'role', :'pw')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'role') \gexec
SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS', :'role', :'pw') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'role')
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db') \gexec
-- Refuse to adopt a database owned by somebody else.
-- count(*) is 0 when the owner matches, so the division is 1/1.
-- A foreign owner makes it 1/0. A constant 1/0 is planned even when no row matches.
SELECT 1 / (1 - count(*))::int
FROM pg_database d
JOIN pg_roles r ON r.oid = d.datdba
WHERE d.datname = :'db' AND r.rolname <> :'role';
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'db') \gexec
SELECT format('GRANT ALL ON DATABASE %I TO %I', :'db', :'role') \gexec
-- PUBLIC can CONNECT to every other database, including postgres, until
-- this is revoked. The consumer must not reach those databases.
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', datname)
FROM pg_database
WHERE datallowconn AND datname <> :'db' \gexec
