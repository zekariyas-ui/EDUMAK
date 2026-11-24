-- EDUMAK migration 003: protect borrowing history; audited corrections.
--
-- Run in Supabase Dashboard > SQL Editor AFTER 002. Safe to re-run. It does not change any
-- existing loan row. After it:
--   * a loan record can never be deleted, and its student, book, dates and deadline never change;
--   * the only allowed change is the authorized return (not returned -> returned at database "now");
--   * any other fix goes through admin_correct_loan(), which needs a written reason and leaves a
--     permanent audit row (who, when, why, old and new values).
-- Limit: the database owner (e.g. someone with full SQL access who runs ALTER TABLE ... DISABLE
-- TRIGGER) can always bypass triggers. This protects against the app, the API and accidents.

-- ---------------------------------------------------------------------------
-- 1. Audit table (insert-only)
-- ---------------------------------------------------------------------------
create table if not exists public.loan_corrections (
  id uuid primary key default gen_random_uuid(),
  loan_id uuid not null references public.loans(id) on delete restrict,
  kind text not null check (kind in ('undo_return', 'edit_manual_details')),
  reason text not null check (char_length(btrim(reason)) between 10 and 500),
  old_values jsonb not null,
  new_values jsonb not null,
  corrected_by uuid not null,
  corrected_by_email text,
  corrected_at timestamptz not null default now(),
  xid bigint not null default txid_current()
);
create index if not exists loan_corrections_loan_idx on public.loan_corrections(loan_id, corrected_at desc);

alter table public.loan_corrections enable row level security;
drop policy if exists "admins read loan corrections" on public.loan_corrections;
create policy "admins read loan corrections" on public.loan_corrections
  for select to authenticated using (public.is_edumak_admin());
revoke all on public.loan_corrections from public, anon, authenticated;
grant select on public.loan_corrections to authenticated;

create or replace function public.edumak_audit_immutable() returns trigger
language plpgsql as $$
begin
  raise exception 'Audit records cannot be changed, deleted or truncated.' using errcode = '42501';
end $$;
drop trigger if exists loan_corrections_immutable on public.loan_corrections;
create trigger loan_corrections_immutable before update or delete on public.loan_corrections
for each row execute function public.edumak_audit_immutable();
drop trigger if exists loan_corrections_no_truncate on public.loan_corrections;
create trigger loan_corrections_no_truncate before truncate on public.loan_corrections
for each statement execute function public.edumak_audit_immutable();

-- ---------------------------------------------------------------------------
-- 2. Loan history protection
-- ---------------------------------------------------------------------------
create or replace function public.edumak_loans_no_truncate() returns trigger
language plpgsql as $$
begin
  raise exception 'Loan history cannot be truncated.' using errcode = '42501';
end $$;
drop trigger if exists loans_no_truncate on public.loans;
create trigger loans_no_truncate before truncate on public.loans
for each statement execute function public.edumak_loans_no_truncate();

create or replace function public.edumak_loans_protect_history() returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_kind text;
begin
  if tg_op = 'DELETE' then
    raise exception 'Loan history cannot be deleted. Record a correction instead.' using errcode = '42501';
  end if;
  if new is not distinct from old then return new; end if;

  -- The student, the book, the dates and the deadline are never changeable, with no exception.
  if new.id is distinct from old.id or new.book_id is distinct from old.book_id
     or new.student_id is distinct from old.student_id or new.book_source is distinct from old.book_source
     or new.borrowed_at is distinct from old.borrowed_at or new.due_at is distinct from old.due_at
     or new.created_at is distinct from old.created_at then
    raise exception 'A loan''s student, book, dates and deadline can never be changed.' using errcode = '42501';
  end if;

  -- A foreign-key action (an account was deleted) may only EMPTY created_by / returned_by.
  if pg_trigger_depth() > 1
     and (new.created_by is not distinct from old.created_by or new.created_by is null)
     and (new.returned_by is not distinct from old.returned_by or new.returned_by is null)
     and new.returned_at is not distinct from old.returned_at
     and new.book_title is not distinct from old.book_title
     and new.book_author is not distinct from old.book_author
     and new.book_identifier is not distinct from old.book_identifier then
    return new;
  end if;

  if new.created_by is distinct from old.created_by then
    raise exception 'Who recorded a loan cannot be changed.' using errcode = '42501';
  end if;

  -- The one authorized return: not returned -> returned at the database clock, nothing else changes.
  if old.returned_at is null and new.returned_at is not null and new.returned_by is not null
     and new.returned_at = now()
     and new.book_title is not distinct from old.book_title
     and new.book_author is not distinct from old.book_author
     and new.book_identifier is not distinct from old.book_identifier then
    return new;
  end if;

  -- Anything else must be an audited correction written in this same transaction.
  select c.kind into v_kind from public.loan_corrections c
  where c.loan_id = old.id and c.xid = txid_current()
  order by c.corrected_at desc, c.id limit 1;
  if v_kind is null then
    raise exception 'Loan history cannot be edited. Use the audited correction function (admin_correct_loan).' using errcode = '42501';
  end if;
  if v_kind = 'undo_return' then
    if old.returned_at is not null and new.returned_at is null and new.returned_by is null
       and new.book_title is not distinct from old.book_title
       and new.book_author is not distinct from old.book_author
       and new.book_identifier is not distinct from old.book_identifier then
      return new;
    end if;
  elsif v_kind = 'edit_manual_details' then
    if old.book_source = 'manual'
       and new.returned_at is not distinct from old.returned_at
       and new.returned_by is not distinct from old.returned_by then
      return new;
    end if;
  end if;
  raise exception 'This change does not match the recorded correction.' using errcode = '42501';
end $$;

drop trigger if exists loans_protect_history on public.loans;
create trigger loans_protect_history before update or delete on public.loans
for each row execute function public.edumak_loans_protect_history();

-- ---------------------------------------------------------------------------
-- 3. The audited correction function (admin only)
-- ---------------------------------------------------------------------------
create or replace function public.admin_correct_loan(
  p_loan_id uuid,
  p_kind text,
  p_reason text,
  p_book_title text default null,
  p_book_author text default null,
  p_book_identifier text default null)
returns public.loan_corrections
language plpgsql security definer set search_path = public
as $$
declare
  v_loan public.loans%rowtype; v_book public.books%rowtype; v_row public.loan_corrections%rowtype;
  v_reason text; v_title text; v_author text; v_ident text; v_active integer; v_email text;
  v_old jsonb; v_new jsonb;
begin
  if auth.uid() is null or not public.is_edumak_admin() then
    raise exception 'Administrator access required' using errcode = '42501';
  end if;
  v_reason := btrim(regexp_replace(coalesce(p_reason, ''), '\s+', ' ', 'g'));
  if char_length(v_reason) < 10 then raise exception 'Enter a reason of at least 10 characters for the correction'; end if;
  if char_length(v_reason) > 500 then raise exception 'The reason is too long (500 characters maximum)'; end if;
  if p_kind is null or p_kind not in ('undo_return', 'edit_manual_details') then
    raise exception 'Unknown correction type';
  end if;

  select * into v_loan from public.loans where id = p_loan_id;
  if not found then raise exception 'Borrowing record not found'; end if;
  -- Lock order is always student, then book, then loan (same as admin_create_loan / admin_return_loan).
  perform 1 from public.profiles where id = v_loan.student_id for update;
  if v_loan.book_id is not null then
    select * into v_book from public.books where id = v_loan.book_id for update;
  end if;
  select * into v_loan from public.loans where id = p_loan_id for update;

  if p_kind = 'undo_return' then
    if v_loan.returned_at is null then raise exception 'This book has not been returned, so there is nothing to undo'; end if;
    if v_loan.book_source = 'catalogue' then
      if exists (select 1 from public.loans where student_id = v_loan.student_id and book_id = v_loan.book_id and returned_at is null) then
        raise exception 'This student already has an active loan of this book';
      end if;
      select count(*) into v_active from public.loans where book_id = v_loan.book_id and returned_at is null;
      if v_active >= v_book.total_quantity then raise exception 'No copy is free, so this return cannot be undone'; end if;
    elsif exists (select 1 from public.loans
                  where student_id = v_loan.student_id and book_source = 'manual' and returned_at is null
                    and lower(book_title) = lower(v_loan.book_title)
                    and coalesce(lower(book_identifier), '') = coalesce(lower(v_loan.book_identifier), '')) then
      raise exception 'This student already has an active loan of this book';
    end if;
    v_old := jsonb_build_object('returned_at', v_loan.returned_at, 'returned_by', v_loan.returned_by);
    v_new := jsonb_build_object('returned_at', null, 'returned_by', null);
  else
    if v_loan.book_source <> 'manual' then
      raise exception 'Only manually entered loans can have their book details corrected';
    end if;
    -- NULL parameter = leave unchanged; empty text = clear (author / identifier only).
    v_title  := case when p_book_title is null then v_loan.book_title
                     else nullif(btrim(regexp_replace(p_book_title, '\s+', ' ', 'g')), '') end;
    v_author := case when p_book_author is null then v_loan.book_author
                     else nullif(btrim(regexp_replace(p_book_author, '\s+', ' ', 'g')), '') end;
    v_ident  := case when p_book_identifier is null then v_loan.book_identifier
                     else nullif(btrim(regexp_replace(p_book_identifier, '\s+', ' ', 'g')), '') end;
    if v_title is null then raise exception 'The book title cannot be blank'; end if;
    if char_length(v_title) > 200 then raise exception 'The book title is too long (200 characters maximum)'; end if;
    if v_author is not null and char_length(v_author) > 120 then raise exception 'The author name is too long (120 characters maximum)'; end if;
    if v_ident is not null and char_length(v_ident) > 64 then raise exception 'The book identification number is too long (64 characters maximum)'; end if;
    if v_title is not distinct from v_loan.book_title and v_author is not distinct from v_loan.book_author
       and v_ident is not distinct from v_loan.book_identifier then
      raise exception 'Nothing to correct: the details are unchanged';
    end if;
    if v_loan.returned_at is null and exists (
         select 1 from public.loans
         where student_id = v_loan.student_id and id <> v_loan.id and book_source = 'manual' and returned_at is null
           and lower(book_title) = lower(v_title)
           and coalesce(lower(book_identifier), '') = coalesce(lower(v_ident), '')) then
      raise exception 'This student already has an active loan of this book';
    end if;
    v_old := jsonb_build_object('book_title', v_loan.book_title, 'book_author', v_loan.book_author, 'book_identifier', v_loan.book_identifier);
    v_new := jsonb_build_object('book_title', v_title, 'book_author', v_author, 'book_identifier', v_ident);
  end if;

  select email into v_email from public.profiles where id = auth.uid();
  insert into public.loan_corrections(loan_id, kind, reason, old_values, new_values, corrected_by, corrected_by_email)
  values (v_loan.id, p_kind, v_reason, v_old, v_new, auth.uid(), v_email)
  returning * into v_row;

  if p_kind = 'undo_return' then
    update public.loans set returned_at = null, returned_by = null where id = v_loan.id;
  else
    update public.loans set book_title = v_title, book_author = v_author, book_identifier = v_ident where id = v_loan.id;
  end if;
  return v_row;
end $$;

revoke all on function public.edumak_audit_immutable() from public, anon, authenticated;
revoke all on function public.edumak_loans_no_truncate() from public, anon, authenticated;
revoke all on function public.edumak_loans_protect_history() from public, anon, authenticated;
revoke all on function public.admin_correct_loan(uuid, text, text, text, text, text) from public, anon;
grant execute on function public.admin_correct_loan(uuid, text, text, text, text, text) to authenticated;

insert into public.edumak_schema_migrations(version, notes)
values ('003_loan_history_protection', 'loans are append-only except the authorized return; audited corrections')
on conflict (version) do nothing;
