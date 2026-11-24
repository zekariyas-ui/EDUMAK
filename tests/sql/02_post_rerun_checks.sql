-- Runs in the SAME database after the suite, AFTER database_setup.sql, 001 and 002 were applied again.
\set ON_ERROR_STOP off
\pset tuples_only on
\o /dev/null
\ir macros.sql
:as_s1
select t.fails($$select public.borrow_book('33333333-3333-3333-3333-333333333333')$$, 'permission denied', 'W1 after re-running the baseline, students still cannot borrow_book');
select t.fails($$select public.return_book('33333333-3333-3333-3333-333333333333')$$, 'permission denied', 'W2 ... or return_book');
select t.fails($$insert into public.loans(book_id,student_id,book_title,due_at) values('33333333-3333-3333-3333-333333333333','00000000-0000-0000-0000-0000000000b1','x',now())$$, 'permission denied', 'W3 ... or write loans');
:as_admin
select t.works($$select public.admin_create_loan('00000000-0000-0000-0000-0000000000b1', null, 'Post-rerun manual book')$$, 'W4 librarian functions still work after re-runs');
:as_super
select t.ok((select count(*) from public.loans)=(select count(*) from t.rerun_snap)+1, 'W5 re-running the scripts added or removed no loan (only the 1 new loan from W4)');
select t.ok(not exists (select 1 from public.loans l join t.rerun_snap s using (id) where md5(concat_ws('|',l.book_id,l.student_id,l.book_title,l.book_author,l.book_identifier,l.book_source,l.borrowed_at,l.due_at,l.created_by,l.returned_at,l.returned_by)) <> s.h), 'W6 every existing loan row is byte-for-byte unchanged by the re-runs');
select t.ok((select count(*) from public.edumak_schema_migrations where version in ('000_baseline','001_datasets','002_librarian_loans_and_integrity'))=3, 'W7 migration history lists 000, 001 and 002 exactly once');
select t.ok(exists (select 1 from pg_indexes where indexname='loans_one_active_per_student_book'), 'W8 unique active-loan index exists (no duplicates were present)');
select t.fails($$insert into public.loans(book_id,student_id,book_title,due_at,book_source) values('33333333-3333-3333-3333-333333333333','00000000-0000-0000-0000-0000000000b1','dup',now(),'catalogue')$$, 'loans_one_active_per_student_book', 'W9 even a superuser cannot create a duplicate active loan');
select t.ok((select count(*) from pg_proc where proname in ('admin_create_loan','admin_return_loan','admin_search_students','get_book_availability','get_library_clock') and pronamespace='public'::regnamespace)=5, 'W10 all 5 new functions exist exactly once');
select t.ok(exists (select 1 from pg_indexes where indexname='loans_one_active_manual_per_student_title'), 'W12 unique index for active manual loans exists');
select t.fails($$insert into public.loans(book_id,student_id,book_title,book_identifier,book_source,due_at) values(null,'00000000-0000-0000-0000-0000000000b1','INTRODUCTION TO AMHARIC','isbn-123','manual',now())$$, 'loans_one_active_manual_per_student_title', 'W13 even a superuser cannot insert a duplicate active manual loan (case-insensitive)');
select t.ok((select count(*) from pg_trigger where tgname='loans_protect_history' and not tgisinternal)=1, 'W14 the history-protection trigger exists exactly once after the re-runs');
select t.fails($$update public.loans set due_at=due_at+interval '1 day'$$, 'never be changed', 'W15 history protection still active after the re-runs');
select t.ok((select count(*) from public.loan_corrections)=(select count(*) from t.rerun_corr) and not exists (select 1 from public.loan_corrections c join t.rerun_corr s using (id) where md5(c::text)<>s.h), 'W16 re-running the scripts left every audit row untouched');
select t.ok((select count(*) from public.edumak_schema_migrations where version in ('000_baseline','001_datasets','002_librarian_loans_and_integrity','003_loan_history_protection'))=4, 'W17 migration history lists 000-003 exactly once');
:as_anon
select t.ok((select count(*) from public.get_book_availability())>=3, 'W11 guests still read availability after re-runs');
:as_super
\o
\pset tuples_only off
select name, 'FAIL' as result, coalesce(detail,'') as detail from t.results where not ok and name like 'W%' order by n;
select 'TOTAL(all) '||count(*)||'  PASS '||count(*) filter (where ok)||'  FAIL '||count(*) filter (where not ok) as summary from t.results;
