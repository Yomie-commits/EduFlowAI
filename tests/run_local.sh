#!/usr/bin/env bash
# Rebuilds a throwaway local database, applies all migrations + seed, runs the security tests.
# Needs PostgreSQL 15+ running locally. Usage: PGHOST=/tmp/pg PGPORT=5499 PGUSER=postgres tests/run_local.sh
set -euo pipefail
cd "$(dirname "$0")/.."
P="psql -v ON_ERROR_STOP=1 -q"
$P -d postgres -c "drop database if exists eduflow_test" -c "create database eduflow_test" >/dev/null
$P -d eduflow_test -f tests/supabase_mock.sql >/dev/null
$P -d eduflow_test -c "insert into auth.users(email) values ('admin@mwangaza.demo'),('head@mwangaza.demo'),('bursar@mwangaza.demo'),('admissions@mwangaza.demo'),('teacher@mwangaza.demo'),('admin@baraka.demo')" >/dev/null
for f in supabase/migrations/00[1-3]*.sql tests/fixtures/test_seed.sql supabase/migrations/004_automation.sql; do
  $P -d eduflow_test -f "$f" >/dev/null 2>&1 || { echo "FAILED applying $f"; $P -d eduflow_test -f "$f"; exit 1; }
done
{ psql -q -d eduflow_test -f tests/security_tests.sql; psql -q -d eduflow_test -f tests/automation_tests.sql; } 2>&1 | sed 's/^psql:[^ ]* NOTICE:  //; s/^NOTICE:  //' | tee /tmp/eduflow_test_results.txt
echo "----"
echo "PASS: $(grep -c '^PASS' /tmp/eduflow_test_results.txt)   FAIL: $(grep -c '^FAIL' /tmp/eduflow_test_results.txt || true)"
