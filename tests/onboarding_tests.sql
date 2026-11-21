-- EduFlow AI onboarding tests (migration 005). Every line must say PASS.
\set QUIET on
\pset tuples_only on
\pset format unaligned
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from auth.users where email = p_email), ''), true); end $$;

begin;
insert into auth.users (email) values ('operator@example.com'), ('newstaff@example.com');
update public.user_profiles set is_super_admin = true where email = 'operator@example.com';

-- O01-O03: the operator creates a school and is treated as its administrator
select pg_temp.as_user('operator@example.com'); set local role authenticated;
select case when (public.my_profile()->>'is_super_admin')::boolean then 'PASS' else 'FAIL' end || '  O01 operator sees their own operator flag';
insert into public.schools (name, slug, school_type, status) values ('Pilot Primary School', 'pilot-primary', 'primary', 'active');
select case when (select count(*) from public.schools where slug = 'pilot-primary') = 1 then 'PASS' else 'FAIL' end || '  O02 operator can create a school';
select case when (public.admin_add_member((select id from public.schools where slug = 'pilot-primary'), 'NewStaff@example.com', 'bursar', 'Jane Bursar')->>'status') = 'added' then 'PASS' else 'FAIL' end || '  O03 operator can add an invited person as staff';
select case when (public.admin_add_member((select id from public.schools where slug = 'pilot-primary'), 'nobody@example.com', 'teacher')->>'status') = 'not_found' then 'PASS' else 'FAIL' end || '  O04 adding someone without a login reports not_found';
select case when (select count(*) from public.school_members((select id from public.schools where slug = 'pilot-primary'))) = 1 then 'PASS' else 'FAIL' end || '  O05 operator can list the school''s members';
reset role;

-- O06-O09: limits for everyone else
select pg_temp.as_user('newstaff@example.com'); set local role authenticated;
select case when (select count(*) from public.schools where slug = 'pilot-primary') = 1 then 'PASS' else 'FAIL' end || '  O06 new bursar can now see their school';
select case when (public.my_profile()->>'is_super_admin')::boolean = false then 'PASS' else 'FAIL' end || '  O07 bursar is not an operator';
do $$ begin perform public.admin_add_member((select id from public.schools where slug = 'pilot-primary'), 'operator@example.com', 'school_admin'); raise notice 'FAIL  O08';
exception when others then raise notice 'PASS  O08 a bursar cannot add staff: %', sqlerrm; end $$;
do $$ begin insert into public.schools (name, slug) values ('Rogue School', 'rogue-school'); raise notice 'FAIL  O09';
exception when insufficient_privilege then raise notice 'PASS  O09 only the operator can create schools'; end $$;
select case when (select count(*) from public.school_members((select id from public.schools where slug = 'pilot-primary'))) = 0 then 'PASS' else 'FAIL' end || '  O10 a bursar cannot list staff emails';
reset role;

select pg_temp.as_user('admin@mwangaza.demo'); set local role authenticated;
do $$ begin perform public.admin_add_member((select id from public.schools where slug = 'pilot-primary'), 'admin@mwangaza.demo', 'school_admin'); raise notice 'FAIL  O11';
exception when others then raise notice 'PASS  O11 another school''s admin cannot add themselves here'; end $$;
reset role;

select pg_temp.as_user(null); set local role anon;
do $$ begin perform public.admin_add_member(gen_random_uuid(), 'x@example.com', 'teacher'); raise notice 'FAIL  O12';
exception when insufficient_privilege then raise notice 'PASS  O12 anonymous visitors cannot call onboarding functions'; end $$;
reset role;
rollback;
