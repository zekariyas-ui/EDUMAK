'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { createEnv, boot, settle, iso } = require('./harness');

const H = 3600 * 1000;
const S1 = 's1', S2 = 's2';
const studentSession = { user: { id: S1, role: 'student', email: 's1@t.test' } };
const adminSession = { user: { id: 'a1', role: 'admin', email: 'a1@t.test' } };
const profiles = [
  { id: S1, email: 's1@t.test', display_name: 'Amina Student', role: 'student', created_at: iso(Date.now() - 99 * H) },
  { id: S2, email: 's2@t.test', display_name: 'Bekele Student', role: 'student', created_at: iso(Date.now() - 98 * H) },
  { id: 'a1', email: 'a1@t.test', display_name: 'Librarian', role: 'admin', created_at: iso(Date.now() - 100 * H) },
];
const books = [
  { id: 'B1', title: 'Chemistry 11', author: 'Smith', category: 'Chem', description: '', total_quantity: 3 },
  { id: 'B2', title: 'Rare Atlas', author: '', category: 'Geo', description: '', total_quantity: 1 },
];
function loan(over) {
  return Object.assign({ id: 'L' + Math.random().toString(36).slice(2, 8), student_id: S1, book_id: 'B1', book_title: 'Chemistry 11', book_author: 'Smith',
    book_identifier: null, book_source: 'catalogue', borrowed_at: iso(Date.now() - 2 * H), due_at: iso(Date.now() + 60 * H), returned_at: null }, over);
}
function studentEnv(extraLoans, opts = {}) {
  const t = Date.now();
  const loans = extraLoans || [
    loan({ id: 'L-active', book_title: 'Active Book', due_at: iso(t + 60 * H) }),
    loan({ id: 'L-soon', book_title: 'Due Soon Book', due_at: iso(t + 10 * H) }),
    loan({ id: 'L-over', book_title: 'Overdue Book', due_at: iso(t - 5 * H) }),
    loan({ id: 'L-ret', book_title: 'Returned Book', due_at: iso(t - 30 * H), returned_at: iso(t - 2 * H) }),
    loan({ id: 'L-man', book_id: null, book_source: 'manual', book_title: 'Manual Title', book_author: 'Alemu', book_identifier: 'ISBN-9', due_at: iso(t + 48 * H) }),
    loan({ id: 'L-other', student_id: S2, book_title: "Someone Else's Book" }),
  ];
  const env = createEnv(Object.assign({ session: studentSession, tables: { books, loans, profiles } }, opts));
  env.activeByBook = { B1: 2, B2: 1 };
  return env;
}
const item = (a, id) => a.doc.querySelector(`.activity-item[data-loan="${id}"]`);

// ------------------------------------------------------------------ student view
test('student: read-only view with status, dates, manual snapshot and no other student records', async () => {
  const a = await boot(studentEnv());
  assert.equal(a.all('.activity-item').length, 5, 'own 5 loans only');
  assert.ok(!a.text('activityList').includes("Someone Else's Book"), 'other student record not shown');
  assert.match(item(a, 'L-active').querySelector('.pill.status').className, /\bactive\b/);
  assert.match(item(a, 'L-soon').querySelector('.pill.status').className, /\bdue-soon\b/);
  assert.match(item(a, 'L-over').querySelector('.pill.status').className, /\boverdue\b/);
  assert.match(item(a, 'L-ret').querySelector('.pill.status').className, /\breturned\b/);
  assert.equal(item(a, 'L-soon').querySelector('.pill.status').textContent, 'Due soon');
  assert.match(item(a, 'L-soon').querySelector('.countdown').textContent, /^(09:5\d|10:00):\d\d left$/);
  assert.match(item(a, 'L-over').querySelector('.countdown').textContent, /^Overdue by 0[45]:\d\d:\d\d$/);
  assert.match(item(a, 'L-ret').textContent, /Returned: /, 'return date shown');
  assert.equal(item(a, 'L-ret').querySelector('.countdown'), null, 'no countdown for returned books');
  const man = item(a, 'L-man').textContent;
  assert.ok(man.includes('Manual Title') && man.includes('Alemu') && man.includes('ISBN-9') && man.includes('Entered by the librarian'), 'manual snapshot visible to the student');
  a.close();
});

test('student: no borrow or return controls anywhere, and no write calls to loans', async () => {
  const a = await boot(studentEnv());
  assert.equal(a.all('[data-borrow],[data-return],[data-return-loan],[data-correct-undo],[data-correct-edit]').length, 0);
  const labels = a.all('button').map(b => b.textContent.trim()).join('|');
  assert.ok(!/Borrow free|Return book|Record return|Record borrowing/i.test(a.all('.page.active button, #activityList button, #borrowList button').map(b => b.textContent).join('|')), labels);
  assert.equal(a.$('adminPanel').classList.contains('hidden'), true, 'lending desk panel is hidden for students');
  assert.equal(a.env.calls.filter(c => c.kind === 'from' && c.table === 'loans' && c.op !== 'select').length, 0);
  assert.equal(a.env.calls.filter(c => c.kind === 'rpc' && /borrow_book|return_book|admin_/.test(c.name)).length, 0);
  assert.match(a.text('borrow'), /lent and returned by the librarian/i);
  a.close();
});

test('availability comes from the server aggregate, not from the visible loans', async () => {
  const a = await boot(studentEnv());
  const cards = a.all('#bookList .book-card').map(c => c.textContent);
  assert.ok(cards.find(t => t.includes('Chemistry 11') && t.includes('1 available') && t.includes('On loan: 2')), cards.join(' | '));
  assert.ok(cards.find(t => t.includes('Rare Atlas') && t.includes('0 available')));
  assert.equal(a.text('statAvailable'), '1');
  a.close();
});

test('guest: sees availability, no loan or clock queries, no private data', async () => {
  const env = studentEnv(); env.session = null;
  const a = await boot(env);
  assert.ok(a.all('#bookList .book-card').some(c => c.textContent.includes('1 available')));
  assert.equal(env.callsTo('from', 'loans').length, 0);
  assert.equal(env.callsTo('rpc', 'get_library_clock').length, 0);
  assert.equal(env.callsTo('rpc', 'get_book_availability').length, 1);
  assert.equal(a.text('statLoans'), '-');
  a.close();
});

// ------------------------------------------------------------------ server time and live countdown
test('countdown uses server time: a device clock 3 hours AHEAD or 30 hours BEHIND does not change the result', async () => {
  for (const skew of [3 * H, -30 * H]) {
    const a = await boot(studentEnv(null, { skew }));
    assert.match(item(a, 'L-soon').querySelector('.countdown').textContent, /^(09:5\d|10:00):\d\d left$/, 'skew ' + skew);
    assert.match(item(a, 'L-over').querySelector('.pill.status').className, /overdue/, 'skew ' + skew);
    assert.match(item(a, 'L-active').querySelector('.pill.status').className, /\bactive\b/, 'skew ' + skew);
    a.close();
  }
});

test('status label, colour and text update live as a deadline passes (active -> due soon -> overdue)', async () => {
  const t = Date.now();
  const env = studentEnv([loan({ id: 'L-x', book_title: 'Live Book', due_at: iso(t + 24 * H + 30000) })]);
  const a = await boot(env);
  const pill = () => item(a, 'L-x').querySelector('.pill.status');
  const cd = () => item(a, 'L-x').querySelector('.countdown');
  assert.equal(pill().textContent, 'Active');
  env.advance(31000); a.tick();
  assert.equal(pill().textContent, 'Due soon'); assert.match(pill().className, /due-soon/); assert.match(cd().className, /due-soon/);
  env.advance(24 * H); a.tick();
  assert.equal(pill().textContent, 'Overdue'); assert.match(pill().className, /overdue/);
  assert.match(cd().textContent, /^Overdue by /);
  a.close();
});

test('the loan-period and due-soon window come from the database policy', async () => {
  const env = studentEnv([loan({ id: 'L-y', due_at: iso(Date.now() + 5 * H) })]);
  env.rpcHandlers.get_library_clock = () => ({ data: [{ server_now: iso(env.trueNow()), loan_hours: 72, due_soon_hours: 4 }], error: null });
  const a = await boot(env);
  assert.equal(item(a, 'L-y').querySelector('.pill.status').textContent, 'Active', '5h left is not due soon when the window is 4h');
  a.close();
});

// ------------------------------------------------------------------ safe refresh / sync indicator
test('failed refresh keeps the catalogue and loans, shows offline + last synced; recovery updates', async () => {
  const env = studentEnv();
  const a = await boot(env);
  const before = { books: a.all('#bookList .book-card').length, loans: a.all('.activity-item').length };
  assert.ok(before.books === 2 && before.loans === 5);
  assert.match(a.text('syncStatus'), /^Last synced just now/);
  assert.equal(a.$('offlineBadge').classList.contains('hidden'), true);
  env.failAll('Failed to fetch');
  await a.click('#refreshBtn');
  assert.equal(a.all('#bookList .book-card').length, before.books, 'catalogue preserved');
  assert.equal(a.all('.activity-item').length, before.loans, 'loans preserved');
  assert.match(a.text('syncStatus'), /Last synced .*showing saved data/);
  assert.equal(a.$('offlineBadge').classList.contains('hidden'), false, 'offline indicator shown');
  assert.match(a.toast(), /offline|saved/i);
  env.heal();
  env.tables.books = books.concat([{ id: 'B3', title: 'New Arrival', author: '', category: 'Misc', description: '', total_quantity: 2 }]);
  await a.click('#refreshBtn');
  assert.equal(a.all('#bookList .book-card').length, 3, 'recovered and updated');
  assert.equal(a.$('offlineBadge').classList.contains('hidden'), true);
  assert.doesNotMatch(a.text('syncStatus'), /showing saved/);
  a.close();
});

test('partial failure: books fail but loans still refresh; nothing is wiped', async () => {
  const env = studentEnv();
  const a = await boot(env);
  env.fail.books = { message: 'timeout' };
  env.tables.loans = env.tables.loans.concat([loan({ id: 'L-new', book_title: 'Fresh Loan' })]);
  await a.click('#refreshBtn');
  assert.equal(a.all('#bookList .book-card').length, 2, 'books kept');
  assert.ok(item(a, 'L-new'), 'loans updated despite the books failure');
  assert.match(a.text('syncStatus'), /some data could not refresh/);
  a.close();
});

test('first load with no connection does not crash and offers refresh', async () => {
  const env = studentEnv(); env.failAll('Failed to fetch');
  const a = await boot(env);
  assert.match(a.text('syncStatus'), /Not synced yet/);
  assert.equal(a.all('#bookList .book-card').length, 0);
  assert.match(a.text('bookList'), /No books found/);
  env.heal(); await a.click('#refreshBtn');
  assert.equal(a.all('#bookList .book-card').length, 2);
  a.close();
});

test('manual refresh re-reads data; a missing database update is reported clearly', async () => {
  const env = studentEnv(); const a = await boot(env);
  const n = env.callsTo('rpc', 'get_book_availability').length;
  await a.click('#refreshBtn');
  assert.equal(env.callsTo('rpc', 'get_book_availability').length, n + 1);
  env.fail.get_book_availability = { code: 'PGRST202', message: 'Could not find the function public.get_book_availability' };
  await a.click('#refreshBtn');
  assert.match(a.toast(), /migration 002/);
  a.close();
});

test('realtime: a loan recorded on the librarian computer appears on the student phone', async () => {
  const env = studentEnv(); const a = await boot(env);
  assert.equal(a.all('.activity-item').length, 5);
  env.tables.loans.push(loan({ id: 'L-rt', book_title: 'Recorded Just Now' }));
  env.realtime.filter(r => r.table === 'loans').forEach(r => r.cb({ eventType: 'INSERT' }));
  await settle();
  assert.ok(item(a, 'L-rt'));
  assert.ok(env.realtime.some(r => r.table === 'books'), 'books channel subscribed (availability signal)');
  a.close();
});

// ------------------------------------------------------------------ librarian lending desk
function adminEnv() {
  const env = createEnv({ session: adminSession, tables: { books, loans: [loan({ id: 'L-s1', student_id: S1, book_title: 'Chemistry 11' }), loan({ id: 'L-s1r', student_id: S1, book_title: 'Old Book', returned_at: iso(Date.now() - H) }), loan({ id: 'L-man', student_id: S1, book_id: null, book_source: 'manual', book_title: 'Typoo Title', book_author: 'A', book_identifier: 'ID-1' })], profiles } });
  env.activeByBook = { B1: 0, B2: 1 };
  env.rpcHandlers.admin_search_students = ({ p_query }) => ({ data: profiles.filter(p => p.role === 'student' && (p.display_name + p.email).toLowerCase().includes((p_query || '').toLowerCase())).map(({ id, display_name, email, created_at }) => ({ id, display_name, email, created_at })), error: null });
  env.rpcHandlers.admin_create_loan = args => ({ data: { id: 'NEW', book_title: args.p_title || 'Chemistry 11', due_at: iso(env.trueNow() + 72 * H) }, error: null });
  env.rpcHandlers.admin_return_loan = () => ({ data: { id: 'L-s1' }, error: null });
  env.rpcHandlers.admin_correct_loan = () => ({ data: { id: 'C1' }, error: null });
  return env;
}
async function pickStudent(a, q) {
  await a.type('studentSearch', q); await a.click('#studentSearchBtn');
  await a.click('[data-pick-student="s1"]');
}

test('librarian: search student, select catalogue book, record borrowing (server decides all times)', async () => {
  const env = adminEnv(); const a = await boot(env);
  assert.equal(a.$('adminPanel').classList.contains('hidden'), false);
  assert.equal(a.$('recordLoanBtn').disabled, true, 'cannot record without a student');
  await pickStudent(a, 'ami');
  assert.equal(a.$('recordLoanBtn').disabled, false);
  assert.match(a.text('selectedStudent'), /Amina Student/);
  assert.equal(a.all('#studentLoanList [data-return-loan]').length, 2, 'only active loans have a return button');
  assert.ok(a.$('lendBookList').querySelector('[data-pick-book="B2"]').disabled, 'unavailable book cannot be selected');
  await a.click('[data-pick-book="B1"]');
  await a.click('#recordLoanBtn');
  const call = env.callsTo('rpc', 'admin_create_loan').pop();
  assert.deepEqual(call.args, { p_student_id: 's1', p_book_id: 'B1' }, 'no client-supplied dates or titles');
  assert.match(a.text('lendMessage'), /Recorded: Chemistry 11 for Amina Student\. Due /);
  a.close();
});

test('librarian: manual entry sends title/author/identifier and creates no catalogue book', async () => {
  const env = adminEnv(); const a = await boot(env);
  await pickStudent(a, 'ami');
  await a.click('#lendModeManual');
  assert.equal(a.$('lendManual').classList.contains('hidden'), false);
  assert.equal(a.$('lendCatalogue').classList.contains('hidden'), true);
  await a.click('#recordLoanBtn');                                   // blank title
  assert.equal(env.callsTo('rpc', 'admin_create_loan').length, 0);
  assert.match(a.toast(), /Enter the book title/);
  a.$('manualTitle').value = 'Introduction to Amharic'; a.$('manualAuthor').value = 'Alemu'; a.$('manualIdentifier').value = 'ISBN-123';
  await a.click('#recordLoanBtn');
  const call = env.callsTo('rpc', 'admin_create_loan').pop();
  assert.deepEqual(call.args, { p_student_id: 's1', p_title: 'Introduction to Amharic', p_author: 'Alemu', p_book_identifier: 'ISBN-123' });
  assert.equal(env.calls.filter(c => c.kind === 'from' && c.table === 'books' && c.op !== 'select').length, 0, 'catalogue untouched');
  assert.equal(a.$('manualTitle').value, '', 'form cleared after saving');
  a.$('manualTitle').value = 'Only Title';
  await a.click('#recordLoanBtn');
  assert.deepEqual(env.callsTo('rpc', 'admin_create_loan').pop().args, { p_student_id: 's1', p_title: 'Only Title', p_author: null, p_book_identifier: null });
  a.close();
});

test('librarian: record a return (with confirmation) and see server errors', async () => {
  const env = adminEnv(); const a = await boot(env);
  await pickStudent(a, 'ami');
  env.confirmAnswer = false;
  await a.click('[data-return-loan="L-s1"]');
  assert.equal(env.callsTo('rpc', 'admin_return_loan').length, 0, 'cancelled confirmation records nothing');
  env.confirmAnswer = true;
  await a.click('[data-return-loan="L-s1"]');
  assert.deepEqual(env.callsTo('rpc', 'admin_return_loan').pop().args, { p_loan_id: 'L-s1' });
  assert.match(a.toast(), /Return recorded/);
  env.rpcHandlers.admin_create_loan = () => ({ data: null, error: { message: 'This student already has an active loan of this book' } });
  await a.click('[data-pick-book="B1"]'); await a.click('#recordLoanBtn');
  assert.match(a.toast(), /already has an active loan/);
  a.close();
});

test('librarian: correction buttons appear only where they apply (undo on returned loans, edit on manual loans)', async () => {
  const env = adminEnv(); const a = await boot(env);
  await pickStudent(a, 'ami');
  assert.deepEqual(a.all('#studentLoanList [data-correct-undo]').map(b => b.dataset.correctUndo), ['L-s1r']);
  assert.deepEqual(a.all('#studentLoanList [data-correct-edit]').map(b => b.dataset.correctEdit), ['L-man']);
  assert.match(a.text('lendingDesk'), /Loan history is protected/);
  a.close();
});

test('librarian: undo a mistaken return needs confirmation AND a written reason; cancelling records nothing', async () => {
  const env = adminEnv(); const a = await boot(env);
  await pickStudent(a, 'ami');
  env.confirmAnswer = false;
  await a.click('[data-correct-undo="L-s1r"]');
  assert.equal(env.callsTo('rpc', 'admin_correct_loan').length, 0, 'declined confirmation');
  env.confirmAnswer = true; env.promptAnswers = [null];
  await a.click('[data-correct-undo="L-s1r"]');
  assert.equal(env.callsTo('rpc', 'admin_correct_loan').length, 0, 'cancelled reason prompt');
  env.promptAnswers = ['Returned by mistake today'];
  await a.click('[data-correct-undo="L-s1r"]');
  assert.deepEqual(env.callsTo('rpc', 'admin_correct_loan').pop().args, { p_loan_id: 'L-s1r', p_kind: 'undo_return', p_reason: 'Returned by mistake today' });
  assert.match(a.toast(), /Correction recorded in the audit log/);
  assert.match(env.prompts.pop().msg, /saved permanently in the audit log/);
  a.close();
});

test('librarian: fix a typo in a manual entry (clearing a field) with a reason; server refusals are shown', async () => {
  const env = adminEnv(); const a = await boot(env);
  await pickStudent(a, 'ami');
  env.promptAnswers = ['Fixed Title', 'A. Author', '', 'Fix the typo in the title'];
  await a.click('[data-correct-edit="L-man"]');
  assert.deepEqual(env.callsTo('rpc', 'admin_correct_loan').pop().args, { p_loan_id: 'L-man', p_kind: 'edit_manual_details', p_reason: 'Fix the typo in the title', p_book_title: 'Fixed Title', p_book_author: 'A. Author', p_book_identifier: '' });
  assert.equal(env.prompts[0].def, 'Typoo Title', 'form is pre-filled with the stored value');
  env.rpcHandlers.admin_correct_loan = () => ({ data: null, error: { message: 'Enter a reason of at least 10 characters for the correction' } });
  env.promptAnswers = ['T', '', '', 'short'];
  await a.click('[data-correct-edit="L-man"]');
  assert.match(a.toast(), /at least 10 characters/);
  a.close();
});

test('librarian: student search sends the typed query and never lists admins', async () => {
  const env = adminEnv(); const a = await boot(env);
  await a.type('studentSearch', 'bek'); await a.click('#studentSearchBtn');
  assert.deepEqual(env.callsTo('rpc', 'admin_search_students').pop().args, { p_query: 'bek', p_limit: 20 });
  assert.equal(a.all('#studentResults [data-pick-student]').length, 1);
  assert.ok(!a.text('studentResults').includes('Librarian'));
  a.close();
});

test('auth listener stays synchronous and signing out restores the public catalogue', async () => {
  const env = studentEnv(); const a = await boot(env);
  const before = env.callsTo('from', 'profiles').length;
  const callbackResult = env.authCb('SIGNED_OUT', null);
  assert.equal(callbackResult, undefined, 'auth callback must not return a Promise or await Supabase work');
  assert.equal(a.text('userLabel'), 'Guest', 'private session state clears immediately');
  await settle();
  assert.equal(a.all('#bookList .book-card').length, 2, 'public catalogue is reloaded after sign-out');
  assert.equal(env.callsTo('from', 'profiles').length, before, 'sign-out does not issue profile reads');
  a.close();
});

test('stored text is escaped: a hostile manual title cannot inject markup', async () => {
  const bad = '<img src=x onerror=alert(1)>';
  const a = await boot(studentEnv([loan({ id: 'L-bad', book_id: null, book_source: 'manual', book_title: bad, book_author: '<b>x</b>', book_identifier: '"><script>1</script>' })]));
  assert.equal(a.all('#activityList img, #activityList script, #activityList b').length, 0);
  assert.ok(a.text('activityList').includes(bad));
  a.close();
});

// ------------------------------------------------------------------ static checks on the shipped client
test('static: no secret keys, no old RPCs, loans are never written from the client', () => {
  const dir = path.join(__dirname, '..', '..', 'EDUMAK_Cloud_App');
  const js = fs.readFileSync(path.join(dir, 'app.js'), 'utf8');
  const cfg = fs.readFileSync(path.join(dir, 'config.js'), 'utf8');
  for (const [name, src] of [['app.js', js], ['config.js', cfg]]) {
    assert.ok(!/service_role/i.test(src.replace(/NEVER put a service_role\/secret key/i, '')), name + ' mentions service_role as a value');
    assert.ok(!/eyJ[A-Za-z0-9_-]{20,}/.test(src), name + ' contains a JWT-like secret');
  }
  assert.ok(!/rpc\('(borrow_book|return_book)'/.test(js));
  const loanWrites = js.match(/from\('loans'\)\.(insert|update|delete|upsert)/g) || [];
  assert.equal(loanWrites.length, 0);
  assert.ok(/rpc\('admin_create_loan'/.test(js) && /rpc\('admin_return_loan'/.test(js));
  assert.ok(/rpc\('admin_correct_loan'/.test(js));
  assert.equal((js.match(/from\('loans'\)\.select\('\*'\)/g) || []).length, 0, 'loan queries must not fetch internal columns');
  assert.equal((js.match(/from\('loans'\)\.select\('id,student_id,book_title,book_author,book_identifier,book_source,borrowed_at,due_at,returned_at'\)/g) || []).length, 2, 'student and librarian loan views use the minimal projection');
  assert.equal((js.match(/from\('loan_corrections'\)\.(insert|update|delete|upsert)/g) || []).length, 0, 'audit rows are written only by the database function');
});
