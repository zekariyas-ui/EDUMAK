-- EDUMAK migration 006: least-privilege Data API table grants.
-- RLS remains the row-level authorization layer; SQL grants now expose only
-- the operations the current application actually uses.

revoke all on table public.profiles from anon, authenticated;
grant select on table public.profiles to authenticated;
grant update (display_name) on table public.profiles to authenticated;

revoke all on table public.books from anon, authenticated;
grant select on table public.books to anon, authenticated;
grant insert, update, delete on table public.books to authenticated;

revoke all on table public.loans from anon, authenticated;
grant select on table public.loans to authenticated;

revoke all on table public.pdf_documents from anon, authenticated;
grant select, insert on table public.pdf_documents to authenticated;

revoke all on table public.dataset_documents from anon, authenticated;
grant select, insert on table public.dataset_documents to authenticated;

revoke all on table public.loan_corrections from anon, authenticated;
grant select on table public.loan_corrections to authenticated;

-- Internal migration ledger is never an application-facing API table.
revoke all on table public.edumak_schema_migrations from anon, authenticated;

insert into public.edumak_schema_migrations(version, notes)
values ('006_least_privilege_table_grants', 'restrict Data API table privileges to current app operations while retaining RLS')
on conflict (version) do nothing;
