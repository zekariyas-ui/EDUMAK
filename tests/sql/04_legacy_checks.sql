-- Part B: after 001 + 002 were applied to the legacy database.
\set ON_ERROR_STOP off
\pset tuples_only on
\o /dev/null
\ir macros.sql
:as_super
select t.ok((select count(*) from public.loans)=(select n from t.legacy_count), 'U1 no legacy loan was added or removed');
select t.ok(not exists (select 1 from public.loans l join t.legacy_snap s using (id) where md5(concat_ws('|',l.book_id,l.student_id,l.book_title,l.borrowed_at,l.due_at,l.returned_at)) <> s.h), 'U2 every legacy loan is byte-for-byte unchanged (dates, titles, returns)');
select t.ok((select bool_and(book_source='catalogue' and book_author is null and book_identifier is null and created_by is null and returned_by is null) from public.loans), 'U3 legacy loans are catalogue loans; new snapshot columns are left empty (no backfill)');
select t.ok(not exists (select 1 from pg_indexes where indexname='loans_one_active_per_student_book'), 'U4 unique index was NOT created because a duplicate active loan exists (preflight skipped it, migration still succeeded)');
select t.ok((select count(*) from public.edumak_schema_migrations where version in ('000_baseline','001_datasets','002_librarian_loans_and_integrity'))=3, 'U5 migration history recorded 000, 001, 002');
select t.ok(to_regclass('public.dataset_documents') is not null, 'U6 001 added the dataset catalogue to the FINAL database');
:as_s1
select t.ok((select count(*) from public.loans)=3, 'U7 Amina still sees her 3 legacy loans');
select t.fails($$select public.borrow_book('33333333-3333-3333-3333-333333333333')$$, 'permission denied', 'U8 old student borrowing is closed after 002');
select t.fails($$update public.loans set due_at=now()+interval '30 days'$$, 'permission denied', 'U9 student cannot extend a legacy deadline');
:as_s2
select t.ok((select available from public.get_book_availability() where book_id='22222222-2222-2222-2222-222222222222')=0, 'U10 over-lent legacy book shows 0 available (never negative)');
:as_admin
select t.fails($$update public.books set total_quantity=0 where id='22222222-2222-2222-2222-222222222222'$$, 'currently on loan', 'U11 over-lent legacy book cannot be reduced further');
select t.works($$update public.books set total_quantity=2 where id='22222222-2222-2222-2222-222222222222'$$, 'U12 but its quantity can be raised to cover the loans');
select t.fails($$select public.admin_create_loan('00000000-0000-0000-0000-0000000000b1','11111111-1111-1111-1111-111111111111')$$, 'already has an active loan', 'U13 new duplicates are blocked even while legacy duplicates exist');
select t.works($$select public.admin_return_loan('a0000000-0000-0000-0000-000000000003')$$, 'U14 librarian can return a legacy loan');
select t.works($$select public.admin_return_loan('a0000000-0000-0000-0000-000000000002')$$, 'U15 librarian returns the duplicate legacy loan');
:as_super
select t.ok((select returned_by='00000000-0000-0000-0000-0000000000a1' and book_title='Rare Atlas' and due_at=(select due_at from public.loans where id='a0000000-0000-0000-0000-000000000003') from public.loans where id='a0000000-0000-0000-0000-000000000003'), 'U16 return recorded the librarian and kept the legacy deadline');
select t.fails($$update public.loans set due_at=due_at+interval '30 days' where id='a0000000-0000-0000-0000-000000000001'$$, 'never be changed', 'U17 after 003 even the database owner cannot extend a legacy deadline');
select t.fails($$delete from public.loans where id='a0000000-0000-0000-0000-000000000005'$$, 'cannot be deleted', 'U18 after 003 legacy history cannot be deleted');
\o
\pset tuples_only off
select name, 'FAIL' as result, coalesce(detail,'') as detail from t.results where not ok order by n;
select 'LEGACY TOTAL '||count(*)||'  PASS '||count(*) filter (where ok)||'  FAIL '||count(*) filter (where not ok) as summary from t.results;
