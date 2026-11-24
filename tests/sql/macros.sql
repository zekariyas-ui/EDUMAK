-- psql role-switch macros shared by suites.
\set as_super 'reset role;'
\set as_anon  'reset role; set role anon; select set_config(''request.jwt.claim.sub'','''',false);'
\set as_admin 'reset role; set role authenticated; select set_config(''request.jwt.claim.sub'',''00000000-0000-0000-0000-0000000000a1'',false);'
\set as_s1    'reset role; set role authenticated; select set_config(''request.jwt.claim.sub'',''00000000-0000-0000-0000-0000000000b1'',false);'
\set as_s2    'reset role; set role authenticated; select set_config(''request.jwt.claim.sub'',''00000000-0000-0000-0000-0000000000b2'',false);'
\set as_s3    'reset role; set role authenticated; select set_config(''request.jwt.claim.sub'',''00000000-0000-0000-0000-0000000000b3'',false);'

