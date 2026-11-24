'use strict';
// Test harness: runs the real EDUMAK_Cloud_App/app.js inside jsdom against a MOCKED Supabase client.
// This is a scratch environment. It is not a browser on a phone and not a real Supabase project.
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const APP = process.env.EDUMAK_APP_DIR || path.join(__dirname, '..', '..', 'EDUMAK_Cloud_App');
const RealDate = Date;

const iso = ms => new RealDate(ms).toISOString();
const settle = (ms = 40) => new Promise(r => setTimeout(r, ms));

function createEnv(opts = {}) {
  const env = {
    skew: opts.skew || 0,          // device clock error relative to the true (database) clock
    shift: 0,                      // simulated passage of time (applies to device AND database)
    online: true,
    confirmAnswer: true,
    promptAnswers: [],
    prompts: [],
    session: opts.session || null,
    tables: Object.assign({ books: [], loans: [], pdf_documents: [], dataset_documents: [], profiles: [] }, opts.tables || {}),
    fail: {},                      // table/rpc name -> error object returned instead of data
    rpcHandlers: Object.assign({}, opts.rpc || {}),
    rls: opts.rls !== false,       // emulate "students read only their own loans"
    calls: [], intervals: [], realtime: [], authCb: null,
  };
  env.trueNow = () => RealDate.now() + env.shift;
  env.deviceNow = () => env.trueNow() + env.skew;
  env.advance = ms => { env.shift += ms; };
  env.failAll = (message) => { for (const n of ['books', 'loans', 'pdf_documents', 'dataset_documents', 'profiles', 'get_book_availability', 'get_library_clock']) env.fail[n] = { message }; };
  env.heal = () => { env.fail = {}; };
  env.callsTo = (kind, name) => env.calls.filter(c => c.kind === kind && (c.name === name || c.table === name));
  return env;
}

function makeClient(env) {
  const user = () => (env.session && env.session.user) || null;
  const isAdminSession = () => !!(env.session && env.session.user && env.session.user.role === 'admin');
  function from(table) {
    const q = { table, filters: [], op: 'select', head: false, payload: null };
    const api = {
      select(cols, o) { if (o && o.head) q.head = true; return api; },
      order() { return api; },
      eq(c, v) { q.filters.push(['eq', c, v]); return api; },
      is(c, v) { q.filters.push(['is', c, v]); return api; },
      insert(v) { q.op = 'insert'; q.payload = v; return api; },
      update(v) { q.op = 'update'; q.payload = v; return api; },
      delete() { q.op = 'delete'; return api; },
      maybeSingle() { return run().then(r => (r.error ? r : { data: (r.data || [])[0] || null, error: null })); },
      then(a, b) { return run().then(a, b); },
    };
    function run() {
      env.calls.push({ kind: 'from', table, op: q.op, filters: JSON.parse(JSON.stringify(q.filters)), head: q.head, payload: q.payload === null ? null : JSON.parse(JSON.stringify(q.payload)) });
      if (env.fail[table]) return Promise.resolve({ data: null, error: env.fail[table] });
      let rows = (env.tables[table] || []).filter(r => q.filters.every(([t, c, v]) => (t === 'is' && v === null ? r[c] == null : r[c] === v)));
      if (table === 'loans' && env.rls && !isAdminSession()) rows = rows.filter(r => user() && r.student_id === user().id);
      if (q.op !== 'select') return Promise.resolve({ data: null, error: null });
      if (q.head) return Promise.resolve({ data: null, count: rows.length, error: null });
      return Promise.resolve({ data: rows.map(r => ({ ...r })), error: null });
    }
    return api;
  }
  const defaultRpc = {
    get_library_clock: () => ({ data: [{ server_now: iso(env.trueNow()), loan_hours: 72, due_soon_hours: 24 }], error: null }),
    get_book_availability: () => ({
      data: env.tables.books.map(b => {
        const n = (env.activeByBook || {})[b.id] || 0;
        return { book_id: b.id, total_quantity: b.total_quantity, active_loans: n, available: Math.max(0, b.total_quantity - n) };
      }), error: null }),
  };
  return {
    from,
    rpc(name, args) {
      env.calls.push({ kind: 'rpc', name, args: args === undefined ? undefined : JSON.parse(JSON.stringify(args)) });
      if (env.fail[name]) return Promise.resolve({ data: null, error: env.fail[name] });
      const h = env.rpcHandlers[name] || defaultRpc[name];
      return Promise.resolve(h ? h(args) : { data: null, error: { message: 'no mock handler for ' + name } });
    },
    auth: {
      getSession: () => Promise.resolve({ data: { session: env.session } }),
      onAuthStateChange(cb) { env.authCb = cb; return { data: { subscription: { unsubscribe() {} } } }; },
      signInWithPassword: () => Promise.resolve({ data: { user: user() }, error: null }),
      signUp: () => Promise.resolve({ data: { user: null, session: null }, error: null }),
      signOut() { env.session = null; if (env.authCb) env.authCb('SIGNED_OUT', null); return Promise.resolve({ error: null }); },
      updateUser: () => Promise.resolve({ error: null }),
    },
    storage: { from: () => ({ createSignedUrl: () => Promise.resolve({ data: { signedUrl: 'https://x/y' }, error: null }), upload: () => Promise.resolve({}), remove: () => Promise.resolve({}) }) },
    channel() {
      const ch = { on(type, filter, cb) { env.realtime.push({ table: filter.table, cb }); return ch; }, subscribe() { return ch; } };
      return ch;
    },
  };
}

async function boot(env) {
  const html = fs.readFileSync(path.join(APP, 'index.html'), 'utf8').replace(/<script[\s\S]*?<\/script>/g, '');
  const dom = new JSDOM(html, { url: 'https://edumak.test/', runScripts: 'outside-only', pretendToBeVisual: true });
  const w = dom.window;
  class FakeDate extends RealDate {
    constructor(...a) { if (a.length === 0) super(env.deviceNow()); else super(...a); }
    static now() { return env.deviceNow(); }
  }
  w.Date = FakeDate;
  w.EDUMAK_CONFIG = { SUPABASE_URL: 'https://test.supabase.co', SUPABASE_ANON_KEY: 'test-anon-key' };
  w.supabase = { createClient: () => makeClient(env) };
  w.HTMLDialogElement.prototype.showModal = function () {};
  w.HTMLDialogElement.prototype.close = function () {};
  w.scrollTo = () => {};
  w.confirm = () => env.confirmAnswer;
  w.prompt = (msg, def) => { env.prompts.push({ msg, def }); return env.promptAnswers.length ? env.promptAnswers.shift() : null; };
  w.setInterval = (fn, ms) => { env.intervals.push({ fn, ms }); return env.intervals.length; };
  Object.defineProperty(w.navigator, 'onLine', { get: () => env.online, configurable: true });
  w.eval(fs.readFileSync(path.join(APP, 'app.js'), 'utf8'));
  await settle();
  const doc = w.document;
  const api = {
    dom, w, doc, env,
    $: id => doc.getElementById(id),
    text: id => doc.getElementById(id).textContent.trim(),
    all: sel => Array.from(doc.querySelectorAll(sel)),
    tick() { env.intervals.filter(i => i.ms === 1000).forEach(i => i.fn()); },
    async click(sel) { const el = typeof sel === 'string' ? doc.querySelector(sel) : sel; el.click(); await settle(); },
    async type(id, value) { const el = doc.getElementById(id); el.value = value; el.dispatchEvent(new w.Event('input', { bubbles: true })); await settle(); },
    toast: () => doc.getElementById('toast').textContent,
    close() { dom.window.close(); },
  };
  return api;
}

module.exports = { createEnv, boot, settle, iso, RealDate };
