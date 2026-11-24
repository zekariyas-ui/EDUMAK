-- EDUMAK: add shared dataset uploads to an existing Supabase project.
-- Run this once in Supabase Dashboard > SQL Editor. Safe to re-run.

create table if not exists public.dataset_documents (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  resource_key text not null,
  version integer not null check (version > 0),
  file_name text not null,
  storage_path text not null unique,
  file_size bigint not null default 0 check (file_size >= 0),
  file_type text not null check (file_type in ('csv','json','xlsx','xls')),
  uploaded_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(resource_key, version)
);

create index if not exists dataset_documents_latest_idx
  on public.dataset_documents(resource_key, version desc);

alter table public.dataset_documents enable row level security;
drop policy if exists "authenticated read dataset metadata" on public.dataset_documents;
create policy "authenticated read dataset metadata"
  on public.dataset_documents for select to authenticated using (true);
drop policy if exists "admin upload dataset metadata" on public.dataset_documents;
create policy "admin upload dataset metadata"
  on public.dataset_documents for insert to authenticated
  with check (public.is_edumak_admin() and uploaded_by=auth.uid());
drop policy if exists "admin delete dataset metadata" on public.dataset_documents;
create policy "admin delete dataset metadata"
  on public.dataset_documents for delete to authenticated
  using (public.is_edumak_admin());
grant select, insert, delete on public.dataset_documents to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('edumak-datasets','edumak-datasets',false,26214400,array[
  'text/csv','application/json',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.ms-excel'
])
on conflict(id) do update set public=false,file_size_limit=26214400,
  allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists "authenticated read edumak datasets" on storage.objects;
create policy "authenticated read edumak datasets" on storage.objects
  for select to authenticated using (bucket_id='edumak-datasets');
drop policy if exists "admin upload edumak datasets" on storage.objects;
create policy "admin upload edumak datasets" on storage.objects
  for insert to authenticated
  with check (bucket_id='edumak-datasets' and public.is_edumak_admin());
drop policy if exists "admin delete edumak datasets" on storage.objects;
create policy "admin delete edumak datasets" on storage.objects
  for delete to authenticated
  using (bucket_id='edumak-datasets' and public.is_edumak_admin());

do $$ begin
  if not exists (select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public'
      and tablename='dataset_documents') then
    alter publication supabase_realtime add table public.dataset_documents;
  end if;
end $$;
