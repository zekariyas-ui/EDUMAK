-- EDUMAK migration 004: tighten trigger-function exposure and pin safe search paths.
-- Trigger functions are invoked by PostgreSQL triggers; application roles do not need EXECUTE.
revoke all on function public.handle_new_edumak_user() from public, anon, authenticated;
revoke all on function public.protect_edumak_role() from public, anon, authenticated;

-- These functions use only built-ins and no public objects; pin their search path.
alter function public.edumak_touch_updated_at() set search_path = pg_catalog;
alter function public.edumak_loan_hours() set search_path = pg_catalog;
alter function public.edumak_due_soon_hours() set search_path = pg_catalog;
alter function public.edumak_audit_immutable() set search_path = pg_catalog;
alter function public.edumak_loans_no_truncate() set search_path = pg_catalog;

insert into public.edumak_schema_migrations(version, notes)
values ('004_security_hardening', 'revoke direct execution of trigger functions and pin search paths')
on conflict (version) do nothing;
