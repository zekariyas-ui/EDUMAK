-- EDUMAK migration 002: librarian-controlled loans, manual book entry,
-- accurate availability, server time, and loan integrity guards.
--
-- Run in Supabase Dashboard > SQL Editor AFTER database_setup.sql
-- (and after 001_datasets.sql if you are upgrading from the FINAL package).
-- Safe to re-run. It never deletes, rewrites or backfills existing loan rows.
-- Optional: run migrations/preflight_002_readonly.sql first to see what it will meet.

-- ---------------------------------------------------------------------------
-- 0. Migration history
-- ---------------------------------------------------------------------------
create table if not exists public.edumak_schema_migrations (
  version text primary key,
  applied_at timestamptz not null default now(),
  notes text
);
alter table public.edumak_schema_migrations enable row level security;
revoke all on public.edumak_schema_migrations from anon, authenticated;

insert into public.edumak_schema_migrations(version, notes)
select '000_baseline', 'recorded by 002: database_setup.sql / FINAL setup assumed applied'
where to_regclass('public.loans') is not null
on conflict (version) do nothing;
insert into public.edumak_schema_migrations(version, notes)
select '001_datasets', 'recorded by 002: dataset_documents table exists'
where to_regclass('public.dataset_documents') is not null
on conflict (version) do nothing;

-- ---------------------------------------------------------------------------
-- 1. Loan records: book snapshot for manual entries, who recorded what
-- ---------------------------------------------------------------------------
alter table public.loans add column if not exists book_author text;
alter table public.loans add column if not exists book_identifier text;
alter table public.loans add column if not exists book_source text not null default 'catalogue';
alter table public.loans add column if not exists created_by uuid references public.profiles(id) on delete set null;
alter table public.loans add column if not exists returned_by uuid references public.profiles(id) on delete set null;
-- Manual loans have no catalogue book. The existing foreign key (on delete restrict) is kept.
alter table public.loans alter column book_id drop not null;

do $$ begin
  if not exists (select 1 from pg_constraint where conrelid='public.loans'::regclass and conname='loans_book_source_check') then
    alter table public.loans add constraint loans_book_source_check check (book_source in ('catalogue','manual'));
  end if;
  if not exists (select 1 from pg_constraint where conrelid='public.loans'::regclass and conname='loans_source_book_consistency') then
    alter table public.loans add constraint loans_source_book_consistency
      check ((book_source='catalogue' and book_id is not null) or (book_source='manual' and book_id is null));
  end if;
  if not exists (select 1 from pg_constraint where conrelid='public.loans'::regclass and conname='loans_book_author_length') then
    alter table public.loans add constraint loans_book_author_length check (book_author is null or char_length(book_author) <= 120);
  end if;
  if not exists (select 1 from pg_constraint where conrelid='public.loans'::regclass and conname='loans_book_identifier_length') then
    alter table public.loans add constraint loans_book_identifier_length check (book_identifier is null or char_length(book_identifier) <= 64);
  end if;
  -- NOT VALID: applies to new rows only, so existing history can never make the migration fail.
  if not exists (select 1 from pg_constraint where conrelid='public.loans'::regclass and conname='loans_book_title_length') then
    alter table public.loans add constraint loans_book_title_length check (char_length(book_title) between 1 and 200) not valid;
  end if;
end $$;

-- One active loan per student and catalogue book. Created only if existing data allows it.
do $$
declare v_dups integer;
begin
  select count(*) into v_dups from (
    select 1 from public.loans
    where returned_at is null and book_id is not null
    group by student_id, book_id having count(*) > 1) d;
  if v_dups = 0 then
    create unique index if not exists loans_one_active_per_student_book
      on public.loans(student_id, book_id) where returned_at is null and book_id is not null;
  else
    raise warning 'EDUMAK preflight: % student/book pair(s) already have more than one ACTIVE loan, so the unique index was NOT created. New duplicates are still blocked by admin_create_loan. Record the extra returns and re-run this migration to add the index.', v_dups;
  end if;
end $$;

-- One active MANUAL loan per student, title and identification number (case-insensitive).
-- Manual loans did not exist before this migration, so this can only meet duplicates if rows were edited by hand.
do $$
declare v_dups integer;
begin
  select count(*) into v_dups from (
    select 1 from public.loans
    where returned_at is null and book_source = 'manual'
    group by student_id, lower(book_title), coalesce(lower(book_identifier), '') having count(*) > 1) d;
  if v_dups = 0 then
    create unique index if not exists loans_one_active_manual_per_student_title
      on public.loans(student_id, lower(book_title), coalesce(lower(book_identifier), ''))
      where returned_at is null and book_source = 'manual';
  else
    raise warning 'EDUMAK preflight: % student/title pair(s) already have more than one ACTIVE manual loan, so the manual-loan unique index was NOT created. New duplicates are still blocked by admin_create_loan.', v_dups;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Library policy values (single place) and server clock
-- ---------------------------------------------------------------------------
create or replace function public.edumak_loan_hours() returns integer
language sql immutable as $$ select 72 $$;
create or replace function public.edumak_due_soon_hours() returns integer
language sql immutable as $$ select 24 $$;

create or replace function public.get_library_clock()
returns table(server_now timestamptz, loan_hours integer, due_soon_hours integer)
language sql stable security definer set search_path = public
as $$ select now(), public.edumak_loan_hours(), public.edumak_due_soon_hours() $$;

-- ---------------------------------------------------------------------------
-- 3. Availability: aggregate counts only, no student information
-- ---------------------------------------------------------------------------
create or replace function public.get_book_availability()
returns table(book_id uuid, total_quantity integer, active_loans integer, available integer)
language sql stable security definer set search_path = public
as $$
  select b.id, b.total_quantity, coalesce(l.n, 0)::integer,
         greatest(0, b.total_quantity - coalesce(l.n, 0))::integer
  from public.books b
  left join (select ln.book_id, count(*) as n from public.loans ln
             where ln.returned_at is null and ln.book_id is not null
             group by ln.book_id) l on l.book_id = b.id
$$;

-- ---------------------------------------------------------------------------
-- 4. Librarian-only functions
-- ---------------------------------------------------------------------------
create or replace function public.admin_search_students(p_query text default '', p_limit integer default 20)
returns table(id uuid, display_name text, email text, created_at timestamptz)
language plpgsql stable security definer set search_path = public
as $$
declare v_q text; v_lim integer;
begin
  if auth.uid() is null or not public.is_edumak_admin() then
    raise exception 'Administrator access required' using errcode = '42501';
  end if;
  v_q := btrim(coalesce(p_query, ''));
  v_lim := least(greatest(coalesce(p_limit, 20), 1), 50);
  v_q := replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_');
  return query
    select p.id, p.display_name, p.email, p.created_at
    from public.profiles p
    where p.role = 'student'
      and (v_q = '' or p.display_name ilike '%' || v_q || '%' escape '\'
                    or p.email ilike '%' || v_q || '%' escape '\')
    order by lower(p.display_name), p.email
    limit v_lim;
end $$;

create or replace function public.admin_create_loan(
  p_student_id uuid,
  p_book_id uuid default null,
  p_title text default null,
  p_author text default null,
  p_book_identifier text default null)
returns public.loans
language plpgsql security definer set search_path = public
as $$
declare
  v_student public.profiles%rowtype;
  v_book public.books%rowtype;
  v_loan public.loans%rowtype;
  v_title text; v_author text; v_ident text; v_active integer;
begin
  if auth.uid() is null or not public.is_edumak_admin() then
    raise exception 'Administrator access required' using errcode = '42501';
  end if;
  if p_student_id is null then raise exception 'Choose a student'; end if;

  -- Lock order is always: student, then book. Serializes loans per student (no duplicate races)
  -- and per book (no over-lending of the last copy).
  select * into v_student from public.profiles where id = p_student_id for update;
  if not found then raise exception 'Student not found'; end if;
  if v_student.role <> 'student' then raise exception 'The selected account is not a student account'; end if;

  v_title  := nullif(btrim(regexp_replace(coalesce(p_title, ''), '\s+', ' ', 'g')), '');
  v_author := nullif(btrim(regexp_replace(coalesce(p_author, ''), '\s+', ' ', 'g')), '');
  v_ident  := nullif(btrim(regexp_replace(coalesce(p_book_identifier, ''), '\s+', ' ', 'g')), '');

  if p_book_id is not null then
    if v_title is not null or v_author is not null or v_ident is not null then
      raise exception 'Choose either a catalogue book or manual book details, not both';
    end if;
    select * into v_book from public.books where id = p_book_id for update;
    if not found then raise exception 'Book not found in the catalogue'; end if;
    if exists (select 1 from public.loans
               where student_id = p_student_id and book_id = p_book_id and returned_at is null) then
      raise exception 'This student already has an active loan of this book';
    end if;
    select count(*) into v_active from public.loans where book_id = p_book_id and returned_at is null;
    if v_active >= v_book.total_quantity then raise exception 'No copies are currently available'; end if;
    insert into public.loans(book_id, student_id, book_title, book_author, book_source,
                             borrowed_at, due_at, created_by)
    values (v_book.id, p_student_id, v_book.title, nullif(btrim(v_book.author), ''), 'catalogue',
            now(), now() + make_interval(hours => public.edumak_loan_hours()), auth.uid())
    returning * into v_loan;
  else
    if v_title is null then raise exception 'Enter the book title'; end if;
    if char_length(v_title) > 200 then raise exception 'The book title is too long (200 characters maximum)'; end if;
    if v_author is not null and char_length(v_author) > 120 then raise exception 'The author name is too long (120 characters maximum)'; end if;
    if v_ident is not null and char_length(v_ident) > 64 then raise exception 'The book identification number is too long (64 characters maximum)'; end if;
    if exists (select 1 from public.loans
               where student_id = p_student_id and book_source = 'manual' and returned_at is null
                 and lower(book_title) = lower(v_title)
                 and coalesce(lower(book_identifier), '') = coalesce(lower(v_ident), '')) then
      raise exception 'This student already has an active loan of this book';
    end if;
    insert into public.loans(book_id, student_id, book_title, book_author, book_identifier, book_source,
                             borrowed_at, due_at, created_by)
    values (null, p_student_id, v_title, v_author, v_ident, 'manual',
            now(), now() + make_interval(hours => public.edumak_loan_hours()), auth.uid())
    returning * into v_loan;
  end if;
  return v_loan;
end $$;

create or replace function public.admin_return_loan(p_loan_id uuid)
returns public.loans
language plpgsql security definer set search_path = public
as $$
declare v_loan public.loans%rowtype;
begin
  if auth.uid() is null or not public.is_edumak_admin() then
    raise exception 'Administrator access required' using errcode = '42501';
  end if;
  select * into v_loan from public.loans where id = p_loan_id;      -- unlocked peek to learn what to lock
  if not found then raise exception 'Borrowing record not found'; end if;
  -- Lock order is always student, then book, then loan (the same order as admin_create_loan).
  perform 1 from public.profiles where id = v_loan.student_id for update;
  if v_loan.book_id is not null then perform 1 from public.books where id = v_loan.book_id for update; end if;
  select * into v_loan from public.loans where id = p_loan_id for update;
  if v_loan.returned_at is not null then raise exception 'This book has already been returned'; end if;
  update public.loans set returned_at = now(), returned_by = auth.uid()
  where id = p_loan_id returning * into v_loan;
  return v_loan;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Students can no longer borrow or return. Old functions refuse and are revoked.
-- ---------------------------------------------------------------------------
create or replace function public.borrow_book(p_book_id uuid)
returns uuid language plpgsql security definer set search_path = public
as $$ begin
  raise exception 'Borrowing is recorded by the librarian. Please see the librarian.' using errcode = '42501';
end $$;
create or replace function public.return_book(p_loan_id uuid)
returns void language plpgsql security definer set search_path = public
as $$ begin
  raise exception 'Returns are recorded by the librarian. Please see the librarian.' using errcode = '42501';
end $$;

-- ---------------------------------------------------------------------------
-- 6. Integrity guards on books
-- ---------------------------------------------------------------------------
create or replace function public.edumak_books_guard_quantity() returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_active integer;
begin
  if new.total_quantity < old.total_quantity then
    select count(*) into v_active from public.loans where book_id = old.id and returned_at is null;
    if new.total_quantity < v_active then
      raise exception 'Cannot reduce the total quantity to %: % copies of this book are currently on loan. Record the returns first.',
        new.total_quantity, v_active;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists books_guard_quantity on public.books;
create trigger books_guard_quantity before update of total_quantity on public.books
for each row execute function public.edumak_books_guard_quantity();

create or replace function public.edumak_books_guard_delete() returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_total integer; v_active integer;
begin
  select count(*), count(*) filter (where returned_at is null) into v_total, v_active
  from public.loans where book_id = old.id;
  if v_total > 0 then
    raise exception 'This book has borrowing history (% loans, % currently on loan) and cannot be deleted. Set its quantity to 0 to stop lending it.',
      v_total, v_active;
  end if;
  return old;
end $$;
drop trigger if exists books_guard_delete on public.books;
create trigger books_guard_delete before delete on public.books
for each row execute function public.edumak_books_guard_delete();

create or replace function public.edumak_touch_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;
drop trigger if exists books_touch_updated_at on public.books;
create trigger books_touch_updated_at before update on public.books
for each row execute function public.edumak_touch_updated_at();

-- Touching the book row on loan changes lets Realtime tell every open device to refresh availability.
create or replace function public.edumak_loan_touch_book() returns trigger
language plpgsql security definer set search_path = public
as $$ begin
  if new.book_id is not null then
    update public.books set updated_at = now() where id = new.book_id;
  end if;
  return new;
end $$;
drop trigger if exists loans_touch_book on public.loans;
create trigger loans_touch_book after insert or update of returned_at on public.loans
for each row execute function public.edumak_loan_touch_book();

-- ---------------------------------------------------------------------------
-- 7. Privileges: do not rely on Supabase default grants
-- ---------------------------------------------------------------------------
-- Loan rows can be written only by the admin functions above.
revoke insert, update, delete, truncate on public.loans from public, anon, authenticated;

revoke all on function public.edumak_loan_hours() from public, anon, authenticated;
revoke all on function public.edumak_due_soon_hours() from public, anon, authenticated;
revoke all on function public.edumak_books_guard_quantity() from public, anon, authenticated;
revoke all on function public.edumak_books_guard_delete() from public, anon, authenticated;
revoke all on function public.edumak_touch_updated_at() from public, anon, authenticated;
revoke all on function public.edumak_loan_touch_book() from public, anon, authenticated;

revoke all on function public.borrow_book(uuid) from public, anon, authenticated;
revoke all on function public.return_book(uuid) from public, anon, authenticated;

revoke all on function public.get_book_availability() from public;
grant execute on function public.get_book_availability() to anon, authenticated;

revoke all on function public.get_library_clock() from public, anon;
grant execute on function public.get_library_clock() to authenticated;

revoke all on function public.admin_search_students(text, integer) from public, anon;
revoke all on function public.admin_create_loan(uuid, uuid, text, text, text) from public, anon;
revoke all on function public.admin_return_loan(uuid) from public, anon;
grant execute on function public.admin_search_students(text, integer) to authenticated;
grant execute on function public.admin_create_loan(uuid, uuid, text, text, text) to authenticated;
grant execute on function public.admin_return_loan(uuid) to authenticated;

insert into public.edumak_schema_migrations(version, notes)
values ('002_librarian_loans_and_integrity', 'librarian-only loans, manual book snapshot, availability, server clock, guards')
on conflict (version) do nothing;
