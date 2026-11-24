-- Upgrade scenario: a database created by the FINAL setup script, with legacy borrowing history
-- written by the old student-borrowing app (including duplicates and over-lending). Then 001 + 002.
-- Part A (this file, before migrations): seed and snapshot.
\set ON_ERROR_STOP off
\pset tuples_only on
\o /dev/null
\ir helpers.sql
insert into auth.users(id,email,raw_user_meta_data) values
 ('00000000-0000-0000-0000-0000000000a1','admin@t.test','{"display_name":"Lib Admin"}'),
 ('00000000-0000-0000-0000-0000000000b1','amina@t.test','{"display_name":"Amina"}'),
 ('00000000-0000-0000-0000-0000000000b2','bekele@t.test','{"display_name":"Bekele"}'),
 ('00000000-0000-0000-0000-0000000000b3','chaltu@t.test','{"display_name":"Chaltu"}');
update public.profiles set role='admin' where email='admin@t.test';
insert into public.books(id,title,author,category,total_quantity) values
 ('11111111-1111-1111-1111-111111111111','Chemistry 11','Smith','Chem',3),
 ('22222222-2222-2222-2222-222222222222','Rare Atlas','','Geo',1),
 ('33333333-3333-3333-3333-333333333333','Physics 12','Jones','Phys',3);
-- legacy rows (old columns only), exactly what the old app/RPC produced, plus legacy anomalies
insert into public.loans(id,book_id,student_id,book_title,borrowed_at,due_at,returned_at) values
 ('a0000000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','00000000-0000-0000-0000-0000000000b1','Chemistry 11', now()-interval '2 days', now()+interval '1 day', null),
 ('a0000000-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','00000000-0000-0000-0000-0000000000b1','Chemistry 11', now()-interval '1 day',  now()+interval '2 days', null),   -- duplicate active loan
 ('a0000000-0000-0000-0000-000000000003','22222222-2222-2222-2222-222222222222','00000000-0000-0000-0000-0000000000b2','Rare Atlas',   now()-interval '5 days', now()-interval '2 days', null),   -- overdue
 ('a0000000-0000-0000-0000-000000000004','22222222-2222-2222-2222-222222222222','00000000-0000-0000-0000-0000000000b3','Rare Atlas',   now()-interval '1 day',  now()+interval '2 days', null),   -- over-lent (2 active, 1 copy)
 ('a0000000-0000-0000-0000-000000000005','33333333-3333-3333-3333-333333333333','00000000-0000-0000-0000-0000000000b1','Physics 12',   now()-interval '9 days', now()-interval '6 days', now()-interval '6 days');  -- returned
create table t.legacy_snap as select id, md5(concat_ws('|',book_id,student_id,book_title,borrowed_at,due_at,returned_at)) h from public.loans;
create table t.legacy_count as select count(*) n from public.loans;
\o
