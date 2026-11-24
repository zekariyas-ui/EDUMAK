#!/usr/bin/env bash
# EDUMAK SQL tests on a SCRATCH PostgreSQL (not a real Supabase project).
# Needs a PostgreSQL superuser connection through the usual PG* environment variables, e.g.
#   PGHOST=/tmp PGPORT=5544 PGUSER=postgres bash tests/run_sql_tests.sh
# It creates and drops the databases edumak_t_main and edumak_t_legacy.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/EDUMAK_Cloud_App"; T="$ROOT/tests/sql"
PSQL=(psql -X -q -v ON_ERROR_STOP=0)
FAILS=0
say() { printf '\n== %s\n' "$*"; }
newdb() { dropdb --if-exists "$1" >/dev/null 2>&1; createdb "$1" || exit 2
  "${PSQL[@]}" -d "$1" -f "$T/00_stub_supabase.sql" 2>&1 | grep -E 'ERROR' && FAILS=$((FAILS+1)); }
apply() { # db file [expect-warning-pattern]
  local err; err=$("${PSQL[@]}" -d "$1" -f "$2" 2>&1 >/dev/null)
  if grep -q 'ERROR' <<<"$err"; then echo "  ERROR applying $(basename "$2"):"; grep 'ERROR' <<<"$err" | sed 's/^/    /'; FAILS=$((FAILS+1));
  else echo "  applied $(basename "$2") without errors"; fi
  grep -E 'WARNING' <<<"$err" | sed 's/^/    warning: /'; }
suite() { local out; out=$("${PSQL[@]}" -A -t -d "$1" -f "$2" 2>&1); echo "$out" | sed 's/^/  /'
  grep -q 'ERROR' <<<"$out" && FAILS=$((FAILS+1))
  grep -E 'FAIL +[1-9]|\|FAIL\|' <<<"$out" >/dev/null && FAILS=$((FAILS+1)); }

say "1. New install: database_setup.sql -> 001 -> 002, then the full suite"
newdb edumak_t_main
apply edumak_t_main "$APP/database_setup.sql"
apply edumak_t_main "$APP/migrations/001_datasets.sql"
apply edumak_t_main "$APP/migrations/002_librarian_loans_and_integrity.sql"
apply edumak_t_main "$APP/migrations/003_loan_history_protection.sql"
suite edumak_t_main "$T/01_suite_librarian_loans.sql"

say "2. Concurrency (two real sessions)"
bash "$T/06_concurrency.sh" edumak_t_main || FAILS=$((FAILS+1))

say "2b. Loan history protection and audited corrections"
suite edumak_t_main "$T/07_history_protection.sql"

say "3. Re-running every script (baseline, 001, 002, 003) is safe and keeps the lockdown"
"${PSQL[@]}" -d edumak_t_main -c "create table t.rerun_snap as select id, md5(concat_ws('|',book_id,student_id,book_title,book_author,book_identifier,book_source,borrowed_at,due_at,created_by,returned_at,returned_by)) h from public.loans" >/dev/null
"${PSQL[@]}" -d edumak_t_main -c "create table t.rerun_corr as select id, md5(c::text) h from public.loan_corrections c" >/dev/null
apply edumak_t_main "$APP/database_setup.sql"
apply edumak_t_main "$APP/migrations/001_datasets.sql"
apply edumak_t_main "$APP/migrations/002_librarian_loans_and_integrity.sql"
apply edumak_t_main "$APP/migrations/003_loan_history_protection.sql"
suite edumak_t_main "$T/02_post_rerun_checks.sql"

say "4. Upgrade from the FINAL database with legacy loans (duplicate, overdue, over-lent)"
TMP=$(mktemp -d); unzip -o -q "$ROOT/EDUMAK_Cloud_App_FINAL.zip" -d "$TMP"
newdb edumak_t_legacy
apply edumak_t_legacy "$TMP/EDUMAK_Cloud_App/database_setup.sql"
"${PSQL[@]}" -d edumak_t_legacy -f "$T/03_legacy_upgrade.sql" 2>&1 | grep ERROR && FAILS=$((FAILS+1))
echo "  read-only preflight output (before migration):"
"${PSQL[@]}" -A -t -d edumak_t_legacy -f "$APP/migrations/preflight_002_readonly.sql" 2>&1 | sed 's/^/    /'
apply edumak_t_legacy "$APP/migrations/001_datasets.sql"
apply edumak_t_legacy "$APP/migrations/002_librarian_loans_and_integrity.sql"
apply edumak_t_legacy "$APP/migrations/003_loan_history_protection.sql"
suite edumak_t_legacy "$T/04_legacy_checks.sql"
apply edumak_t_legacy "$APP/migrations/002_librarian_loans_and_integrity.sql"
apply edumak_t_legacy "$APP/migrations/003_loan_history_protection.sql"
suite edumak_t_legacy "$T/05_legacy_rerun_checks.sql"
rm -rf "$TMP"

say "RESULT"
if [ "$FAILS" -eq 0 ]; then echo "  ALL SQL TESTS PASSED"; exit 0; else echo "  SQL TESTS FAILED ($FAILS problem group(s))"; exit 1; fi
