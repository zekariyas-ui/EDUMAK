(() => {
'use strict';
const cfg = window.EDUMAK_CONFIG || {};
const configured = !!(cfg.SUPABASE_URL && cfg.SUPABASE_ANON_KEY && !cfg.SUPABASE_ANON_KEY.includes('PASTE_'));
const sb = configured && window.supabase ? window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY) : null;
const $ = id => document.getElementById(id);
const state = {user:null,profile:null,books:[],loans:[],pdfs:[],datasets:[],profiles:[],admin:false,superAdmin:false,channel:null,lastRefresh:0,
  availability:new Map(),activeLoanCount:null,clock:{offset:0,loanHours:72,dueSoonHours:24,synced:false},
  lastSync:0,syncError:null,offline:false,refreshing:false,refreshQueued:false,
  studentResults:[],lendingStudent:null,studentLoans:[],lendBookId:null};
const esc = v => String(v ?? '').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function toast(msg){const el=$('toast');el.textContent=msg;el.classList.add('show');clearTimeout(toast.t);toast.t=setTimeout(()=>el.classList.remove('show'),3200)}
function page(name){document.querySelectorAll('.page').forEach(x=>x.classList.toggle('active',x.id===name));document.querySelectorAll('.nav').forEach(x=>x.classList.toggle('active',x.dataset.page===name));$('sidebar').classList.remove('open');if(name==='admin')renderAdmin();if(name==='activities')renderActivities();if(name==='datasets')renderDatasets()}
document.querySelectorAll('[data-page]').forEach(b=>b.addEventListener('click',()=>page(b.dataset.page)));
document.querySelectorAll('[data-go]').forEach(b=>b.addEventListener('click',()=>page(b.dataset.go)));
$('menuBtn').addEventListener('click',()=>$('sidebar').classList.toggle('open'));
$('year').textContent=new Date().getFullYear();
function currentStudent(){return state.user && state.profile?.role==='student'}
function updateHeader(){ $('userLabel').textContent=state.user?(state.profile?.display_name||state.user.email):'Guest';$('accountBtn').textContent=state.user?'Log out':'Login'; }
function openAuth(){document.querySelectorAll('.tab').forEach(x=>x.classList.toggle('active',x.dataset.tab==='loginForm'));$('loginForm').classList.remove('hidden');$('registerForm').classList.add('hidden');$('authDialog').showModal()}
$('accountBtn').addEventListener('click',async()=>{if(state.user){await sb.auth.signOut();}else openAuth()});
document.querySelectorAll('.tab').forEach(b=>b.addEventListener('click',()=>{document.querySelectorAll('.tab').forEach(x=>x.classList.toggle('active',x===b));$('loginForm').classList.toggle('hidden',b.dataset.tab!=='loginForm');$('registerForm').classList.toggle('hidden',b.dataset.tab!=='registerForm')}));
async function requireClient(){if(!sb){toast('Supabase is not configured yet. Follow SETUP_GUIDE.txt and add the publishable key to config.js.');return false}return true}
$('loginForm').addEventListener('submit',async e=>{e.preventDefault();if(!await requireClient())return;const {error}=await sb.auth.signInWithPassword({email:$('loginEmail').value.trim(),password:$('loginPassword').value});if(error){toast(error.message);return}$('authDialog').close();e.target.reset();toast('Signed in successfully.')});
$('registerForm').addEventListener('submit',async e=>{e.preventDefault();if(!await requireClient())return;const name=$('registerName').value.trim();const {data,error}=await sb.auth.signUp({email:$('registerEmail').value.trim(),password:$('registerPassword').value,options:{data:{display_name:name}}});if(error){toast(error.message);return}if(data.user && data.session){await loadSession(data.session.user);$('authDialog').close()}else toast('Registration submitted. Check your email to confirm, then log in.');e.target.reset()});
$('adminLoginForm').addEventListener('submit',async e=>{e.preventDefault();if(!await requireClient())return;const {data,error}=await sb.auth.signInWithPassword({email:$('adminEmail').value.trim(),password:$('adminPassword').value});if(error){toast(error.message);return}await loadSession(data.user);if(!['admin','super_admin'].includes(state.profile?.role)){await sb.auth.signOut();toast('This account is not authorized as an administrator.');return}e.target.reset();toast('Administrator signed in.');page('admin')});
$('adminLogout').addEventListener('click',()=>sb.auth.signOut());
async function loadSession(user){state.user=user;const {data,error}=await sb.from('profiles').select('id,email,display_name,role,created_at').eq('id',user.id).maybeSingle();if(error){console.error(error);toast('Could not load account profile: '+error.message);state.profile=null}else state.profile=data;state.admin=['admin','super_admin'].includes(state.profile?.role);state.superAdmin=state.profile?.role==='super_admin';updateHeader();await refreshData();renderAdmin()}
const SYNC_LABELS={books:'books',availability:'availability',loans:'your loans',activeCount:'loan count',pdfs:'PDFs',datasets:'datasets',profiles:'accounts',clock:'server time'};
const isNetworkError=m=>/failed to fetch|network|load failed|fetch/i.test(String(m||''));
/* Reads everything from Supabase. A failed query never wipes data that was already loaded. */
async function refreshData(opts={}){
  if(!sb)return;
  if(state.refreshing){state.refreshQueued=true;return}
  state.refreshing=true;updateSyncBar();
  const user=state.user,admin=state.admin;
  let sent=0,recv=0;
  const jobs={
    books:sb.from('books').select('*').order('title'),
    availability:sb.rpc('get_book_availability'),
    loans:user&&!admin?sb.from('loans').select('id,student_id,book_title,book_author,book_identifier,book_source,borrowed_at,due_at,returned_at').order('borrowed_at',{ascending:false}):null,
    activeCount:user&&admin?sb.from('loans').select('id',{count:'exact',head:true}).is('returned_at',null):null,
    pdfs:user?sb.from('pdf_documents').select('*').order('created_at',{ascending:false}):null,
    datasets:user?sb.from('dataset_documents').select('*').order('created_at',{ascending:false}):null,
    profiles:admin?sb.from('profiles').select('id,email,display_name,role,created_at').order('created_at',{ascending:false}):null,
    clock:user?(async()=>{sent=Date.now();const r=await sb.rpc('get_library_clock');recv=Date.now();return r})():null
  };
  const names=Object.keys(jobs).filter(n=>jobs[n]);
  const results=await Promise.all(names.map(n=>Promise.resolve(jobs[n]).then(r=>r,e=>({error:{message:String((e&&e.message)||e)}}))));
  const failed=[];let needsMigration=false;
  names.forEach((n,i)=>{
    const r=results[i];
    if(!r||r.error){
      failed.push(n);console.error(n,r&&r.error);
      if(r&&r.error&&(r.error.code==='PGRST202'||/could not find the function/i.test(r.error.message||'')))needsMigration=true;
      return;
    }
    if(n==='books')state.books=r.data||[];
    else if(n==='availability')state.availability=new Map((r.data||[]).map(a=>[a.book_id,a]));
    else if(n==='loans')state.loans=r.data||[];
    else if(n==='activeCount')state.activeLoanCount=r.count;
    else if(n==='pdfs')state.pdfs=r.data||[];
    else if(n==='datasets')state.datasets=r.data||[];
    else if(n==='profiles')state.profiles=r.data||[];
    else if(n==='clock'){const row=Array.isArray(r.data)?r.data[0]:r.data;if(row&&row.server_now)state.clock={offset:new Date(row.server_now).getTime()-(sent+recv)/2,loanHours:row.loan_hours||72,dueSoonHours:row.due_soon_hours||24,synced:true}}
  });
  const hadError=!!state.syncError;
  if(failed.length){state.syncError=failed;state.offline=navigator.onLine===false||results.some(r=>r&&r.error&&isNetworkError(r.error.message))}
  else{state.syncError=null;state.offline=false;state.lastSync=Date.now();state.lastRefresh=Date.now()}
  state.refreshing=false;
  renderAll();updateSyncBar();
  if(failed.length&&(opts.manual||!hadError))toast(needsMigration?'The database needs the latest update (run migration 002 in Supabase).':(state.offline?'You appear to be offline. Showing the last saved library data.':'Some data could not be refreshed ('+failed.map(n=>SYNC_LABELS[n]||n).join(', ')+'). Showing the last saved data.'));
  else if(opts.manual&&!failed.length)toast('Library data is up to date.');
  if(state.refreshQueued){state.refreshQueued=false;refreshData()}
}
function relTime(ts){const s=Math.max(0,Math.round((Date.now()-ts)/1000));if(s<45)return 'just now';const m=Math.round(s/60);if(m<60)return m+' min ago';const h=Math.round(m/60);return h<24?h+' h ago':new Date(ts).toLocaleString()}
function updateSyncBar(){
  const st=$('syncStatus');if(!st)return;
  const off=state.offline||navigator.onLine===false;
  $('offlineBadge').classList.toggle('hidden',!off);
  if(state.refreshing)st.textContent='Syncing...';
  else if(state.lastSync)st.textContent='Last synced '+relTime(state.lastSync)+' ('+new Date(state.lastSync).toLocaleTimeString()+')'+(state.syncError?' - some data could not refresh, showing saved data':'');
  else st.textContent=state.syncError?'Not synced yet - could not reach the library':'Not synced yet';
  $('refreshBtn').disabled=!!state.refreshing;
}
function availInfo(book){return state.availability.get(book.id)||null}
function available(book){const a=availInfo(book);return a?a.available:null}
function availLabel(book){const n=available(book);return n===null?'-':String(n)}
function renderStats(){
  $('statBooks').textContent=state.books.length;
  const vals=state.books.map(b=>available(b)).filter(v=>v!==null);
  $('statAvailable').textContent=vals.length?vals.reduce((n,v)=>n+v,0):'-';
  $('statPdfs').textContent=state.user?state.pdfs.length:'-';
  $('statLoans').textContent=!state.user?'-':(state.admin?(state.activeLoanCount===null?'-':state.activeLoanCount):state.loans.filter(x=>!x.returned_at).length);
}
function bookCard(b){
  const a=availInfo(b),n=a?a.available:null,out=a?a.active_loans:null;
  return `<article class="book-card"><div class="book-meta"><span class="pill">${esc(b.category)}</span><span class="pill ${n===null?'':(n?'available':'unavailable')}">${n===null?'Availability unknown':n+' available'}</span></div><h3>${esc(b.title)}</h3><p>${esc(b.author||'Author not specified')}</p><p>${esc(b.description||'No description provided.')}</p><p>Total copies: ${Number(b.total_quantity)} · On loan: ${out===null?'-':out}</p></article>`;
}
function renderBooks(){const q=$('bookSearch').value.trim().toLowerCase();const found=state.books.filter(b=>[b.title,b.author,b.category,b.description].join(' ').toLowerCase().includes(q));$('bookList').innerHTML=found.length?found.map(b=>bookCard(b)).join(''):'<div class="empty">No books found. The administrator can register books from the Admin Dashboard.</div>';$('borrowList').innerHTML=state.books.length?state.books.map(b=>bookCard(b)).join(''):'<div class="empty">No books have been registered yet.</div>'}
/* Official time = device clock corrected by the offset measured against the database clock. */
function serverNow(){return Date.now()+state.clock.offset}
function timeLeft(due){return new Date(due).getTime()-serverNow()}
const STATUS_LABEL={active:'Active','due-soon':'Due soon',overdue:'Overdue',returned:'Returned'};
function loanStatus(r){if(r.returned_at)return 'returned';const ms=timeLeft(r.due_at);if(ms<=0)return 'overdue';return ms<=state.clock.dueSoonHours*3600000?'due-soon':'active'}
const fmt=d=>d?esc(new Date(d).toLocaleString()):'';
function formatLeft(ms){if(ms<=0)return '00:00:00';const s=Math.floor(ms/1000),h=Math.floor(s/3600),m=Math.floor((s%3600)/60),sec=s%60;return `${String(h).padStart(2,'0')}:${String(m).padStart(2,'0')}:${String(sec).padStart(2,'0')}`}
function countdownText(r){const ms=timeLeft(r.due_at);return ms<=0?'Overdue by '+formatLeft(-ms):formatLeft(ms)+' left'}
function loanRow(r,admin){
  const st=loanStatus(r),returned=st==='returned';
  const meta=[r.book_author?esc(r.book_author):'',r.book_identifier?'ID '+esc(r.book_identifier):'',r.book_source==='manual'?'Entered by the librarian':''].filter(Boolean).join(' · ');
  return `<div class="activity-item" data-loan="${esc(r.id)}" data-due="${esc(r.due_at)}" data-returned="${returned?1:0}"><div><strong>${esc(r.book_title||'Book')}</strong>${meta?`<small>${meta}</small>`:''}<small>Borrowed: ${fmt(r.borrowed_at)} · Due: ${fmt(r.due_at)}${returned?` · Returned: ${fmt(r.returned_at)}`:''}</small>${returned?'':`<div class="countdown ${st}">${countdownText(r)}</div>`}</div><div class="loan-actions"><span class="pill status ${st}">${STATUS_LABEL[st]}</span>${admin&&!returned?`<button type="button" class="btn btn-outline" data-return-loan="${esc(r.id)}">Record return</button>`:''}${admin&&returned?`<button type="button" class="btn-small" data-correct-undo="${esc(r.id)}">Undo return</button>`:''}${admin&&r.book_source==='manual'?`<button type="button" class="btn-small" data-correct-edit="${esc(r.id)}">Edit details</button>`:''}</div></div>`;
}
/* Student view: read-only. There is no borrow or return control anywhere in the student interface. */
function renderActivities(){
  const box=$('activityList');
  if(!state.user){box.innerHTML='<div class="empty">Please log in with your student account to see your borrowed books.</div>';return}
  if(!currentStudent()){box.innerHTML='<div class="empty">Borrowing is recorded from the Lending Desk in the Admin Dashboard.</div>';return}
  const rows=state.loans.filter(x=>x.student_id===state.user.id);
  if(!rows.length){box.innerHTML='<div class="empty">You have no borrowing records yet. Books are lent by the librarian.</div>';return}
  const cur=rows.filter(r=>!r.returned_at).sort((a,b)=>new Date(a.due_at)-new Date(b.due_at));
  const done=rows.filter(r=>r.returned_at).sort((a,b)=>new Date(b.returned_at)-new Date(a.returned_at));
  box.innerHTML=(cur.length?'<h3 class="list-title">Current loans</h3>'+cur.map(r=>loanRow(r,false)).join(''):'<div class="empty">You have no books on loan right now.</div>')+(done.length?'<h3 class="list-title">Returned</h3>'+done.map(r=>loanRow(r,false)).join(''):'');
}
/* Runs every second: updates countdown text, colour AND the status label as deadlines pass. */
function tickCountdowns(){document.querySelectorAll('.activity-item[data-loan]').forEach(el=>{
  if(el.dataset.returned==='1')return;
  const r={returned_at:null,due_at:el.dataset.due},st=loanStatus(r);
  const cd=el.querySelector('.countdown'),pill=el.querySelector('.pill.status');
  if(cd){cd.textContent=countdownText(r);cd.className='countdown '+st}
  if(pill){pill.textContent=STATUS_LABEL[st];pill.className='pill status '+st}
})}
/* ---------- Lending desk (librarian/admin only; the database enforces this too) ---------- */
let studentSearchTimer;
function lendMode(){const m=document.querySelector('input[name="lendMode"]:checked');return m?m.value:'catalogue'}
function syncLendMode(){const manual=lendMode()==='manual';$('lendCatalogue').classList.toggle('hidden',manual);$('lendManual').classList.toggle('hidden',!manual)}
async function searchStudents(){
  if(!state.admin)return;
  const {data,error}=await sb.rpc('admin_search_students',{p_query:$('studentSearch').value.trim(),p_limit:20});
  if(error){toast(error.message);return}
  state.studentResults=data||[];renderStudentResults();
}
function renderStudentResults(){
  const box=$('studentResults'),q=$('studentSearch').value.trim();
  box.innerHTML=state.studentResults.length?state.studentResults.map(s=>`<button type="button" class="pick-row ${state.lendingStudent&&state.lendingStudent.id===s.id?'selected':''}" data-pick-student="${esc(s.id)}"><b>${esc(s.display_name)}</b><small>${esc(s.email)}</small></button>`).join(''):`<p class="hint">${q?'No matching students.':'Type a name or email, then press Search.'}</p>`;
  box.querySelectorAll('[data-pick-student]').forEach(b=>b.addEventListener('click',()=>pickStudent(b.dataset.pickStudent)));
}
async function pickStudent(id){state.lendingStudent=state.studentResults.find(s=>s.id===id)||null;$('lendMessage').textContent='';await loadStudentLoans();renderLendingDesk()}
async function loadStudentLoans(){
  if(!state.lendingStudent){state.studentLoans=[];return}
  const {data,error}=await sb.from('loans').select('id,student_id,book_title,book_author,book_identifier,book_source,borrowed_at,due_at,returned_at').eq('student_id',state.lendingStudent.id).order('borrowed_at',{ascending:false});
  if(error){toast('Could not load the student\'s loans: '+error.message);return}
  state.studentLoans=data||[];
}
function renderSelectedStudent(){
  const box=$('selectedStudent'),s=state.lendingStudent;
  box.innerHTML=s?`<div class="sel-card"><div><b>${esc(s.display_name)}</b><small>${esc(s.email)}</small></div><button type="button" class="btn-small" id="clearStudent">Change</button></div>`:'<p class="hint">No student selected.</p>';
  const c=$('clearStudent');if(c)c.addEventListener('click',()=>{state.lendingStudent=null;state.studentLoans=[];renderLendingDesk()});
}
function renderLendBooks(){
  const box=$('lendBookList'),q=($('lendBookSearch').value||'').trim().toLowerCase();
  const list=state.books.filter(b=>!q||[b.title,b.author,b.category].join(' ').toLowerCase().includes(q)).slice(0,30);
  box.innerHTML=list.length?list.map(b=>{const n=available(b);return `<button type="button" class="pick-row ${state.lendBookId===b.id?'selected':''}" data-pick-book="${esc(b.id)}" ${n===0?'disabled':''}><b>${esc(b.title)}</b><small>${esc(b.author||'')}${b.category?' · '+esc(b.category):''} · ${n===null?'availability unknown':n+' available'}</small></button>`}).join(''):'<p class="hint">No catalogue books match.</p>';
  box.querySelectorAll('[data-pick-book]').forEach(x=>x.addEventListener('click',()=>{state.lendBookId=x.dataset.pickBook;renderLendBooks()}));
}
function renderStudentLoans(){
  const box=$('studentLoanList');
  if(!state.lendingStudent){box.innerHTML='<p class="hint">Select a student to see their loans.</p>';return}
  box.innerHTML=state.studentLoans.length?state.studentLoans.map(r=>loanRow(r,true)).join(''):'<p class="hint">This student has no borrowing records.</p>';
  box.querySelectorAll('[data-return-loan]').forEach(b=>b.addEventListener('click',()=>recordReturn(b.dataset.returnLoan)));
  box.querySelectorAll('[data-correct-undo]').forEach(b=>b.addEventListener('click',()=>correctLoan(b.dataset.correctUndo,'undo_return')));
  box.querySelectorAll('[data-correct-edit]').forEach(b=>b.addEventListener('click',()=>correctLoan(b.dataset.correctEdit,'edit_manual_details')));
}
function renderLendingDesk(){
  if(!$('lendingDesk'))return;
  renderStudentResults();renderSelectedStudent();renderLendBooks();renderStudentLoans();syncLendMode();
  $('recordLoanBtn').disabled=!state.admin||!state.lendingStudent;
}
async function recordLoan(){
  if(!state.admin||!state.lendingStudent){toast('Choose a student first.');return}
  const args={p_student_id:state.lendingStudent.id};
  if(lendMode()==='catalogue'){
    if(!state.lendBookId){toast('Select a book from the catalogue.');return}
    args.p_book_id=state.lendBookId;
  }else{
    const title=$('manualTitle').value.trim();
    if(!title){toast('Enter the book title.');return}
    args.p_title=title;args.p_author=$('manualAuthor').value.trim()||null;args.p_book_identifier=$('manualIdentifier').value.trim()||null;
  }
  const btn=$('recordLoanBtn');btn.disabled=true;
  const {data,error}=await sb.rpc('admin_create_loan',args);
  btn.disabled=false;
  if(error){toast(error.message);return}
  $('lendMessage').textContent='Recorded: '+data.book_title+' for '+state.lendingStudent.display_name+'. Due '+new Date(data.due_at).toLocaleString()+'.';
  state.lendBookId=null;$('manualTitle').value='';$('manualAuthor').value='';$('manualIdentifier').value='';
  await loadStudentLoans();await refreshData();renderLendingDesk();
}
async function recordReturn(loanId){
  const r=state.studentLoans.find(x=>x.id===loanId);
  if(!r||!state.admin)return;
  if(!confirm('Record the return of "'+r.book_title+'" from '+(state.lendingStudent?state.lendingStudent.display_name:'this student')+'?'))return;
  const {error}=await sb.rpc('admin_return_loan',{p_loan_id:loanId});
  if(error){toast(error.message);return}
  toast('Return recorded.');await loadStudentLoans();await refreshData();renderLendingDesk();
}
/* Loan history is protected by the database. A mistake is fixed only through an audited correction with a written reason. */
async function correctLoan(loanId,kind){
  const r=state.studentLoans.find(x=>x.id===loanId);
  if(!r||!state.admin)return;
  const args={p_loan_id:loanId,p_kind:kind};
  if(kind==='edit_manual_details'){
    const t=prompt('Book title',r.book_title);if(t===null)return;
    const a=prompt('Author (leave empty to clear)',r.book_author||'');if(a===null)return;
    const i=prompt('Book identification number (leave empty to clear)',r.book_identifier||'');if(i===null)return;
    args.p_book_title=t;args.p_book_author=a;args.p_book_identifier=i;
  }else if(!confirm('Undo the recorded return of "'+r.book_title+'"? The loan becomes active again with its original deadline.'))return;
  const reason=prompt('Reason for this correction (saved permanently in the audit log, at least 10 characters)','');
  if(reason===null)return;
  args.p_reason=reason;
  const {error}=await sb.rpc('admin_correct_loan',args);
  if(error){toast(error.message);return}
  toast('Correction recorded in the audit log.');await loadStudentLoans();await refreshData();renderLendingDesk();
}
$('studentSearch').addEventListener('input',()=>{clearTimeout(studentSearchTimer);studentSearchTimer=setTimeout(searchStudents,300)});
$('studentSearchBtn').addEventListener('click',searchStudents);
$('lendBookSearch').addEventListener('input',renderLendBooks);
document.querySelectorAll('input[name="lendMode"]').forEach(r=>r.addEventListener('change',syncLendMode));
$('recordLoanBtn').addEventListener('click',recordLoan);
async function renderPdfs(){if(!state.user){$('pdfList').innerHTML='<div class="empty">Log in to access shared PDF resources.</div>';return}if(!state.pdfs.length){$('pdfList').innerHTML='<div class="empty">No PDF resources have been uploaded yet.</div>';return}$('pdfList').innerHTML=state.pdfs.map(p=>`<div class="pdf-item"><div><strong>▣ ${esc(p.title)}</strong><small>${esc(p.file_name)} · ${new Date(p.created_at).toLocaleDateString()}</small></div><button class="btn btn-primary" data-open-pdf="${p.id}">Open PDF</button></div>`).join('');document.querySelectorAll('[data-open-pdf]').forEach(btn=>btn.addEventListener('click',async()=>{const p=state.pdfs.find(x=>x.id===btn.dataset.openPdf);const {data,error}=await sb.storage.from('edumak-pdfs').createSignedUrl(p.storage_path,300);if(error){toast(error.message);return}window.open(data.signedUrl,'_blank','noopener')}))}
function renderDatasets(){if(!state.user){$('datasetList').innerHTML='<div class="empty">Log in to access shared datasets.</div>';return}if(!state.datasets.length){$('datasetList').innerHTML='<div class="empty">No datasets have been uploaded yet.</div>';return}const latestByKey=new Map();for(const d of state.datasets){const current=latestByKey.get(d.resource_key);if(!current||Number(d.version)>Number(current.version))latestByKey.set(d.resource_key,d)}$('datasetList').innerHTML=state.datasets.map(d=>{const latest=latestByKey.get(d.resource_key)?.id===d.id;return `<div class="pdf-item"><div><strong>▦ ${esc(d.title)} ${latest?'<span class="pill available">Latest</span>':'<span class="pill">Previous version</span>'}</strong><small>${esc(d.file_name)} · Version ${d.version} · ${new Date(d.created_at).toLocaleDateString()}</small></div><button class="btn btn-primary" data-open-dataset="${d.id}">Download</button></div>`}).join('');document.querySelectorAll('[data-open-dataset]').forEach(btn=>btn.addEventListener('click',async()=>{const d=state.datasets.find(x=>x.id===btn.dataset.openDataset);if(!d)return;const {data,error}=await sb.storage.from('edumak-datasets').createSignedUrl(d.storage_path,300);if(error){toast(error.message);return}window.location.href=data.signedUrl}))}
async function changeAccountRole(userId){if(!state.superAdmin)return toast('Super Admin access required.');const control=document.querySelector('[data-role-select="'+userId+'"]');if(!control)return;const role=control.value;const label=role==='admin'?'Librarian Admin':role==='super_admin'?'Super Admin':'Student';if(!confirm('Change this account role to '+label+'?'))return;const {error}=await sb.rpc('admin_set_user_role',{p_user_id:userId,p_role:role});if(error){toast(error.message);return}await refreshData();toast('Account role updated.');}
function renderAdmin(){const show=state.admin&&!!state.user;$('adminLoginPanel').classList.toggle('hidden',show);$('adminPanel').classList.toggle('hidden',!show);if(!show)return;$('adminIdentity').textContent=`Signed in as ${state.profile?.email||state.user.email}`;$('profileName').value=state.profile?.display_name||'';$('adminBookList').innerHTML=state.books.length?state.books.map(b=>`<div class="admin-row"><div><b>${esc(b.title)}</b><small>${esc(availLabel(b))} available / ${Number(b.total_quantity)} total</small></div><div class="mini-actions"><button class="btn-small" data-edit-book="${b.id}">Edit</button><button class="btn-small btn-danger" data-delete-book="${b.id}">Delete</button></div></div>`).join(''):'<p class="hint">No books registered yet.</p>';document.querySelectorAll('[data-edit-book]').forEach(x=>x.addEventListener('click',()=>editBook(x.dataset.editBook)));document.querySelectorAll('[data-delete-book]').forEach(x=>x.addEventListener('click',()=>deleteBook(x.dataset.deleteBook)));$('adminDatasetList').innerHTML=state.datasets.length?state.datasets.map(d=>`<div class="admin-row"><div><b>${esc(d.title)}</b><small>${esc(d.file_name)} · Version ${d.version} · ${new Date(d.created_at).toLocaleDateString()}</small></div></div>`).join(''):'<p class="hint">No datasets uploaded yet.</p>';$('studentList').innerHTML=state.profiles.length?state.profiles.map(p=>`<div class="admin-row"><div><b>${esc(p.display_name||'Student')}</b><small>${esc(p.email)} · ${esc(p.role)}</small></div></div>`).join(''):'<p class="hint">No profiles to display.</p>';$('adminManagementPanel').classList.toggle('hidden',!state.superAdmin);$('adminManagementList').innerHTML=state.superAdmin?(state.profiles.length?state.profiles.map(p=>{const own=p.id===state.user.id;return `<div class="admin-row"><div><b>${esc(p.display_name||'Student')}</b><small>${esc(p.email)} · Current role: ${esc(p.role)}</small></div><div class="mini-actions">${own?'<small>Your own role is locked</small>':`<select aria-label="Role for ${esc(p.email)}" data-role-select="${esc(p.id)}"><option value="student" ${p.role==='student'?'selected':''}>Student</option><option value="admin" ${p.role==='admin'?'selected':''}>Librarian Admin</option><option value="super_admin" ${p.role==='super_admin'?'selected':''}>Super Admin</option></select><button type="button" class="btn-small" data-save-role="${esc(p.id)}">Save role</button>`}</div></div>`}).join(''):'<p class="hint">No accounts found.</p>'):'<p class="hint">Only a Super Admin can manage account roles.</p>';document.querySelectorAll('[data-save-role]').forEach(b=>b.addEventListener('click',()=>changeAccountRole(b.dataset.saveRole)));}
function editBook(id){const b=state.books.find(x=>x.id===id);if(!b)return;$('bookId').value=b.id;$('bookTitle').value=b.title;$('bookAuthor').value=b.author||'';$('bookCategory').value=b.category;$('bookQuantity').value=b.total_quantity;$('bookDescription').value=b.description||'';window.scrollTo({top:document.getElementById('bookForm').getBoundingClientRect().top+scrollY-90,behavior:'smooth'})}
$('cancelBookEdit').addEventListener('click',()=>$('bookForm').reset());
$('bookForm').addEventListener('submit',async e=>{e.preventDefault();if(!state.admin)return toast('Administrator access required.');const id=$('bookId').value;const payload={title:$('bookTitle').value.trim(),author:$('bookAuthor').value.trim(),category:$('bookCategory').value.trim(),total_quantity:Number($('bookQuantity').value),description:$('bookDescription').value.trim()};if(!Number.isInteger(payload.total_quantity)||payload.total_quantity<0)return toast('Enter a valid whole-number quantity.');let res;if(id)res=await sb.from('books').update(payload).eq('id',id);else res=await sb.from('books').insert(payload);if(res.error){toast(res.error.message);return}e.target.reset();await refreshData();toast(id?'Book updated.':'Book registered.')});
async function deleteBook(id){if(!confirm('Delete this book record? A book that has ever been borrowed cannot be deleted; set its quantity to 0 to stop lending it.'))return;const {error}=await sb.from('books').delete().eq('id',id);if(error){toast(error.message);return}await refreshData();toast('Book deleted.')}
$('profileForm').addEventListener('submit',async e=>{e.preventDefault();if(!state.admin)return;const name=$('profileName').value.trim(),password=$('newPassword').value;const {error:pe}=await sb.from('profiles').update({display_name:name}).eq('id',state.user.id);if(pe){toast(pe.message);return}if(password){const {error}=await sb.auth.updateUser({password});if(error){toast('Name saved, but password update failed: '+error.message);return}}$('newPassword').value='';await loadSession(state.user);toast('Administrator account updated.')});
$('datasetForm').addEventListener('submit',async e=>{e.preventDefault();if(!state.admin)return toast('Administrator access required.');const file=$('datasetFile').files[0];if(!file)return toast('Choose a dataset file.');const ext=file.name.split('.').pop().toLowerCase();const mimeByExt={csv:'text/csv',json:'application/json',xlsx:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',xls:'application/vnd.ms-excel'};if(!mimeByExt[ext])return toast('Supported formats are CSV, JSON, XLSX and XLS.');if(file.size>25*1024*1024)return toast('Dataset must be 25 MB or smaller.');const title=$('datasetTitle').value.trim();if(!title)return toast('Enter a dataset title.');const key=title.normalize('NFKD').toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'').slice(0,100)||`dataset-${Date.now()}`;const latest=state.datasets.filter(x=>x.resource_key===key).reduce((n,x)=>Math.max(n,Number(x.version)||0),0);const version=latest+1;const safeName=file.name.replace(/[^a-zA-Z0-9._-]/g,'_');const path=`${state.user.id}/${crypto.randomUUID()}-${safeName}`;const up=await sb.storage.from('edumak-datasets').upload(path,file,{contentType:mimeByExt[ext],upsert:false});if(up.error){toast(up.error.message);return}const ins=await sb.from('dataset_documents').insert({title,resource_key:key,version,file_name:file.name,storage_path:path,file_size:file.size,file_type:ext,uploaded_by:state.user.id});if(ins.error){await sb.storage.from('edumak-datasets').remove([path]);toast(ins.error.code==='23505'?'Another admin uploaded this dataset at the same time. Refresh and try again.':ins.error.message);return}e.target.reset();await refreshData();toast(`Dataset uploaded as version ${version}.`)});
$('pdfForm').addEventListener('submit',async e=>{e.preventDefault();if(!state.admin)return;const file=$('pdfFile').files[0];if(!file)return toast('Choose a PDF file.');if(file.type!=='application/pdf'&&!file.name.toLowerCase().endsWith('.pdf'))return toast('Only PDF files are accepted.');if(file.size>25*1024*1024)return toast('PDF must be 25 MB or smaller.');const path=`${state.user.id}/${crypto.randomUUID()}-${file.name.replace(/[^a-zA-Z0-9._-]/g,'_')}`;const up=await sb.storage.from('edumak-pdfs').upload(path,file,{contentType:'application/pdf',upsert:false});if(up.error){toast(up.error.message);return}const ins=await sb.from('pdf_documents').insert({title:$('pdfTitle').value.trim(),file_name:file.name,storage_path:path,file_size:file.size,uploaded_by:state.user.id});if(ins.error){await sb.storage.from('edumak-pdfs').remove([path]);toast(ins.error.message);return}e.target.reset();await refreshData();toast('PDF uploaded to shared storage.')});
$('bookSearch').addEventListener('input',renderBooks);$('searchBtn').addEventListener('click',renderBooks);
function renderAll(){renderStats();renderBooks();renderActivities();renderPdfs();renderDatasets();renderAdmin();renderLendingDesk()}
let authEventVersion=0;
function clearSignedOutState(){
  state.user=null;state.profile=null;state.admin=false;state.superAdmin=false;state.loans=[];state.pdfs=[];state.datasets=[];state.profiles=[];
  state.studentLoans=[];state.lendingStudent=null;state.studentResults=[];state.activeLoanCount=null;
  state.lendBookId=null;state.availability=new Map();state.clock={offset:0,loanHours:72,dueSoonHours:24,synced:false};
  updateHeader();renderAll();
}
async function init(){updateHeader();if(!configured){$('connectionNotice').textContent='Setup required: add the Supabase publishable/anon key in config.js and run database_setup.sql in the Supabase SQL Editor. The project URL is already filled in.';renderAll();return}if(!sb){toast('Supabase client library did not load. Check internet connection.');return}const {data:{session}}=await sb.auth.getSession();if(session)await loadSession(session.user);else await refreshData();sb.auth.onAuthStateChange((_event,session)=>{
  // Supabase holds an auth lock while this callback runs. Defer all Supabase reads
  // until after it returns; awaiting loadSession() here can deadlock auth events.
  const version=++authEventVersion;
  if(!session){clearSignedOutState();window.setTimeout(()=>{if(version===authEventVersion)refreshData()},0);return}
  const authUser=session.user;
  window.setTimeout(()=>{if(version===authEventVersion&&state.user?.id!==authUser.id)void loadSession(authUser)},0);
});state.channel=sb.channel('edumak-live').on('postgres_changes',{event:'*',schema:'public',table:'books'},()=>refreshData()).on('postgres_changes',{event:'*',schema:'public',table:'loans'},()=>{refreshData();if(state.admin&&state.lendingStudent)loadStudentLoans().then(renderLendingDesk)}).on('postgres_changes',{event:'*',schema:'public',table:'pdf_documents'},payload=>{refreshData();if(payload.eventType==='INSERT'&&state.user)toast('New shared PDF resource available.')}).on('postgres_changes',{event:'*',schema:'public',table:'dataset_documents'},payload=>{refreshData();if(payload.eventType==='INSERT'&&state.user)toast('New shared dataset available.')}).subscribe();}
$('refreshBtn').addEventListener('click',()=>refreshData({manual:true}));
window.addEventListener('online',()=>{state.offline=false;updateSyncBar();refreshData()});
window.addEventListener('offline',()=>{state.offline=true;updateSyncBar()});
setInterval(updateSyncBar,30000);
setInterval(tickCountdowns,1000);setInterval(()=>{if(sb&&document.visibilityState==='visible')refreshData()},6*60*60*1000);document.addEventListener('visibilitychange',()=>{if(sb&&document.visibilityState==='visible'&&Date.now()-state.lastRefresh>=6*60*60*1000)refreshData()});init();
})();

// EDUMAK role management and installable PWA feature branch validation.
