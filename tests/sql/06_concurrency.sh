#!/usr/bin/env bash
# Two real database sessions racing. Usage: 06_concurrency.sh <database>   (uses PG* variables)
# Scratch-environment test, not a real Supabase project.
set -u
DB="$1"
A1=00000000-0000-0000-0000-0000000000a1
S1=00000000-0000-0000-0000-0000000000b1; S2=00000000-0000-0000-0000-0000000000b2; S3=00000000-0000-0000-0000-0000000000b3
CA=c1111111-1111-1111-1111-111111111111; CB=c2222222-2222-2222-2222-222222222222; CQ=c3333333-3333-3333-3333-333333333333
P=(psql -X -q -At -d "$DB" -v ON_ERROR_STOP=0)
bad=0
chk() { if [ "$2" = "$3" ]; then echo "  PASS $1"; else echo "  FAIL $1 (expected '$3', got '$2')"; bad=1; fi; }
has() { if grep -qi "$3" "$2"; then echo "  PASS $1"; else echo "  FAIL $1 (output lacked '$3'): $(tr '\n' ' ' <"$2")"; bad=1; fi; }
"${P[@]}" -c "insert into public.books(id,title,category,total_quantity) values ('$CA','Concurrent Atlas','Geo',1),('$CB','Concurrent Pair','Geo',5),('$CQ','Concurrent Qty','Geo',3)" >/dev/null
tx() { # pre-sleep hold-seconds sql outfile   (runs as librarian in one transaction)
  ( sleep "$1"; "${P[@]}" -c "begin; select set_config('request.jwt.claim.sub','$A1',true); set local role authenticated; $3 select pg_sleep($2); commit;" >"$4" 2>&1 ) & }

# 1. Two librarians lend the LAST copy to two different students at once.
tx 0 3 "select public.admin_create_loan('$S1','$CA');" /tmp/cc_x1.out
tx 1 0 "select public.admin_create_loan('$S2','$CA');" /tmp/cc_y1.out
wait
chk "last copy lent exactly once" "$("${P[@]}" -c "select count(*) from public.loans where book_id='$CA' and returned_at is null")" 1
has "the losing librarian is told no copies remain" /tmp/cc_y1.out "No copies are currently available"

# 2. Two librarians lend the same book to the same student at once.
tx 0 3 "select public.admin_create_loan('$S3','$CB');" /tmp/cc_x2.out
tx 1 0 "select public.admin_create_loan('$S3','$CB');" /tmp/cc_y2.out
wait
chk "no duplicate active loan from a race" "$("${P[@]}" -c "select count(*) from public.loans where student_id='$S3' and book_id='$CB' and returned_at is null")" 1
has "the second request is rejected as a duplicate" /tmp/cc_y2.out "already has an active loan"

# 3. A loan is recorded while another librarian lowers the quantity below the new active count.
"${P[@]}" -c "begin; select set_config('request.jwt.claim.sub','$A1',true); set local role authenticated; select public.admin_create_loan('$S1','$CQ'); commit;" >/dev/null 2>&1
tx 0 3 "select public.admin_create_loan('$S2','$CQ');" /tmp/cc_x3.out
tx 1 0 "update public.books set total_quantity=1 where id='$CQ';" /tmp/cc_y3.out
wait
chk "both loans recorded" "$("${P[@]}" -c "select count(*) from public.loans where book_id='$CQ' and returned_at is null")" 2
chk "quantity not lowered below the active loans" "$("${P[@]}" -c "select total_quantity from public.books where id='$CQ'")" 3
has "quantity reduction rejected after the loan committed" /tmp/cc_y3.out "currently on loan"

# 4. Two librarians record the same MANUAL book for the same student at once.
tx 0 3 "select public.admin_create_loan('$S1', null, 'Race Manual Title', null, 'RM-1');" /tmp/cc_x4.out
tx 1 0 "select public.admin_create_loan('$S1', null, 'race manual title', null, 'rm-1');" /tmp/cc_y4.out
wait
chk "no duplicate manual loan from a race" "$("${P[@]}" -c "select count(*) from public.loans where student_id='$S1' and lower(book_title)='race manual title' and returned_at is null")" 1
has "the second manual request is rejected as a duplicate" /tmp/cc_y4.out "already has an active loan"

# 5. A mistaken return is undone while another librarian lends the same single copy.
CD=c4444444-4444-4444-4444-444444444444
"${P[@]}" -c "insert into public.books(id,title,category,total_quantity) values ('$CD','Concurrent Undo','Geo',1)" >/dev/null
"${P[@]}" -c "begin; select set_config('request.jwt.claim.sub','$A1',true); set local role authenticated; select public.admin_create_loan('$S1','$CD'); commit;" >/dev/null 2>&1
LID=$("${P[@]}" -c "select id from public.loans where student_id='$S1' and book_id='$CD'")
"${P[@]}" -c "begin; select set_config('request.jwt.claim.sub','$A1',true); set local role authenticated; select public.admin_return_loan('$LID'); commit;" >/dev/null 2>&1
tx 0 3 "select public.admin_correct_loan('$LID','undo_return','Reopened after a mistaken return');" /tmp/cc_x5.out
tx 1 0 "select public.admin_create_loan('$S2','$CD');" /tmp/cc_y5.out
wait
chk "undo-return vs new loan: exactly one active loan for the single copy" "$("${P[@]}" -c "select count(*) from public.loans where book_id='$CD' and returned_at is null")" 1
has "the second librarian is told no copies remain" /tmp/cc_y5.out "No copies are currently available"
if grep -qi "deadlock" /tmp/cc_x5.out /tmp/cc_y5.out; then echo "  FAIL a deadlock occurred"; bad=1; else echo "  PASS no deadlock between return/correction/lending locks"; fi
exit $bad
