-- EDUMAK shared database setup for Supabase
-- Run the complete script in Supabase Dashboard > SQL Editor > New query.
-- This script is the baseline and is safe to re-run. AFTER it, run the files in
-- migrations/ in numeric order (see SETUP_GUIDE.txt). Migration 002 is REQUIRED:
-- it makes borrowing and returning librarian-only.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  display_name text not null default 'Student',
  role text not null default 'student' check (role in ('student','admin')),
  created_at timestamptz not null default now()
);
create table if not exists public.books (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  author text not null default '',
  category text not null,
  description text not null default '',
  total_quantity integer not null default 0 check (total_quantity >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists books_title_unique_ci on public.books (lower(title));
create table if not exists public.loans (
  id uuid primary key default gen_random_uuid(),
  book_id uuid not null references public.books(id) on delete restrict,
  student_id uuid not null references public.profiles(id) on delete restrict,
  book_title text not null,
  borrowed_at timestamptz not null default now(),
  due_at timestamptz not null,
  returned_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists loans_active_book_idx on public.loans(book_id) where returned_at is null;
create index if not exists loans_student_idx on public.loans(student_id, borrowed_at desc);
create table if not exists public.pdf_documents (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  file_name text not null,
  storage_path text not null unique,
  file_size bigint not null default 0,
  uploaded_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create or replace function public.is_edumak_admin()
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.profiles where id=auth.uid() and role='admin') $$;

create or replace function public.handle_new_edumak_user()
returns trigger language plpgsql security definer set search_path=public
as $$ begin
  insert into public.profiles(id,email,display_name,role)
  values(new.id, coalesce(new.email,''), coalesce(new.raw_user_meta_data->>'display_name','Student'), 'student')
  on conflict(id) do update set email=excluded.email;
  return new;
end; $$;
drop trigger if exists on_auth_user_created_edumak on auth.users;
create trigger on_auth_user_created_edumak after insert on auth.users
for each row execute procedure public.handle_new_edumak_user();

-- Prevent a user from promoting their own profile to admin.
create or replace function public.protect_edumak_role()
returns trigger language plpgsql security definer set search_path=public
as $$ begin
  -- auth.uid() is NULL when a trusted operator runs SQL in the Supabase
  -- dashboard. Normal app users always have a JWT and must already be admin.
  if new.role is distinct from old.role
     and auth.uid() is not null
     and not public.is_edumak_admin() then
    raise exception 'Only an existing administrator can change account roles';
  end if;
  return new;
end; $$;
drop trigger if exists protect_edumak_role_trigger on public.profiles;
create trigger protect_edumak_role_trigger before update on public.profiles
for each row execute procedure public.protect_edumak_role();

create or replace function public.borrow_book(p_book_id uuid)
returns uuid language plpgsql security definer set search_path=public
as $$
declare v_profile public.profiles%rowtype; v_book public.books%rowtype; v_active integer; v_id uuid;
begin
  if auth.uid() is null then raise exception 'Please sign in first'; end if;
  select * into v_profile from public.profiles where id=auth.uid();
  if not found or v_profile.role <> 'student' then raise exception 'A student account is required to borrow books'; end if;
  select * into v_book from public.books where id=p_book_id for update;
  if not found then raise exception 'Book not found'; end if;
  select count(*) into v_active from public.loans where book_id=p_book_id and returned_at is null;
  if v_active >= v_book.total_quantity then raise exception 'No copies are currently available'; end if;
  insert into public.loans(book_id,student_id,book_title,borrowed_at,due_at)
  values(v_book.id,auth.uid(),v_book.title,now(),now()+interval '72 hours') returning id into v_id;
  return v_id;
end; $$;

create or replace function public.return_book(p_loan_id uuid)
returns void language plpgsql security definer set search_path=public
as $$
declare v_loan public.loans%rowtype;
begin
  if auth.uid() is null then raise exception 'Please sign in first'; end if;
  select * into v_loan from public.loans where id=p_loan_id for update;
  if not found then raise exception 'Borrowing record not found'; end if;
  if v_loan.student_id <> auth.uid() and not public.is_edumak_admin() then raise exception 'You cannot return another student''s book'; end if;
  if v_loan.returned_at is not null then raise exception 'This book has already been returned'; end if;
  update public.loans set returned_at=now() where id=p_loan_id;
end; $$;

alter table public.profiles enable row level security;
alter table public.books enable row level security;
alter table public.loans enable row level security;
alter table public.pdf_documents enable row level security;
drop policy if exists "profiles read self or admin" on public.profiles;
create policy "profiles read self or admin" on public.profiles for select to authenticated using (id=auth.uid() or public.is_edumak_admin());
drop policy if exists "profiles update self or admin" on public.profiles;
create policy "profiles update self or admin" on public.profiles for update to authenticated using (id=auth.uid() or public.is_edumak_admin()) with check (id=auth.uid() or public.is_edumak_admin());
drop policy if exists "books readable" on public.books;
create policy "books readable" on public.books for select to anon,authenticated using (true);
drop policy if exists "admin insert books" on public.books;
create policy "admin insert books" on public.books for insert to authenticated with check (public.is_edumak_admin());
drop policy if exists "admin update books" on public.books;
create policy "admin update books" on public.books for update to authenticated using (public.is_edumak_admin()) with check (public.is_edumak_admin());
drop policy if exists "admin delete books" on public.books;
create policy "admin delete books" on public.books for delete to authenticated using (public.is_edumak_admin());
drop policy if exists "read own loans or admin" on public.loans;
create policy "read own loans or admin" on public.loans for select to authenticated using (student_id=auth.uid() or public.is_edumak_admin());
drop policy if exists "admin read pdf metadata" on public.pdf_documents;
drop policy if exists "read pdf metadata" on public.pdf_documents;
create policy "read pdf metadata" on public.pdf_documents for select to authenticated using (true);
drop policy if exists "admin add pdf metadata" on public.pdf_documents;
create policy "admin add pdf metadata" on public.pdf_documents for insert to authenticated with check (public.is_edumak_admin() and uploaded_by=auth.uid());
drop policy if exists "admin delete pdf metadata" on public.pdf_documents;
create policy "admin delete pdf metadata" on public.pdf_documents for delete to authenticated using (public.is_edumak_admin());

grant usage on schema public to anon, authenticated;
grant select on public.books to anon, authenticated;
grant select, update on public.profiles to authenticated;
grant select on public.loans to authenticated;
grant select, insert, delete on public.pdf_documents to authenticated;
grant insert, update, delete on public.books to authenticated;
revoke all on function public.borrow_book(uuid) from public, anon;
revoke all on function public.return_book(uuid) from public, anon;
revoke all on function public.is_edumak_admin() from public, anon;
grant execute on function public.borrow_book(uuid) to authenticated;
grant execute on function public.return_book(uuid) to authenticated;
grant execute on function public.is_edumak_admin() to authenticated;

-- Create the private PDF bucket. Authenticated users may read; admins may upload/delete.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('edumak-pdfs','edumak-pdfs',false,26214400,array['application/pdf'])
on conflict(id) do update set public=false,file_size_limit=26214400,allowed_mime_types=array['application/pdf'];
drop policy if exists "authenticated read edumak pdfs" on storage.objects;
create policy "authenticated read edumak pdfs" on storage.objects for select to authenticated using (bucket_id='edumak-pdfs');
drop policy if exists "admin upload edumak pdfs" on storage.objects;
create policy "admin upload edumak pdfs" on storage.objects for insert to authenticated with check (bucket_id='edumak-pdfs' and public.is_edumak_admin());
drop policy if exists "admin delete edumak pdfs" on storage.objects;
create policy "admin delete edumak pdfs" on storage.objects for delete to authenticated using (bucket_id='edumak-pdfs' and public.is_edumak_admin());

-- Enable live updates for books, loans and PDF catalogue changes.
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='books') then
    alter publication supabase_realtime add table public.books;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='loans') then
    alter publication supabase_realtime add table public.loans;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='pdf_documents') then
    alter publication supabase_realtime add table public.pdf_documents;
  end if;
end $$;


-- Shared dataset catalogue with immutable upload versions.
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
create index if not exists dataset_documents_latest_idx on public.dataset_documents(resource_key, version desc);
alter table public.dataset_documents enable row level security;
drop policy if exists "authenticated read dataset metadata" on public.dataset_documents;
create policy "authenticated read dataset metadata" on public.dataset_documents for select to authenticated using (true);
drop policy if exists "admin upload dataset metadata" on public.dataset_documents;
create policy "admin upload dataset metadata" on public.dataset_documents for insert to authenticated with check (public.is_edumak_admin() and uploaded_by=auth.uid());
drop policy if exists "admin delete dataset metadata" on public.dataset_documents;
create policy "admin delete dataset metadata" on public.dataset_documents for delete to authenticated using (public.is_edumak_admin());
grant select, insert, delete on public.dataset_documents to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('edumak-datasets','edumak-datasets',false,26214400,array['text/csv','application/json','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','application/vnd.ms-excel'])
on conflict(id) do update set public=false,file_size_limit=26214400,allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists "authenticated read edumak datasets" on storage.objects;
create policy "authenticated read edumak datasets" on storage.objects for select to authenticated using (bucket_id='edumak-datasets');
drop policy if exists "admin upload edumak datasets" on storage.objects;
create policy "admin upload edumak datasets" on storage.objects for insert to authenticated with check (bucket_id='edumak-datasets' and public.is_edumak_admin());
drop policy if exists "admin delete edumak datasets" on storage.objects;
create policy "admin delete edumak datasets" on storage.objects for delete to authenticated using (bucket_id='edumak-datasets' and public.is_edumak_admin());
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='dataset_documents') then
    alter publication supabase_realtime add table public.dataset_documents;
  end if;
end $$;

-- Re-run safety: if migration 002 (librarian-only loans) was already applied, this baseline
-- must not re-open student borrowing. Re-apply the lockdown of the old student functions.
do $$
declare v_applied boolean := false;
begin
  if to_regclass('public.edumak_schema_migrations') is not null then
    execute 'select exists (select 1 from public.edumak_schema_migrations where version like ''002%'')' into v_applied;
  end if;
  if v_applied then
    revoke all on function public.borrow_book(uuid) from public, anon, authenticated;
    revoke all on function public.return_book(uuid) from public, anon, authenticated;
    revoke insert, update, delete, truncate on public.loans from public, anon, authenticated;
  end if;
end $$;
