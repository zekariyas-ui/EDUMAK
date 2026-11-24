-- EDUMAK migration 007: preserve guest catalogue availability.
-- The app intentionally shows public book availability before login. This RPC
-- returns only per-book aggregate counts, never student identities or loan rows.
grant execute on function public.get_book_availability() to anon, authenticated;

insert into public.edumak_schema_migrations(version, notes)
values ('007_public_catalogue_availability', 'allow anonymous access to the aggregate-only catalogue availability RPC')
on conflict (version) do nothing;
