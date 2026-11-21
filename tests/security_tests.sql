-- EduFlow AI security & business-rule tests. Every line printed must say PASS.
-- Run: tests/run_local.sh   (uses plain PostgreSQL + tests/supabase_mock.sql)
\set QUIET on
\pset tuples_only on
\pset format unaligned

-- helper: become a user (or anon / automation) for the current transaction
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce((select id::text from auth.users where email = p_email), ''), true);
end $$;

-- 1. Tenant isolation ------------------------------------------------------
begin; select pg_temp.as_user('admin@mwangaza.demo'); set local role authenticated;
select case when (select count(*) from students) = 48 then 'PASS' else 'FAIL' end || '  T01 Mwangaza admin sees all 48 of their students';
select case when (select count(distinct school_id) from admissions_enquiries) = 1 then 'PASS' else 'FAIL' end || '  T02 Mwangaza admin sees no Baraka enquiries';
select case when (select count(*) from v_school_dashboard) = 1 then 'PASS' else 'FAIL' end || '  T03 dashboard view returns only the user''s own school';
rollback;

begin; select pg_temp.as_user('admin@baraka.demo'); set local role authenticated;
select case when (select count(*) from students) = 0 and (select count(*) from admissions_enquiries) = 1 then 'PASS' else 'FAIL' end || '  T04 Baraka admin cannot see Mwangaza learners';
select case when (select count(*) from payments) = 0 and (select count(*) from v_fee_balances) = 0 then 'PASS' else 'FAIL' end || '  T05 Baraka admin cannot see Mwangaza finances';
rollback;

-- 2. Role separation -------------------------------------------------------
begin; select pg_temp.as_user('teacher@mwangaza.demo'); set local role authenticated;
select case when (select count(*) from students) = 6 then 'PASS' else 'FAIL' end || '  T06 teacher sees only the 6 learners in their class';
select case when (select count(*) from student_fee_accounts) = 0 and (select count(*) from admissions_enquiries) = 0 then 'PASS' else 'FAIL' end || '  T07 teacher sees no fees and no enquiries';
rollback;

begin; select pg_temp.as_user('bursar@mwangaza.demo'); set local role authenticated;
select case when (select count(*) from v_fee_balances) = 48 then 'PASS' else 'FAIL' end || '  T08 bursar sees all fee balances';
select case when (select count(*) from admissions_enquiries) = 0 and (select count(*) from applications) = 0 then 'PASS' else 'FAIL' end || '  T09 bursar cannot see admissions';
rollback;

begin; select pg_temp.as_user('admissions@mwangaza.demo'); set local role authenticated;
select case when (select count(*) from payments) = 0 then 'PASS' else 'FAIL' end || '  T10 admissions officer cannot see payments';
rollback;

-- 3. Anonymous access -----------------------------------------------------
begin; select pg_temp.as_user(null); set local role anon;
do $$ begin perform count(*) from public.students; raise notice 'FAIL  T11 anon can read students';
exception when insufficient_privilege then raise notice 'PASS  T11 anon cannot read any table'; end $$;
do $$ begin perform public.create_reminder_batch('11111111-1111-4111-8111-111111111111'); raise notice 'FAIL  T12 anon ran reminder batch';
exception when insufficient_privilege then raise notice 'PASS  T12 anon cannot trigger fee reminders'; end $$;
rollback;

-- 4. Public enquiry RPC -----------------------------------------------------
begin; set local role anon;
select case when (public.submit_enquiry('mwangaza-junior','Test Parent','0712 345 678',null,'Amina',6,'Grade 1','January 2027','Hello',true)->>'reference') like 'EQ-%' then 'PASS' else 'FAIL' end || '  T13 parent can submit an enquiry and gets a reference';
select case when (public.submit_enquiry('mwangaza-junior','Test Parent','+254712345678',null,'amina',6,'Grade 1','January 2027','Again',true)->>'duplicate')::boolean then 'PASS' else 'FAIL' end || '  T14 repeat enquiry (same phone + learner) is merged, not duplicated';
do $$ begin perform public.submit_enquiry('mwangaza-junior','X Y','12345',null,'A',6,null,null,'hi',true); raise notice 'FAIL  T15';
exception when others then raise notice 'PASS  T15 invalid phone rejected: %', sqlerrm; end $$;
do $$ begin perform public.submit_enquiry('mwangaza-junior','X Y','0712345679',null,'A',6,null,null,'hi',false); raise notice 'FAIL  T16';
exception when others then raise notice 'PASS  T16 enquiry without consent rejected: %', sqlerrm; end $$;
reset role;
select case when (select count(*) from admissions_enquiries where parent_phone = '+254712345678') = 1
             and (select merge_count from admissions_enquiries where parent_phone = '+254712345678') = 1 then 'PASS' else 'FAIL' end || '  T17 one row stored, merge counted';
rollback;

-- 5. Applications + documents ---------------------------------------------
begin; set local role anon;
create temp table r on commit drop as
  select public.submit_application('mwangaza-junior', null, 'Tamu', 'Ngugi', '2019-02-02', 'female', 'Grade 2', 'January 2027', null,
                                   'Jane Ngugi', '0722000111', null, true) as j;
select case when jsonb_array_length((select j->'required_documents' from r)) = 3 then 'PASS' else 'FAIL' end || '  T18 application returns the school''s document checklist';
insert into storage.objects (bucket_id, name)
  select 'application-documents', (j->>'school_id') || '/' || (j->>'application_id') || '/' || (j->>'upload_token') || '/bc.pdf' from r;
select 'PASS  T19 applicant can upload into their own folder';
do $$ begin
  insert into storage.objects (bucket_id, name) values ('application-documents', '11111111-1111-4111-8111-111111111111/' || gen_random_uuid() || '/' || gen_random_uuid() || '/x.pdf');
  raise notice 'FAIL  T20 upload with a guessed token allowed';
exception when insufficient_privilege then raise notice 'PASS  T20 upload with a wrong token is blocked'; end $$;
select case when (select count(*) from storage.objects) = 0 then 'PASS' else 'FAIL' end || '  T21 anonymous users cannot list stored documents';
select case when (public.register_application_document((j->>'application_id')::uuid, (j->>'upload_token')::uuid, 'birth_certificate',
          (j->>'school_id') || '/' || (j->>'application_id') || '/' || (j->>'upload_token') || '/bc.pdf', 'bc.pdf', 'application/pdf', 1000)
          ->'missing_documents') = '["passport_photo", "previous_report"]'::jsonb then 'PASS' else 'FAIL' end || '  T22 missing-document list updates after upload'
from r;
rollback;

-- 6. Human-in-the-loop rules against automations (service role, no user) ---
begin; select pg_temp.as_user(null); set local role service_role;
do $$ begin update public.applications set status = 'offered' where learner_first_name = 'Nia'; raise notice 'FAIL  T23';
exception when others then raise notice 'PASS  T23 automation cannot make an admission decision: %', sqlerrm; end $$;
do $$ begin update public.communication_logs set status = 'approved' where status = 'draft'; raise notice 'FAIL  T24';
exception when others then raise notice 'PASS  T24 automation cannot approve a message: %', sqlerrm; end $$;
do $$ begin update public.communication_logs set status = 'sent' where status = 'draft'; raise notice 'FAIL  T25';
exception when others then raise notice 'PASS  T25 automation cannot send an unapproved AI draft: %', sqlerrm; end $$;
do $$ begin insert into public.communication_logs (school_id, direction, channel, body, ai_generated, requires_approval, status)
  values ('11111111-1111-4111-8111-111111111111','outbound','sms','x',true,false,'queued'); raise notice 'FAIL  T26';
exception when check_violation then raise notice 'PASS  T26 AI-written text can never skip approval'; end $$;
insert into public.communication_logs (school_id, direction, channel, body, ai_generated, requires_approval, template_key, status, idempotency_key)
  values ('11111111-1111-4111-8111-111111111111','outbound','sms','Ack template',false,false,'enquiry_ack','sent','ack:test');
select 'PASS  T27 fixed acknowledgement template can be sent automatically';
do $$ begin insert into public.communication_logs (school_id, direction, channel, body, ai_generated, requires_approval, template_key, status, idempotency_key)
  values ('11111111-1111-4111-8111-111111111111','outbound','sms','Ack template',false,false,'enquiry_ack','sent','ack:test'); raise notice 'FAIL  T28';
exception when unique_violation then raise notice 'PASS  T28 idempotency key blocks a duplicate send'; end $$;
do $$ begin insert into public.payments (school_id, fee_account_id, student_id, amount, method, reference, status)
  select school_id, id, student_id, 100, 'mpesa', 'AUTOCONF', 'confirmed' from public.student_fee_accounts limit 1; raise notice 'FAIL  T29';
exception when others then raise notice 'PASS  T29 automation cannot record a confirmed payment: %', sqlerrm; end $$;
insert into public.payments (school_id, fee_account_id, student_id, amount, method, reference, status, source)
  select school_id, id, student_id, 100, 'mpesa', 'AUTOPEND', 'pending', 'mpesa_c2b' from public.student_fee_accounts limit 1;
select 'PASS  T30 automation can add a pending M-Pesa payment for review';
do $$ begin update public.payments set status = 'confirmed' where reference = 'AUTOPEND'; raise notice 'FAIL  T31';
exception when others then raise notice 'PASS  T31 automation cannot confirm a payment: %', sqlerrm; end $$;
rollback;

-- 7. Staff decisions and finance integrity ---------------------------------
begin; select pg_temp.as_user('admissions@mwangaza.demo'); set local role authenticated;
update applications set status = 'offered' where learner_first_name = 'Nia';
select case when (select decided_by is not null and decided_at is not null from applications where learner_first_name = 'Nia') then 'PASS' else 'FAIL' end || '  T32 admissions officer decision is recorded with who and when';
reset role;
select case when exists (select 1 from audit_logs where table_name = 'applications' and actor_type = 'user' and new_data->>'status' = 'offered') then 'PASS' else 'FAIL' end || '  T33 decision written to the audit log';
rollback;

begin; select pg_temp.as_user('bursar@mwangaza.demo'); set local role authenticated;
select case when (select count(*) from applications where status = 'under_review') = 0 then 'PASS' else 'FAIL' end || '  T34 bursar cannot reach applications to decide them';
do $$ begin update public.payments set amount = amount + 1 where status = 'confirmed'; raise notice 'FAIL  T35';
exception when others then raise notice 'PASS  T35 confirmed payment amount cannot be edited: %', sqlerrm; end $$;
do $$ begin update public.payments set status = 'reversed' where reference = 'DEMO000004A'; raise notice 'FAIL  T36';
exception when others then raise notice 'PASS  T36 reversal without a reason is refused: %', sqlerrm; end $$;
update payments set status = 'reversed', reversal_reason = 'Recorded twice' where reference = 'DEMO000004A';
select case when (select status from payments where reference = 'DEMO000004A') = 'reversed' then 'PASS' else 'FAIL' end || '  T37 bursar can reverse with a reason';
do $$ begin delete from public.payments where reference = 'DEMO000004A';
  if not exists (select 1 from public.payments where reference = 'DEMO000004A') then raise notice 'FAIL  T38'; else raise notice 'PASS  T38 payments cannot be deleted'; end if;
exception when others then raise notice 'PASS  T38 payments cannot be deleted'; end $$;
rollback;

-- 8. Fee reminder batch rules ---------------------------------------------
begin; select pg_temp.as_user('bursar@mwangaza.demo'); set local role authenticated;
create temp table b1 on commit drop as select public.create_reminder_batch('11111111-1111-4111-8111-111111111111') as j;
select case when (select (j->>'drafts')::int from b1) > 0 then 'PASS' else 'FAIL' end || '  T39 reminder batch drafts reminders (' || (select j->>'drafts' from b1) || ')';
select case when not exists (select 1 from payment_reminders r join v_fee_balances b on b.fee_account_id = r.fee_account_id where b.balance <= 0) then 'PASS' else 'FAIL' end || '  T40 no reminder for a cleared account';
select case when not exists (select 1 from payment_reminders r join v_fee_balances b on b.fee_account_id = r.fee_account_id where b.amount_pending > 0 or b.reminders_paused) then 'PASS' else 'FAIL' end || '  T41 no reminder where a payment awaits confirmation or reminders are paused';
select case when (public.create_reminder_batch('11111111-1111-4111-8111-111111111111')->>'drafts')::int = 0 then 'PASS' else 'FAIL' end || '  T42 running the batch again creates no duplicates';
select case when (select bool_and(r.message_body like '%KES ' || to_char(r.balance_at_draft, 'FM999,999,990') || '%') from payment_reminders r) then 'PASS' else 'FAIL' end || '  T43 every reminder quotes the database balance exactly';
update payment_reminders set status = 'approved' where id = (select id from payment_reminders limit 1);
select case when (select count(*) from payment_reminders where approved_by is not null) = 1 then 'PASS' else 'FAIL' end || '  T44 approval stamps the approving bursar';
rollback;

begin; select pg_temp.as_user('admissions@mwangaza.demo'); set local role authenticated;
do $$ begin perform public.create_reminder_batch('11111111-1111-4111-8111-111111111111'); raise notice 'FAIL  T45';
exception when others then raise notice 'PASS  T45 admissions officer cannot run fee reminders: %', sqlerrm; end $$;
rollback;

-- 9. Privilege escalation -------------------------------------------------
begin; select pg_temp.as_user('admin@mwangaza.demo'); set local role authenticated;
do $$ begin update public.user_profiles set is_super_admin = true where id = auth.uid(); raise notice 'FAIL  T46';
exception when others then raise notice 'PASS  T46 a user cannot make themselves super admin: %', sqlerrm; end $$;
do $$ begin insert into public.school_memberships (school_id, user_id, role_key)
  values ('22222222-2222-4222-8222-222222222222', auth.uid(), 'school_admin'); raise notice 'FAIL  T47';
exception when insufficient_privilege then raise notice 'PASS  T47 an admin cannot add themselves to another school'; end $$;
do $$ begin update public.announcements set status = 'approved' where title = 'Closing day reminder';
  if (select approved_by from public.announcements where title = 'Closing day reminder') = auth.uid() then raise notice 'PASS  T48 administrator can approve an announcement'; else raise notice 'FAIL  T48'; end if; end $$;
rollback;

begin; select pg_temp.as_user('teacher@mwangaza.demo'); set local role authenticated;
do $$ begin update public.announcements set status = 'approved';
  if exists (select 1 from public.announcements where status = 'approved') then raise notice 'FAIL  T49'; else raise notice 'PASS  T49 teacher cannot approve announcements (no rows reachable)'; end if;
exception when others then raise notice 'PASS  T49 teacher cannot approve announcements: %', sqlerrm; end $$;
rollback;
