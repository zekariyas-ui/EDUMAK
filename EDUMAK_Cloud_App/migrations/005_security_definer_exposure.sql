-- EDUMAK migration 005: close unnecessary SECURITY DEFINER API exposure.
-- rls_auto_enable is a PostgreSQL event-trigger function, never an application RPC.
revoke all on function public.rls_auto_enable() from public, anon, authenticated;

-- Availability is used by the signed-in app; anonymous callers do not need it.
revoke all on function public.get_book_availability() from public, anon;
grant execute on function public.get_book_availability() to authenticated;

-- These reviewed SECURITY DEFINER functions use schema-qualified objects.
-- Pin resolution to pg_catalog to prevent public-schema object shadowing.
alter function public.get_book_availability() set search_path = pg_catalog;
alter function public.get_library_clock() set search_path = pg_catalog;
alter function public.is_edumak_admin() set search_path = pg_catalog;
alter function public.admin_search_students(text, integer) set search_path = pg_catalog;
alter function public.admin_create_loan(uuid, uuid, text, text, text) set search_path = pg_catalog;
alter function public.admin_return_loan(uuid) set search_path = pg_catalog;
alter function public.admin_correct_loan(uuid, text, text, text, text, text) set search_path = pg_catalog;

insert into public.edumak_schema_migrations(version, notes)
values ('005_security_definer_exposure', 'revoke application execution of event trigger; restrict availability RPC to authenticated; pin reviewed definer search paths')
on conflict (version) do nothing;
