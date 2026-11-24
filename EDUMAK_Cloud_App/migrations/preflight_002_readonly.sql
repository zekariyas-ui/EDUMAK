-- EDUMAK preflight for migration 002. READ ONLY: this script changes nothing.
-- Run it in Supabase Dashboard > SQL Editor BEFORE migration 002 and review every row.

select 'total loans' as check_name, count(*)::text as result from public.loans
union all select 'active (unreturned) loans', count(*)::text from public.loans where returned_at is null
union all select 'student/book pairs with more than one ACTIVE loan (if > 0 the unique index is skipped with a warning)',
  count(*)::text from (select 1 from public.loans where returned_at is null and book_id is not null group by student_id, book_id having count(*) > 1) d
union all select 'books with more active loans than total_quantity (quantity guard will block lowering them)',
  count(*)::text from (select b.id from public.books b join public.loans l on l.book_id = b.id and l.returned_at is null
                       group by b.id, b.total_quantity having count(*) > b.total_quantity) x
union all select 'loans whose book_title is longer than 200 characters (informational; constraint is NOT VALID)',
  count(*)::text from public.loans where char_length(book_title) > 200
union all select 'loans with NULL book_id (expected 0 before migration)', count(*)::text from public.loans where book_id is null
union all select 'student accounts', count(*)::text from public.profiles where role = 'student'
union all select 'administrator accounts', count(*)::text from public.profiles where role = 'admin'
union all select 'migration history table already exists', (to_regclass('public.edumak_schema_migrations') is not null)::text;

-- Detail: any duplicate active loans (student, book, how many).
select student_id, book_id, max(book_title) as book_title, count(*) as active_loans
from public.loans where returned_at is null and book_id is not null
group by student_id, book_id having count(*) > 1;
