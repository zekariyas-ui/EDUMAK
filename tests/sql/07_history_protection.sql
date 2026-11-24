-- Loan history protection and audited corrections (scratch Postgres, NOT a real Supabase project).
-- Runs in the main test database after 003 was applied. Many checks run as the SUPERUSER on purpose:
-- the protection must hold even for the database owner's ordinary SQL (not only for API roles).
\set ON_ERROR_STOP off
\pset tuples_only on
\o /dev/null
\ir macros.sql
:as_super
create table t.h_start as select coalesce(max(n),0) as n from t.results;
insert into auth.users(id,email,raw_user_meta_data) values ('00000000-0000-0000-0000-0000000000a3','admin3@t.test','{"display_name":"Third Admin"}');
update public.profiles set role='admin' where email='admin3@t.test';
insert into public.books(id,title,author,category,total_quantity) values
 ('55555555-5555-5555-5555-555555555555','HP One','','Misc',1),
 ('66666666-6666-6666-6666-666666666666','HP Two','','Misc',2);
:as_admin
select public.admin_create_loan('00000000-0000-0000-0000-0000000000b2','55555555-5555-5555-5555-555555555555');
select public.admin_create_loan('00000000-0000-0000-0000-0000000000b2',null,'Fix Me Title','Typoo','ID-1');
select public.admin_create_loan('00000000-0000-0000-0000-0000000000b3','66666666-6666-6666-6666-666666666666');
:as_super
create table t.h as select
 (select id from public.loans where student_id='00000000-0000-0000-0000-0000000000b2' and book_id='55555555-5555-5555-5555-555555555555') as la,
 (select id from public.loans where student_id='00000000-0000-0000-0000-0000000000b2' and book_title='Fix Me Title') as lb,
 (select id from public.loans where student_id='00000000-0000-0000-0000-0000000000b3' and book_id='66666666-6666-6666-6666-666666666666') as lc;
grant select on t.h to anon, authenticated;
select t.ok(not exists (select 1 from pg_class c cross join lateral aclexplode(coalesce(c.relacl, acldefault('r',c.relowner))) a where c.oid='public.loan_corrections'::regclass and a.grantee=0 and a.privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE','SELECT')), 'HA0 PUBLIC has no direct access to the audit table');
create table t.h_snap as select id, md5(concat_ws('|',book_id,student_id,book_title,book_author,book_identifier,book_source,borrowed_at,due_at,created_by,created_at)) as h, borrowed_at, due_at from public.loans;
create table t.all_before as select id, md5(l::text) as h from public.loans l;

-- ------------------------------------------------ protection (superuser SQL)
select t.fails($$update public.loans set due_at=due_at+interval '1 day' where id=(select la from t.h)$$, 'never be changed', 'HP1 the deadline cannot be edited, even by the database owner');
select t.fails($$update public.loans set student_id='00000000-0000-0000-0000-0000000000b3' where id=(select la from t.h)$$, 'never be changed', 'HP2 the student cannot be changed');
select t.fails($$update public.loans set borrowed_at=borrowed_at-interval '1 day' where id=(select la from t.h)$$, 'never be changed', 'HP3 the borrow time cannot be changed');
select t.fails($$update public.loans set book_id='66666666-6666-6666-6666-666666666666' where id=(select la from t.h)$$, 'never be changed', 'HP4 the catalogue book cannot be swapped');
select t.fails($$update public.loans set book_title='Changed' where id=(select la from t.h)$$, 'cannot be edited', 'HP5 the recorded title cannot be silently edited');
select t.fails($$update public.loans set returned_at='2020-01-01' where id=(select la from t.h)$$, 'cannot be edited', 'HP6 a return cannot be back-dated');
select t.fails($$update public.loans set returned_at=now() where id=(select la from t.h)$$, 'cannot be edited', 'HP7 a return without a recorded librarian is not the authorized return');
select t.fails($$update public.loans set returned_at='2020-01-01', returned_by='00000000-0000-0000-0000-0000000000a1' where id=(select la from t.h)$$, 'cannot be edited', 'HP14 a return WITH a librarian but a back-dated time is still refused (return time must be database now)');
select t.fails($$update public.loans set created_by='00000000-0000-0000-0000-0000000000a2' where id=(select la from t.h)$$, 'Who recorded', 'HP8 who recorded a loan cannot be changed');
select t.fails($$delete from public.loans where id=(select la from t.h)$$, 'cannot be deleted', 'HP9 a loan cannot be deleted');
select t.fails($$delete from public.loans$$, 'cannot be deleted', 'HP10 loan history cannot be bulk deleted');
select t.fails($$truncate public.loans cascade$$, 'truncated', 'HP11 loan history cannot be truncated');
select t.ok(not exists (select 1 from public.loans l join t.all_before b using (id) where md5(l::text) <> b.h), 'HP12 none of the rejected attempts changed a single loan row');

-- ------------------------------------------------ the authorized return still works
:as_admin
select t.works($$select public.admin_return_loan((select la from t.h))$$, 'HR1 the authorized return (admin_return_loan) still works');
:as_super
select t.ok((select returned_at is not null and returned_by='00000000-0000-0000-0000-0000000000a1' and abs(extract(epoch from now()-returned_at))<10 from public.loans where id=(select la from t.h)), 'HR2 the return records the librarian and the database time');
select t.ok(not exists (select 1 from public.loans l join t.h_snap s using (id) where md5(concat_ws('|',l.book_id,l.student_id,l.book_title,l.book_author,l.book_identifier,l.book_source,l.borrowed_at,l.due_at,l.created_by,l.created_at)) <> s.h), 'HR3 the return changed nothing else in any loan');
select t.works($$update public.loans set returned_at=now(), returned_by='00000000-0000-0000-0000-0000000000a1' where id=(select lc from t.h)$$, 'HR4 the authorized-return shape is the only direct update the database accepts');
select t.fails($$update public.loans set returned_at=null, returned_by=null where id=(select la from t.h)$$, 'cannot be edited', 'HP13 a return cannot be silently undone');

-- ------------------------------------------------ audited corrections
:as_s2
select t.fails($$select public.admin_correct_loan((select la from t.h),'undo_return','A student attempt')$$, 'Administrator access required', 'HC1 a student cannot correct loans');
:as_anon
select t.fails($$select public.admin_correct_loan('99999999-9999-9999-9999-999999999999','undo_return','An anonymous attempt')$$, 'permission denied', 'HC2 anonymous users cannot correct loans');
:as_admin
select t.fails($$select public.admin_correct_loan((select la from t.h),'undo_return','short')$$, 'at least 10', 'HC3 a written reason is mandatory');
select t.fails($$select public.admin_correct_loan((select la from t.h),'delete_it','A long enough reason here')$$, 'Unknown correction type', 'HC4 only the defined correction kinds exist (there is no delete)');
select t.fails($$select public.admin_correct_loan('99999999-9999-9999-9999-999999999999','undo_return','A long enough reason here')$$, 'not found', 'HC5 unknown loan rejected');
select t.fails($$select public.admin_correct_loan((select lb from t.h),'undo_return','This manual loan is still active')$$, 'not been returned', 'HC6 cannot undo a return that never happened');
select t.works($$select public.admin_create_loan('00000000-0000-0000-0000-0000000000b3','55555555-5555-5555-5555-555555555555')$$, 'HC7 seed: another student borrows the single freed copy');
select t.fails($$select public.admin_correct_loan((select la from t.h),'undo_return','Returned by mistake yesterday')$$, 'No copy is free', 'HC8 a return cannot be undone while no copy is free');
select t.works($$select public.admin_return_loan((select id from public.loans where student_id='00000000-0000-0000-0000-0000000000b3' and book_id='55555555-5555-5555-5555-555555555555' and returned_at is null))$$, 'HC9 seed: the competing loan is returned');
select t.works($$select public.admin_correct_loan((select la from t.h),'undo_return','Returned by mistake yesterday')$$, 'HC10 audited undo of a mistaken return');
:as_super
select t.ok((select l.returned_at is null and l.returned_by is null and md5(concat_ws('|',l.book_id,l.student_id,l.book_title,l.book_author,l.book_identifier,l.book_source,l.borrowed_at,l.due_at,l.created_by,l.created_at)) = s.h from public.loans l join t.h_snap s using (id) where l.id=(select la from t.h)), 'HC11 the undo restored the loan with its ORIGINAL deadline and details');
select t.ok((select count(*)=1 and bool_and(kind='undo_return' and reason='Returned by mistake yesterday' and corrected_by='00000000-0000-0000-0000-0000000000a1' and corrected_by_email='admin@t.test' and old_values->>'returned_at' is not null and old_values->>'returned_by'='00000000-0000-0000-0000-0000000000a1' and new_values->>'returned_at' is null and new_values->>'returned_by' is null) from public.loan_corrections where loan_id=(select la from t.h)), 'HC12 permanent audit row: who, why, old and new values');
select t.ok((select available from public.get_book_availability() where book_id='55555555-5555-5555-5555-555555555555')=0, 'HC13 availability reflects the reopened loan');
:as_admin
select t.fails($$select public.admin_correct_loan((select lc from t.h),'edit_manual_details','Trying this on a catalogue loan','X')$$, 'Only manually entered', 'HE1 catalogue loans cannot have their details edited');
select t.fails($$select public.admin_correct_loan((select lb from t.h),'edit_manual_details','Blank title attempt here','   ')$$, 'cannot be blank', 'HE2 a blank title is rejected');
select t.fails($$select public.admin_correct_loan((select lb from t.h),'edit_manual_details','Nothing actually changes here')$$, 'Nothing to correct', 'HE3 a no-op correction is rejected');
select t.works($$select public.admin_create_loan('00000000-0000-0000-0000-0000000000b2',null,'Other Title')$$, 'HE4 seed: a second manual loan');
select t.fails($$select public.admin_correct_loan((select lb from t.h),'edit_manual_details','Would duplicate the other loan','other title',null,'')$$, 'already has an active loan', 'HE5 a correction cannot create a duplicate active loan');
select t.works($$select public.admin_correct_loan((select lb from t.h),'edit_manual_details','Fix the typo and clear the wrong ID','Fixed Title',null,'')$$, 'HE6 audited correction of a manual title typo');
:as_super
select t.ok((select book_title='Fixed Title' and book_author='Typoo' and book_identifier is null and book_source='manual' and l.borrowed_at=s.borrowed_at and l.due_at=s.due_at from public.loans l join t.h_snap s using (id) where l.id=(select lb from t.h)), 'HE7 only the corrected fields changed; dates and deadline are untouched');
select t.ok((select count(*)=1 and bool_and(old_values->>'book_title'='Fix Me Title' and new_values->>'book_title'='Fixed Title' and old_values->>'book_identifier'='ID-1' and new_values->>'book_identifier' is null and old_values->>'book_author'='Typoo') from public.loan_corrections where loan_id=(select lb from t.h)), 'HE8 the audit row keeps the old and the new values');
:as_s2
select t.ok((select count(*) from public.loans where book_title='Fixed Title')=1, 'HE9 the student sees the corrected title');
select t.ok((select count(*) from public.loan_corrections)=0, 'HA6 students cannot read the audit log');
:as_anon
select t.fails($$select count(*) from public.loan_corrections$$, 'permission denied', 'HA7 anonymous users cannot read the audit log');

-- ------------------------------------------------ audit rows are permanent
:as_super
select t.fails($$update public.loan_corrections set reason='tampered reason text'$$, 'cannot be changed', 'HA1 audit rows cannot be edited (even by the database owner)');
select t.fails($$delete from public.loan_corrections$$, 'cannot be changed', 'HA2 audit rows cannot be deleted');
select t.fails($$truncate public.loan_corrections$$, 'truncated', 'HA3 the audit log cannot be truncated');
:as_admin
select t.ok((select count(*) from public.loan_corrections where loan_id in ((select la from t.h),(select lb from t.h)))=2 and (select count(*) from public.loan_corrections)>=2, 'HA4 an admin can read the audit log');
select t.fails($$insert into public.loan_corrections(loan_id,kind,reason,old_values,new_values,corrected_by) values ((select la from t.h),'undo_return','forged audit row attempt','{}','{}','00000000-0000-0000-0000-0000000000a1')$$, 'permission denied', 'HA5 even an admin cannot write audit rows directly');

-- ------------------------------------------------ deleting a librarian account keeps the history
reset role; set role authenticated; select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000a3',false);
select public.admin_create_loan('00000000-0000-0000-0000-0000000000b1','66666666-6666-6666-6666-666666666666');
select public.admin_return_loan((select id from public.loans where student_id='00000000-0000-0000-0000-0000000000b1' and book_id='66666666-6666-6666-6666-666666666666'));
:as_super
create table t.h2 as select id, md5(concat_ws('|',book_id,student_id,book_title,book_author,book_identifier,book_source,borrowed_at,due_at,returned_at,created_at)) as h from public.loans where created_by='00000000-0000-0000-0000-0000000000a3';
select t.ok((select count(*) from t.h2)=1, 'HF0 seed: a loan recorded and returned by the third librarian');
select t.works($$delete from auth.users where id='00000000-0000-0000-0000-0000000000a3'$$, 'HF1 a librarian account can be deleted');
select t.ok((select l.created_by is null and l.returned_by is null and md5(concat_ws('|',l.book_id,l.student_id,l.book_title,l.book_author,l.book_identifier,l.book_source,l.borrowed_at,l.due_at,l.returned_at,l.created_at))=h2.h from public.loans l join t.h2 h2 using (id)), 'HF2 the loan survives; only the librarian references were emptied; every other column is identical');
select t.fails($$update public.loans set created_by='00000000-0000-0000-0000-0000000000a1' where id=(select id from t.h2)$$, 'Who recorded', 'HF3 a recorder cannot be re-attached afterwards either');

\o
\pset tuples_only off
select name, 'FAIL' as result, coalesce(detail,'') as detail from t.results where not ok and n > (select n from t.h_start) order by n;
select 'HISTORY TOTAL '||count(*)||'  PASS '||count(*) filter (where ok)||'  FAIL '||count(*) filter (where not ok) as summary from t.results where n > (select n from t.h_start);
