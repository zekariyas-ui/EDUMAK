-- Part C: after returning the duplicate and re-running 002, the unique index is created.
\set ON_ERROR_STOP off
\pset tuples_only on
\o /dev/null
\ir macros.sql
:as_super
select t.ok(exists (select 1 from pg_indexes where indexname='loans_one_active_per_student_book'), 'V1 re-running 002 after the duplicate was returned creates the unique index');
select t.ok(not exists (select 1 from public.loans l join t.legacy_snap s using (id) where l.id<>'a0000000-0000-0000-0000-000000000002' and l.id<>'a0000000-0000-0000-0000-000000000003' and md5(concat_ws('|',l.book_id,l.student_id,l.book_title,l.borrowed_at,l.due_at,l.returned_at)) <> s.h), 'V2 untouched legacy loans remain identical after the second run');
\o
\pset tuples_only off
select name, 'FAIL' as result, coalesce(detail,'') as detail from t.results where not ok and name like 'V%' order by n;
select 'LEGACY RERUN: '||count(*) filter (where name like 'V%')||' checks, FAIL '||count(*) filter (where not ok and name like 'V%') as summary from t.results;
