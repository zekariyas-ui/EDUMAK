-- Shared test helpers (scratch Postgres). Included by the suites with \ir.
create schema t;
create table t.results(n serial primary key, name text not null, ok boolean not null, detail text);
create function t.record(p_name text, p_ok boolean, p_detail text) returns void
  language sql security definer as $$ insert into t.results(name, ok, detail) values (p_name, coalesce(p_ok,false), p_detail) $$;
create function t.ok(p_ok boolean, p_name text) returns void language sql as $$ select t.record(p_name, p_ok, null) $$;
create function t.fails(p_sql text, p_frag text, p_name text) returns void language plpgsql as $$
declare v_msg text;
begin
  begin
    execute p_sql;
    perform t.record(p_name, false, 'expected an error containing "'||p_frag||'" but none was raised');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform t.record(p_name, position(lower(p_frag) in lower(v_msg)) > 0, 'error was: '||v_msg);
  end;
end $$;
create function t.works(p_sql text, p_name text) returns void language plpgsql as $$
declare v_msg text;
begin
  begin execute p_sql; perform t.record(p_name, true, null);
  exception when others then get stacked diagnostics v_msg = message_text;
    perform t.record(p_name, false, 'unexpected error: '||v_msg); end;
end $$;
create function t.affected(p_sql text) returns integer language plpgsql as $$
declare n integer; begin execute p_sql; get diagnostics n = row_count; return n; end $$;
grant usage on schema t to anon, authenticated;

\set as_super 'reset role;'
\set as_anon  'reset role; set role anon; select set_config(''request.jwt.claim.sub'','''',false);'
\set as_admin 'reset role; set role authenticated; select set_config(''request.jwt.claim.sub'',''00000000-0000-0000-0000-0000000000a1'',false);'
\set as_s1    'reset role; set role authenticated; select set_config(''request.jwt.claim.sub'',''00000000-0000-0000-0000-0000000000b1'',false);'
\set as_s2    'reset role; set role authenticated; select set_config(''request.jwt.claim.sub'',''00000000-0000-0000-0000-0000000000b2'',false);'
\set as_s3    'reset role; set role authenticated; select set_config(''request.jwt.claim.sub'',''00000000-0000-0000-0000-0000000000b3'',false);'

