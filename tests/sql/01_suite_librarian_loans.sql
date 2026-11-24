-- EDUMAK SQL test suite (scratch Postgres, NOT a real Supabase project).
-- Run through tests/run_sql_tests.sh, which applies: stub -> database_setup.sql -> 001 -> 002.
\set ON_ERROR_STOP off
\pset tuples_only on
\o /dev/null

\ir helpers.sql

-- ---------------------------------------------------------------- seed (as superuser)
insert into auth.users(id,email,raw_user_meta_data) values
 ('00000000-0000-0000-0000-0000000000a1','admin@t.test','{"display_name":"Lib Admin"}'),
 ('00000000-0000-0000-0000-0000000000a2','admin2@t.test','{"display_name":"Second Admin"}'),
 ('00000000-0000-0000-0000-0000000000b1','amina@t.test','{"display_name":"Amina Student"}'),
 ('00000000-0000-0000-0000-0000000000b2','bekele@t.test','{"display_name":"Bekele Student"}'),
 ('00000000-0000-0000-0000-0000000000b3','100%_sure@t.test','{"display_name":"Percent_User"}');
update public.profiles set role='admin' where email in ('admin@t.test','admin2@t.test');
insert into public.books(id,title,author,category,total_quantity) values
 ('11111111-1111-1111-1111-111111111111','Chemistry 11','Smith','Chem',2),
 ('22222222-2222-2222-2222-222222222222','Rare Atlas','','Geo',1),
 ('33333333-3333-3333-3333-333333333333','Physics 12','Jones','Phys',3),
 ('44444444-4444-4444-4444-444444444444','Delete Me','','Misc',1);
insert into public.pdf_documents(title,file_name,storage_path,uploaded_by) values ('P','p.pdf','a1/p.pdf','00000000-0000-0000-0000-0000000000a1');

-- ---------------------------------------------------------------- 1. availability, guests
:as_anon
select t.ok((select available from public.get_book_availability() where book_id='11111111-1111-1111-1111-111111111111')=2, 'A1 guest sees availability of Chemistry 11 = 2');
select t.ok((select count(*) from public.get_book_availability())=4, 'A2 guest availability lists all 4 catalogue books');
:as_super
select t.ok(pg_get_function_result('public.get_book_availability()'::regprocedure)='TABLE(book_id uuid, total_quantity integer, active_loans integer, available integer)', 'A3 availability returns aggregate columns only (no student information)');
:as_anon
select t.ok((select count(*) from public.loans)=0, 'A4 guest cannot read loans');
select t.ok((select count(*) from public.profiles)=0, 'A5 guest cannot read profiles');
select t.ok((select count(*) from public.pdf_documents)=0, 'A6 guest cannot read PDF metadata');

-- ---------------------------------------------------------------- 2. lockdown: students/anon/admin direct access
:as_s1
select t.fails($$select public.borrow_book('11111111-1111-1111-1111-111111111111')$$, 'permission denied', 'L1 student cannot call borrow_book');
select t.fails($$select public.return_book('11111111-1111-1111-1111-111111111111')$$, 'permission denied', 'L2 student cannot call return_book');
select t.fails($$select public.admin_create_loan('00000000-0000-0000-0000-0000000000b1','11111111-1111-1111-1111-111111111111')$$, 'Administrator access required', 'L3 student cannot create a loan (not even for themselves)');
select t.fails($$select public.admin_return_loan('11111111-1111-1111-1111-111111111111')$$, 'Administrator access required', 'L4 student cannot return a loan');
select t.fails($$select * from public.admin_search_students('')$$, 'Administrator access required', 'L5 student cannot list students');
select t.fails($$insert into public.loans(book_id,student_id,book_title,due_at) values('11111111-1111-1111-1111-111111111111','00000000-0000-0000-0000-0000000000b1','x',now())$$, 'permission denied', 'L6 student cannot INSERT into loans directly');
select t.fails($$update public.loans set due_at=now()+interval '999 days'$$, 'permission denied', 'L7 student cannot UPDATE loans directly (deadlines are protected)');
select t.fails($$delete from public.loans$$, 'permission denied', 'L8 student cannot DELETE loans directly');
select t.ok(not exists (select 1 from pg_class c cross join lateral aclexplode(coalesce(c.relacl, acldefault('r',c.relowner))) a where c.oid='public.loans'::regclass and a.grantee=0 and a.privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE')), 'L8b PUBLIC has no direct write privileges on loans');
select t.ok(t.affected($$update public.books set total_quantity=99$$)=0, 'L9 student cannot change books');
select t.ok(t.affected($$delete from public.books$$)=0, 'L10 student cannot delete books');
select t.fails($$update public.profiles set role='admin' where id='00000000-0000-0000-0000-0000000000b1'$$, 'Only an existing administrator', 'L11 student cannot promote themselves');
select t.ok((select count(*) from public.profiles)=1, 'L12 student sees only their own profile');
:as_anon
select t.fails($$select public.admin_create_loan('00000000-0000-0000-0000-0000000000b1','11111111-1111-1111-1111-111111111111')$$, 'permission denied', 'L13 anon cannot call admin_create_loan');
select t.fails($$select public.admin_return_loan('11111111-1111-1111-1111-111111111111')$$, 'permission denied', 'L14 anon cannot call admin_return_loan');
select t.fails($$select * from public.admin_search_students('')$$, 'permission denied', 'L15 anon cannot call admin_search_students');
select t.fails($$select public.borrow_book('11111111-1111-1111-1111-111111111111')$$, 'permission denied', 'L16 anon cannot call borrow_book');
select t.fails($$select * from public.get_library_clock()$$, 'permission denied', 'L17 anon cannot call get_library_clock');
select t.fails($$insert into public.loans(book_id,student_id,book_title,due_at) values('11111111-1111-1111-1111-111111111111','00000000-0000-0000-0000-0000000000b1','x',now())$$, 'permission denied', 'L18 anon cannot INSERT into loans');
:as_admin
select t.fails($$insert into public.loans(book_id,student_id,book_title,due_at) values('11111111-1111-1111-1111-111111111111','00000000-0000-0000-0000-0000000000b1','x',now())$$, 'permission denied', 'L19 even an admin cannot INSERT loans around the functions');
select t.fails($$update public.loans set returned_at=now()$$, 'permission denied', 'L20 even an admin cannot UPDATE loans around the functions');
select t.fails($$delete from public.loans$$, 'permission denied', 'L21 even an admin cannot DELETE loan history');
select t.fails($$select public.borrow_book('11111111-1111-1111-1111-111111111111')$$, 'permission denied', 'L22 old borrow_book is closed to everyone');

-- ---------------------------------------------------------------- 3. student search
:as_admin
select t.ok((select count(*) from public.admin_search_students(''))=3, 'S1 search returns the 3 students and no admins');
select t.ok((select count(*) from public.admin_search_students('amina'))=1, 'S2 search by name');
select t.ok((select count(*) from public.admin_search_students('BEKELE@t'))=1, 'S3 search by email, case-insensitive');
select t.ok((select count(*) from public.admin_search_students('%'))=1, 'S4 percent sign is escaped, not a wildcard');
select t.ok((select count(*) from public.admin_search_students('_'))=1, 'S5 underscore is escaped, not a wildcard');
select t.ok((select count(*) from public.admin_search_students('', 1))=1, 'S6 limit is honoured');
select t.ok((select count(*) from public.admin_search_students('admin'))=0, 'S7 admins never appear as lendable students');

-- ---------------------------------------------------------------- 4. catalogue loans
:as_super
create table t.snap_updated as select updated_at from public.books where id='11111111-1111-1111-1111-111111111111';
:as_admin
select t.works($$select public.admin_create_loan('00000000-0000-0000-0000-0000000000b1','11111111-1111-1111-1111-111111111111')$$, 'C1 librarian records a catalogue loan for Amina');
:as_super
select t.ok((select book_source='catalogue' and book_title='Chemistry 11' and book_author='Smith' and book_id='11111111-1111-1111-1111-111111111111' and created_by='00000000-0000-0000-0000-0000000000a1' and returned_at is null from public.loans where student_id='00000000-0000-0000-0000-0000000000b1'), 'C2 loan stores catalogue snapshot + who recorded it');
select t.ok((select due_at - borrowed_at = interval '72 hours' from public.loans where student_id='00000000-0000-0000-0000-0000000000b1'), 'C3 due date is exactly 72 hours after the SERVER borrow time');
select t.ok((select abs(extract(epoch from now()-borrowed_at)) < 10 from public.loans where student_id='00000000-0000-0000-0000-0000000000b1'), 'C4 borrow time comes from the database clock');
select t.ok((select updated_at > (select updated_at from t.snap_updated) from public.books where id='11111111-1111-1111-1111-111111111111'), 'C5 loan change touches the book row (Realtime signal for availability)');
:as_s1
select t.ok((select count(*) from public.loans)=1, 'C6 Amina sees her loan');
:as_s2
select t.ok((select count(*) from public.loans)=0, 'C7 Bekele cannot see Amina''s loan');
select t.ok((select available from public.get_book_availability() where book_id='11111111-1111-1111-1111-111111111111')=1, 'C8 other students see TRUE availability (2 copies - 1 on loan = 1)');
:as_admin
select t.fails($$select public.admin_create_loan('00000000-0000-0000-0000-0000000000b1','11111111-1111-1111-1111-111111111111')$$, 'already has an active loan', 'C9 same student cannot hold the same book twice');
select t.works($$select public.admin_create_loan('00000000-0000-0000-0000-0000000000b2','11111111-1111-1111-1111-111111111111')$$, 'C10 a different student can borrow the second copy');
select t.fails($$select public.admin_create_loan('00000000-0000-0000-0000-0000000000b3','11111111-1111-1111-1111-111111111111')$$, 'No copies are currently available', 'C11 no lending beyond the number of copies');
select t.fails($$select public.admin_create_loan('00000000-0000-0000-0000-0000000000a2','33333333-3333-3333-3333-333333333333')$$, 'not a student account', 'C12 cannot lend to an admin account');
select t.fails($$select public.admin_create_loan('00000000-0000-0000-0000-0000000000f9','33333333-3333-3333-3333-333333333333')$$, 'Student not found', 'C13 unknown student rejected');
select t.fails($$select public.admin_create_loan('00000000-0000-0000-0000-0000000000b1','99999999-9999-9999-9999-999999999999')$$, 'Book not found', 'C14 unknown catalogue book rejected');
select t.fails($$select public.admin_create_loan('00000000-0000-0000-0000-0000000000b1','33333333-3333-3333-3333-333333333333','Typed Title')$$, 'not both', 'C15 catalogue book and manual details together rejected');
select t.fails($$select public.admin_create_loan(null,'33333333-3333-3333-3333-333333333333')$$, 'Choose a student', 'C16 student is required');

-- ---------------------------------------------------------------- 5. manual entries
:as_super
create table t.books_before as select count(*) n from public.books;
create table t.avail_before as select * from public.get_book_availability();
:as_admin
select t.works($$select public.admin_create_loan('00000000-0000-0000-0000-0000000000b1', null, '  Introduction   to Amharic ', ' Alemu  Tadesse ', '  ISBN-123 ')$$, 'M1 librarian records a MANUAL loan (title, author, identification number)');
:as_super
select t.ok((select book_id is null and book_source='manual' and book_title='Introduction to Amharic' and book_author='Alemu Tadesse' and book_identifier='ISBN-123' and due_at-borrowed_at=interval '72 hours' and created_by='00000000-0000-0000-0000-0000000000a1' from public.loans where book_source='manual'), 'M2 manual snapshot stored, whitespace normalised, null book_id, 72h server deadline');
select t.ok((select count(*) from public.books)=(select n from t.books_before), 'M3 manual entry did NOT create a catalogue book');
select t.ok(not exists (select 1 from public.get_book_availability() a join t.avail_before b using (book_id) where a.available<>b.available or a.total_quantity<>b.total_quantity or a.active_loans<>b.active_loans), 'M4 manual loans do not consume catalogue copies');
:as_s1
select t.ok((select count(*) from public.loans where book_title='Introduction to Amharic' and book_author='Alemu Tadesse' and book_identifier='ISBN-123')=1, 'M5 Amina sees the manual title, author and identifier in her history');
:as_s2
select t.ok((select count(*) from public.loans where book_source='manual')=0, 'M6 Bekele cannot see Amina''s manual loan');
:as_admin
select t.fails($$select public.admin_create_loan('00000000-0000-0000-0000-0000000000b1', null, 'introduction to amharic', null, 'isbn-123')$$, 'already has an active loan', 'M7 duplicate manual loan (same title + identifier, any case) rejected');
select t.works($$select public.admin_create_loan('00000000-0000-0000-0000-0000000000b1', null, 'Introduction to Amharic', null, 'ISBN-999')$$, 'M8 same title with a different identification number is a different book');
select t.fails($$select public.admin_create_loan('00000000-0000-0000-0000-0000000000b1', null, '   ')$$, 'Enter the book title', 'M9 blank title rejected');
select t.fails($$select public.admin_create_loan('00000000-0000-0000-0000-0000000000b1', null, repeat('x',201))$$, 'too long', 'M10 title over 200 characters rejected');
select t.fails($$select public.admin_create_loan('00000000-0000-0000-0000-0000000000b1', null, 'T', repeat('a',121))$$, 'too long', 'M11 author over 120 characters rejected');
select t.fails($$select public.admin_create_loan('00000000-0000-0000-0000-0000000000b1', null, 'T', null, repeat('9',65))$$, 'too long', 'M12 identification number over 64 characters rejected');
select t.works($$select public.admin_create_loan('00000000-0000-0000-0000-0000000000b2', null, 'ባዮሎጂ 12')$$, 'M13 non-Latin (Amharic) manual title accepted');
:as_s2
select t.ok((select count(*) from public.loans where book_title='ባዮሎጂ 12')=1, 'M14 student sees the non-Latin title exactly');

-- ---------------------------------------------------------------- 6. returns
:as_super
create table t.snap_loans as select id, md5(concat_ws('|',book_id,student_id,book_title,book_author,book_identifier,book_source,borrowed_at,due_at,created_by)) h from public.loans;
create table t.target as select id as loan_id from public.loans where student_id='00000000-0000-0000-0000-0000000000b1' and book_id='11111111-1111-1111-1111-111111111111';
grant select on t.target to anon, authenticated;
:as_s1
select t.fails($$select public.admin_return_loan((select loan_id from t.target))$$, 'Administrator access required', 'R1 student cannot return their own book');
:as_admin
select t.works($$select public.admin_return_loan((select loan_id from t.target))$$, 'R2 librarian records the return');
:as_super
select t.ok((select returned_at is not null and returned_by='00000000-0000-0000-0000-0000000000a1' and abs(extract(epoch from now()-returned_at))<10 from public.loans where id=(select loan_id from t.target)), 'R3 return time is the database clock and records the librarian');
select t.ok(not exists (select 1 from public.loans l join t.snap_loans s using (id) where md5(concat_ws('|',l.book_id,l.student_id,l.book_title,l.book_author,l.book_identifier,l.book_source,l.borrowed_at,l.due_at,l.created_by)) <> s.h), 'R4 a return changes nothing else in any loan record');
:as_admin
select t.fails($$select public.admin_return_loan((select loan_id from t.target))$$, 'already been returned', 'R5 cannot return twice');
select t.fails($$select public.admin_return_loan('99999999-9999-9999-9999-999999999999')$$, 'not found', 'R6 unknown loan rejected');
:as_s1
select t.ok((select returned_at is not null from public.loans where book_id='11111111-1111-1111-1111-111111111111'), 'R7 student sees that the book was returned');
:as_s2
select t.ok((select available from public.get_book_availability() where book_id='11111111-1111-1111-1111-111111111111')=1, 'R8 the returned copy is available again for everyone');
:as_admin
select t.works($$select public.admin_create_loan('00000000-0000-0000-0000-0000000000b1','11111111-1111-1111-1111-111111111111')$$, 'R9 after returning, the same student may borrow the same book again');

-- ---------------------------------------------------------------- 7. quantity guard
:as_admin
select t.works($$select public.admin_create_loan('00000000-0000-0000-0000-0000000000b1','33333333-3333-3333-3333-333333333333')$$, 'Q0a seed: Physics 12 loan 1');
select t.works($$select public.admin_create_loan('00000000-0000-0000-0000-0000000000b2','33333333-3333-3333-3333-333333333333')$$, 'Q0b seed: Physics 12 loan 2');
select t.works($$select public.admin_create_loan('00000000-0000-0000-0000-0000000000b3','33333333-3333-3333-3333-333333333333')$$, 'Q0c seed: Physics 12 loan 3');
select t.fails($$update public.books set total_quantity=2 where id='33333333-3333-3333-3333-333333333333'$$, 'currently on loan', 'Q1 cannot reduce quantity below active loans');
select t.works($$update public.books set total_quantity=3 where id='33333333-3333-3333-3333-333333333333'$$, 'Q2 quantity equal to active loans is allowed');
select t.works($$update public.books set total_quantity=5 where id='33333333-3333-3333-3333-333333333333'$$, 'Q3 quantity may be increased');
select t.works($$update public.books set title='Physics 12 (2nd ed.)' where id='33333333-3333-3333-3333-333333333333'$$, 'Q4 other edits are unaffected');
:as_super
select t.ok((select book_title from public.loans where student_id='00000000-0000-0000-0000-0000000000b1' and book_id='33333333-3333-3333-3333-333333333333')='Physics 12', 'Q5 renaming a book never rewrites the title recorded in a loan');
select t.ok((select updated_at>created_at from public.books where id='33333333-3333-3333-3333-333333333333'), 'Q6 books.updated_at is maintained');

-- ---------------------------------------------------------------- 8. book deletion
:as_admin
select t.fails($$delete from public.books where id='11111111-1111-1111-1111-111111111111'$$, 'borrowing history', 'X1 book with loan history cannot be deleted, with a clear message');
select t.fails($$delete from public.books where id='33333333-3333-3333-3333-333333333333'$$, 'currently on loan', 'X2 message reports active loans');
select t.works($$delete from public.books where id='44444444-4444-4444-4444-444444444444'$$, 'X3 a book without any loans can be deleted');

-- ---------------------------------------------------------------- 9. clock
:as_s1
select t.ok((select loan_hours=72 and due_soon_hours=24 and abs(extract(epoch from server_now-now()))<5 from public.get_library_clock()), 'K1 clock returns server time, 72h loan period, 24h due-soon window');

-- ---------------------------------------------------------------- 10. history preserved
:as_s1
select t.ok((select count(*) from public.loans)=5, 'H1 Amina''s full history (catalogue, manual x2, returned, re-borrowed, Physics) is intact');

:as_super
\o
\pset tuples_only off
select name, case when ok then 'PASS' else 'FAIL' end as result, coalesce(detail,'') as detail from t.results where not ok order by n;
select 'TOTAL '||count(*)||'  PASS '||count(*) filter (where ok)||'  FAIL '||count(*) filter (where not ok) as summary from t.results;
