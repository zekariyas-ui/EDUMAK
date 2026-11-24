-- Scratch-environment stand-ins for the Supabase pieces the EDUMAK SQL depends on.
-- NOT a real Supabase project. Includes Supabase-style DEFAULT PRIVILEGES so tests prove
-- that the migrations do not rely on defaults being absent.
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
end $$;
create schema auth; create schema storage;
create table auth.users(id uuid primary key default gen_random_uuid(), email text, raw_user_meta_data jsonb default '{}');
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
create table storage.buckets(id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
create table storage.objects(id uuid primary key default gen_random_uuid(), bucket_id text, name text);
alter table storage.objects enable row level security;
create publication supabase_realtime;
grant usage on schema auth, storage to anon, authenticated;
grant select,insert,update,delete on storage.objects to authenticated; grant select on storage.objects to anon;
-- Supabase gives anon/authenticated broad default privileges on new public objects; RLS and
-- explicit REVOKEs are what actually protect the data.
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant all on sequences to anon, authenticated;
alter default privileges in schema public grant all on functions to anon, authenticated;
