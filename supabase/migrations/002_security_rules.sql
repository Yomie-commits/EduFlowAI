-- =====================================================================
-- EduFlow AI  |  Migration 002: security, business rules, RPCs, views
--
-- Principles enforced HERE, in the database (never only in the frontend):
--   1. Tenant isolation: a user only sees rows of schools they belong to.
--   2. Role-based access: each table is readable/writable by named groups.
--   3. Human-in-the-loop: automations (service role, auth.uid() is null)
--      can never approve a message, make an admission decision, or confirm
--      or alter a confirmed payment.
--   4. Everything sensitive is written to audit_logs.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Role groups (edit here to change who can do what)
-- ---------------------------------------------------------------------
create or replace function app.group_roles(p_group text) returns text[]
language sql immutable as $$
  select case p_group
    when 'admin'      then array['school_admin']
    when 'leaders'    then array['school_admin','head_teacher']
    when 'admissions' then array['school_admin','head_teacher','admissions_officer']
    when 'finance'    then array['school_admin','head_teacher','bursar']
    when 'fin_write'  then array['school_admin','bursar']
    when 'office'     then array['school_admin','head_teacher','admissions_officer','bursar']
    when 'staff'      then array['school_admin','head_teacher','admissions_officer','bursar','teacher']
    when 'members'    then array['school_admin','head_teacher','admissions_officer','bursar','teacher','parent']
    else array[]::text[]
  end;
$$;

create or replace function app.is_super_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_super_admin from public.user_profiles where id = auth.uid()), false);
$$;

create or replace function app.in_group(p_school uuid, p_group text) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
    app.is_super_admin() or exists (
      select 1 from public.school_memberships m
      where m.school_id = p_school
        and m.user_id = auth.uid()
        and m.status = 'active'
        and m.role_key = any (app.group_roles(p_group))));
$$;

-- Parent helpers (portal phase): students linked to the signed-in guardian
create or replace function app.my_student_ids() returns setof uuid
language sql stable security definer set search_path = public as $$
  select sg.student_id
  from public.student_guardians sg
  join public.parents_guardians g on g.id = sg.guardian_id
  where g.user_id = auth.uid();
$$;

-- Teacher helper: classes where the signed-in user is the class teacher
create or replace function app.my_class_ids() returns setof uuid
language sql stable security definer set search_path = public as $$
  select c.id from public.classes c
  join public.staff s on s.id = c.class_teacher_id
  where s.user_id = auth.uid();
$$;

revoke all on function app.in_group(uuid, text) from public;
grant usage on schema app to authenticated, anon, service_role;
grant execute on function app.in_group(uuid, text), app.is_super_admin(), app.group_roles(text),
                          app.my_student_ids(), app.my_class_ids() to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Standard policies: (table, read group, write group)
-- write = insert + update. Delete is only granted where listed below.
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select * from (values
    ('staff',                 'staff',      'admin'),
    ('classes',               'staff',      'admin'),
    ('admissions_enquiries',  'admissions', 'admissions'),
    ('applications',          'admissions', 'admissions'),
    ('application_documents', 'admissions', 'admissions'),
    ('fee_structures',        'finance',    'fin_write'),
    ('student_fee_accounts',  'finance',    'fin_write'),
    ('invoices',              'finance',    'fin_write'),
    ('payments',              'finance',    'fin_write'),
    ('payment_reminders',     'finance',    'fin_write'),
    ('communication_logs',    'office',     'office'),
    ('school_events',         'members',    'leaders'),
    ('automation_logs',       'leaders',    'none'),
    ('audit_logs',            'leaders',    'none'),
    ('ai_interaction_logs',   'leaders',    'office')
  ) as t(tbl, read_grp, write_grp)
  loop
    execute format('alter table public.%I enable row level security', r.tbl);
    execute format('create policy %I on public.%I for select to authenticated using (app.in_group(school_id, %L))',
                   r.tbl || '_read', r.tbl, r.read_grp);
    if r.write_grp <> 'none' then
      execute format('create policy %I on public.%I for insert to authenticated with check (app.in_group(school_id, %L))',
                     r.tbl || '_insert', r.tbl, r.write_grp);
      execute format('create policy %I on public.%I for update to authenticated using (app.in_group(school_id, %L)) with check (app.in_group(school_id, %L))',
                     r.tbl || '_update', r.tbl, r.write_grp, r.write_grp);
    end if;
  end loop;
end $$;

-- Deletes (kept deliberately narrow; financial rows are never deleted, only reversed)
create policy enquiries_delete     on public.admissions_enquiries for delete to authenticated using (app.in_group(school_id, 'admin'));
create policy app_docs_delete      on public.application_documents for delete to authenticated using (app.in_group(school_id, 'admissions'));
create policy events_delete        on public.school_events for delete to authenticated using (app.in_group(school_id, 'leaders'));
create policy fee_structure_delete on public.fee_structures for delete to authenticated using (app.in_group(school_id, 'fin_write'));

-- ---------------------------------------------------------------------
-- Custom policies
-- ---------------------------------------------------------------------
-- schools: members read their school; admins edit it; only super admins create/delete
alter table public.schools enable row level security;
create policy schools_read   on public.schools for select to authenticated using (app.in_group(id, 'members'));
create policy schools_update on public.schools for update to authenticated using (app.in_group(id, 'admin')) with check (app.in_group(id, 'admin'));
create policy schools_insert on public.schools for insert to authenticated with check (app.is_super_admin());
create policy schools_delete on public.schools for delete to authenticated using (app.is_super_admin());

-- reference tables: read-only for signed-in users
alter table public.roles enable row level security;
alter table public.permissions enable row level security;
alter table public.role_permissions enable row level security;
create policy roles_read on public.roles for select to authenticated using (true);
create policy permissions_read on public.permissions for select to authenticated using (true);
create policy role_permissions_read on public.role_permissions for select to authenticated using (true);

-- user_profiles: yourself, plus colleagues in a school where you are office staff
alter table public.user_profiles enable row level security;
create policy profiles_read on public.user_profiles for select to authenticated using (
  id = auth.uid() or app.is_super_admin() or exists (
    select 1 from public.school_memberships m
    where m.user_id = user_profiles.id and app.in_group(m.school_id, 'staff')));
create policy profiles_update_self on public.user_profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- Users can never grant themselves super admin
create or replace function app.protect_profile() returns trigger
language plpgsql as $$
begin
  if new.is_super_admin is distinct from old.is_super_admin and auth.uid() is not null and not app.is_super_admin() then
    raise exception 'Only a platform super administrator can change is_super_admin';
  end if;
  return new;
end $$;
create trigger protect_profile before update on public.user_profiles
  for each row execute function app.protect_profile();

-- school_memberships: see your own; school admins manage their school's staff
alter table public.school_memberships enable row level security;
create policy memberships_read on public.school_memberships for select to authenticated
  using (user_id = auth.uid() or app.in_group(school_id, 'leaders'));
create policy memberships_insert on public.school_memberships for insert to authenticated with check (app.in_group(school_id, 'admin'));
create policy memberships_update on public.school_memberships for update to authenticated
  using (app.in_group(school_id, 'admin')) with check (app.in_group(school_id, 'admin'));
create policy memberships_delete on public.school_memberships for delete to authenticated using (app.in_group(school_id, 'admin'));

-- students: office staff see all; teachers see their classes; parents see their own children
alter table public.students enable row level security;
create policy students_read on public.students for select to authenticated using (
  app.in_group(school_id, 'office')
  or (app.in_group(school_id, 'staff') and class_id in (select app.my_class_ids()))
  or id in (select app.my_student_ids()));
create policy students_insert on public.students for insert to authenticated with check (app.in_group(school_id, 'admissions'));
create policy students_update on public.students for update to authenticated
  using (app.in_group(school_id, 'admissions')) with check (app.in_group(school_id, 'admissions'));

-- guardians and links: office staff; a parent sees their own record
alter table public.parents_guardians enable row level security;
create policy guardians_read on public.parents_guardians for select to authenticated
  using (app.in_group(school_id, 'office') or user_id = auth.uid());
create policy guardians_insert on public.parents_guardians for insert to authenticated with check (app.in_group(school_id, 'office'));
create policy guardians_update on public.parents_guardians for update to authenticated
  using (app.in_group(school_id, 'office')) with check (app.in_group(school_id, 'office'));

alter table public.student_guardians enable row level security;
create policy student_guardians_read on public.student_guardians for select to authenticated
  using (app.in_group(school_id, 'office') or student_id in (select app.my_student_ids()));
create policy student_guardians_write on public.student_guardians for insert to authenticated with check (app.in_group(school_id, 'admissions'));
create policy student_guardians_update on public.student_guardians for update to authenticated
  using (app.in_group(school_id, 'admissions')) with check (app.in_group(school_id, 'admissions'));
create policy student_guardians_delete on public.student_guardians for delete to authenticated using (app.in_group(school_id, 'admissions'));

-- Parents: read-only view of their own children's fee accounts and payments (portal phase)
create policy fee_accounts_parent_read on public.student_fee_accounts for select to authenticated
  using (student_id in (select app.my_student_ids()));
create policy payments_parent_read on public.payments for select to authenticated
  using (student_id in (select app.my_student_ids()) and status = 'confirmed');

-- attendance: leaders read all; teachers read/write their own classes; parents read own children
alter table public.attendance_records enable row level security;
create policy attendance_read on public.attendance_records for select to authenticated using (
  app.in_group(school_id, 'leaders')
  or (app.in_group(school_id, 'staff') and class_id in (select app.my_class_ids()))
  or student_id in (select app.my_student_ids()));
create policy attendance_insert on public.attendance_records for insert to authenticated with check (
  app.in_group(school_id, 'leaders') or (app.in_group(school_id, 'staff') and class_id in (select app.my_class_ids())));
create policy attendance_update on public.attendance_records for update to authenticated
  using (app.in_group(school_id, 'leaders') or (app.in_group(school_id, 'staff') and class_id in (select app.my_class_ids())))
  with check (app.in_group(school_id, 'leaders') or (app.in_group(school_id, 'staff') and class_id in (select app.my_class_ids())));

-- staff tasks: leaders see all; staff see tasks assigned to or created by them
alter table public.staff_tasks enable row level security;
create policy tasks_read on public.staff_tasks for select to authenticated using (
  app.in_group(school_id, 'leaders')
  or (app.in_group(school_id, 'staff') and (assigned_to = auth.uid() or created_by = auth.uid())));
create policy tasks_insert on public.staff_tasks for insert to authenticated with check (app.in_group(school_id, 'staff'));
create policy tasks_update on public.staff_tasks for update to authenticated
  using (app.in_group(school_id, 'leaders') or (app.in_group(school_id, 'staff') and (assigned_to = auth.uid() or created_by = auth.uid())))
  with check (app.in_group(school_id, 'staff'));

-- announcements: staff read; office drafts; parents read sent whole-school ones (portal)
alter table public.announcements enable row level security;
create policy announcements_read on public.announcements for select to authenticated using (
  app.in_group(school_id, 'staff') or (app.in_group(school_id, 'members') and status = 'sent' and audience = 'whole_school'));
create policy announcements_insert on public.announcements for insert to authenticated with check (app.in_group(school_id, 'office'));
create policy announcements_update on public.announcements for update to authenticated
  using (app.in_group(school_id, 'office')) with check (app.in_group(school_id, 'office'));

-- notifications: only your own
alter table public.notifications enable row level security;
create policy notifications_read on public.notifications for select to authenticated using (user_id = auth.uid());
create policy notifications_update on public.notifications for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------------------------------------------------------------------
-- Business-rule triggers (apply to EVERYONE, including Make's service role)
-- ---------------------------------------------------------------------

-- R1. Admission decisions are human-only, by authorised roles
create or replace function app.guard_application_decision() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status in ('offered','waitlisted','declined','enrolled')
     and (tg_op = 'INSERT' or new.status is distinct from old.status) then
    if auth.uid() is null then
      raise exception 'Admission decisions must be made by a signed-in staff member, not an automation';
    end if;
    if not app.in_group(new.school_id, 'admissions') then
      raise exception 'Your role cannot make admission decisions';
    end if;
    new.decided_by := auth.uid();
    new.decided_at := now();
  end if;
  return new;
end $$;
create trigger guard_application_decision before insert or update on public.applications
  for each row execute function app.guard_application_decision();

-- R2. Message approval is human-only; sending requires prior approval
--     (or a fixed, pre-approved template that is not AI-generated)
create or replace function app.guard_message_status() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  was text := case when tg_op = 'UPDATE' then old.status else null end;
begin
  if new.status = 'approved' and was is distinct from 'approved' then
    if auth.uid() is null then
      raise exception 'Messages can only be approved by a signed-in staff member';
    end if;
    new.approved_by := auth.uid();
    new.approved_at := now();
  end if;

  if new.status in ('queued','sent','delivered') and new.direction = 'outbound' and new.requires_approval
     and new.approved_by is null then
    raise exception 'This message needs approval before it can be sent';
  end if;

  if tg_op = 'UPDATE' and old.status in ('sent','delivered') and new.body is distinct from old.body then
    raise exception 'A sent message cannot be edited';
  end if;
  return new;
end $$;
create trigger guard_message_status before insert or update on public.communication_logs
  for each row execute function app.guard_message_status();

create or replace function app.guard_reminder_status() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'approved' and (tg_op = 'INSERT' or old.status is distinct from 'approved') then
    if auth.uid() is null then
      raise exception 'Fee reminders can only be approved by a signed-in staff member';
    end if;
    if not app.in_group(new.school_id, 'fin_write') then
      raise exception 'Only the bursar or school administrator can approve fee reminders';
    end if;
    new.approved_by := auth.uid();
    new.approved_at := now();
  end if;
  if new.status = 'sent' and new.approved_by is null then
    raise exception 'Fee reminder was not approved';
  end if;
  return new;
end $$;
create trigger guard_reminder_status before insert or update on public.payment_reminders
  for each row execute function app.guard_reminder_status();

create or replace function app.guard_announcement_status() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'approved' and (tg_op = 'INSERT' or old.status is distinct from 'approved') then
    if auth.uid() is null or not app.in_group(new.school_id, 'leaders') then
      raise exception 'Announcements must be approved by the school administrator or head teacher';
    end if;
    new.approved_by := auth.uid();
    new.approved_at := now();
  end if;
  if new.status = 'sent' and new.approved_by is null then
    raise exception 'Announcement was not approved';
  end if;
  return new;
end $$;
create trigger guard_announcement_status before insert or update on public.announcements
  for each row execute function app.guard_announcement_status();

-- R3. Financial integrity: automations may only add PENDING payments;
--     confirmed payments are immutable except a human reversal.
create or replace function app.guard_payment() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if new.status = 'confirmed' then
      if auth.uid() is null then
        raise exception 'Automations cannot record confirmed payments; insert as pending for bursar confirmation';
      end if;
      new.confirmed_by := auth.uid();
      new.confirmed_at := now();
    end if;
    new.recorded_by := coalesce(new.recorded_by, auth.uid());
    return new;
  end if;

  -- UPDATE
  if old.status = 'confirmed' then
    if new.amount is distinct from old.amount or new.fee_account_id is distinct from old.fee_account_id
       or new.student_id is distinct from old.student_id or new.reference is distinct from old.reference
       or new.method is distinct from old.method or new.paid_at is distinct from old.paid_at then
      raise exception 'Confirmed payments cannot be edited. Reverse it and record a new payment.';
    end if;
    if new.status = 'reversed' then
      if auth.uid() is null then raise exception 'Only staff can reverse a payment'; end if;
      if coalesce(new.reversal_reason, '') = '' then raise exception 'A reversal reason is required'; end if;
    elsif new.status <> 'confirmed' then
      raise exception 'A confirmed payment can only be reversed';
    end if;
  elsif old.status in ('reversed','rejected') and new is distinct from old then
    raise exception 'Reversed or rejected payments are final';
  end if;

  if new.status = 'confirmed' and old.status = 'pending' then
    if auth.uid() is null then
      raise exception 'Automations cannot confirm payments';
    end if;
    new.confirmed_by := auth.uid();
    new.confirmed_at := now();
  end if;
  return new;
end $$;
create trigger guard_payment before insert or update on public.payments
  for each row execute function app.guard_payment();

create or replace function app.block_delete() returns trigger language plpgsql as $$
begin
  raise exception '% rows cannot be deleted; use a status change instead', tg_table_name;
end $$;
create trigger no_delete_payments before delete on public.payments for each row execute function app.block_delete();
create trigger no_delete_audit before delete on public.audit_logs for each row execute function app.block_delete();

-- ---------------------------------------------------------------------
-- Audit trail
-- ---------------------------------------------------------------------
create or replace function app.audit() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  rec jsonb := to_jsonb(coalesce(new, old));
begin
  insert into public.audit_logs (school_id, actor_user_id, actor_type, action, table_name, record_id, old_data, new_data)
  values ((rec->>'school_id')::uuid,
          auth.uid(),
          case when auth.uid() is null then 'automation' else 'user' end,
          tg_op, tg_table_name, (rec->>'id')::uuid,
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end);
  return coalesce(new, old);
end $$;

do $$
declare t text;
begin
  foreach t in array array['applications','payments','student_fee_accounts','fee_structures','school_memberships',
                           'communication_logs','payment_reminders','announcements','students','schools']
  loop
    execute format('create trigger audit_%1$s after insert or update or delete on public.%1$I
                    for each row execute function app.audit()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Views (security_invoker = RLS of the person asking applies)
-- ---------------------------------------------------------------------
create view public.v_fee_balances with (security_invoker = true) as
select a.id as fee_account_id, a.school_id, a.student_id, a.academic_year, a.term, a.due_date,
       a.amount_billed, a.discount, a.reminders_paused,
       coalesce(sum(p.amount) filter (where p.status = 'confirmed'), 0)::numeric(12,2) as amount_paid,
       coalesce(sum(p.amount) filter (where p.status = 'pending'), 0)::numeric(12,2)   as amount_pending,
       (a.amount_billed - a.discount - coalesce(sum(p.amount) filter (where p.status = 'confirmed'), 0))::numeric(12,2) as balance
from public.student_fee_accounts a
left join public.payments p on p.fee_account_id = a.id
group by a.id;

create view public.v_school_dashboard with (security_invoker = true) as
select s.id as school_id, s.name,
  (select count(*) from public.students st where st.school_id = s.id and st.status = 'enrolled')                      as enrolled_students,
  (select count(*) from public.admissions_enquiries e where e.school_id = s.id and e.status in ('new','acknowledged')) as open_enquiries,
  (select count(*) from public.admissions_enquiries e where e.school_id = s.id and e.created_at > now() - interval '7 days') as enquiries_7d,
  (select count(*) from public.admissions_enquiries e where e.school_id = s.id and e.status in ('new','acknowledged','in_progress')
                                                       and e.follow_up_due_at < now())                              as overdue_follow_ups,
  (select count(*) from public.applications a where a.school_id = s.id and a.status in ('submitted','incomplete','complete','under_review','assessment')) as pending_applications,
  (select count(*) from public.applications a where a.school_id = s.id and a.status = 'incomplete')                  as incomplete_applications,
  (select coalesce(sum(b.balance), 0) from public.v_fee_balances b where b.school_id = s.id and b.balance > 0 and b.due_date < current_date) as overdue_fees,
  (select count(*) from public.communication_logs c where c.school_id = s.id and c.status = 'draft' and c.direction = 'outbound') as messages_awaiting_approval,
  (select count(*) from public.payment_reminders r where r.school_id = s.id and r.status = 'draft')                  as reminders_awaiting_approval,
  (select count(*) from public.staff_tasks t where t.school_id = s.id and t.status in ('open','in_progress'))         as open_tasks
from public.schools s;

grant select on public.v_fee_balances, public.v_school_dashboard to authenticated;

-- ---------------------------------------------------------------------
-- Public RPCs (callable by anonymous parents from the school's forms)
-- They validate, de-duplicate and store; nothing else is exposed.
-- ---------------------------------------------------------------------
create or replace function app.normalise_phone(p text) returns text
language sql immutable as $$
  select case
    when p is null or btrim(p) = '' then null
    when regexp_replace(p, '[^0-9+]', '', 'g') ~ '^\+?254[17][0-9]{8}$'
      then '+' || ltrim(regexp_replace(p, '[^0-9]', '', 'g'), '+')
    when regexp_replace(p, '[^0-9]', '', 'g') ~ '^0[17][0-9]{8}$'
      then '+254' || substr(regexp_replace(p, '[^0-9]', '', 'g'), 2)
    else 'INVALID'
  end;
$$;

create or replace function public.submit_enquiry(
  p_school_slug text, p_parent_name text, p_parent_phone text, p_parent_email text,
  p_learner_first_name text, p_learner_age int, p_grade_sought text, p_intake text,
  p_message text, p_consent boolean, p_source text default 'web_form'
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_school  public.schools;
  v_phone   text := app.normalise_phone(p_parent_phone);
  v_email   text := nullif(lower(btrim(p_parent_email)), '');
  v_dup     public.admissions_enquiries;
  v_new     public.admissions_enquiries;
begin
  select * into v_school from public.schools where slug = p_school_slug and status in ('onboarding','active');
  if not found then raise exception 'School not found' using errcode = 'P0002'; end if;
  if coalesce(p_consent, false) = false then raise exception 'Consent is required to process your enquiry'; end if;
  if length(btrim(coalesce(p_parent_name, ''))) < 2 then raise exception 'Please enter your name'; end if;
  if v_phone = 'INVALID' then raise exception 'Please enter a valid Kenyan phone number, e.g. 0712 345 678'; end if;
  if v_phone is null and v_email is null then raise exception 'Please give a phone number or email address'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Please enter a valid email address'; end if;
  if length(coalesce(p_message, '')) > 2000 then raise exception 'Message is too long (2000 characters max)'; end if;

  -- simple abuse limit: 5 submissions per contact per day per school
  if (select count(*) from public.admissions_enquiries
      where school_id = v_school.id and created_at > now() - interval '1 day'
        and (parent_phone = v_phone or parent_email = v_email)) >= 5 then
    raise exception 'Too many submissions today. The school will contact you.';
  end if;

  -- duplicate: same contact + same learner within 30 days, still open -> merge
  select * into v_dup from public.admissions_enquiries
  where school_id = v_school.id
    and (parent_phone = v_phone or (v_email is not null and parent_email = v_email))
    and lower(coalesce(learner_first_name, '')) = lower(btrim(coalesce(p_learner_first_name, '')))
    and status not in ('closed','spam','converted')
    and created_at > now() - interval '30 days'
  order by created_at desc limit 1;

  if found then
    update public.admissions_enquiries
       set message = left(coalesce(message, '') || E'\n\n[Follow-up ' || to_char(now() at time zone 'Africa/Nairobi', 'DD Mon HH24:MI') || '] '
                     || coalesce(p_message, ''), 4000),
           merge_count = merge_count + 1
     where id = v_dup.id;
    return jsonb_build_object('reference', v_dup.reference, 'enquiry_id', v_dup.id, 'duplicate', true, 'school', v_school.name);
  end if;

  insert into public.admissions_enquiries
    (school_id, source, parent_name, parent_phone, parent_email, learner_first_name, learner_age,
     grade_sought, intake, message, consent_given, consent_at, follow_up_due_at)
  values
    (v_school.id, coalesce(p_source, 'web_form'), btrim(p_parent_name), v_phone, v_email, nullif(btrim(p_learner_first_name), ''),
     p_learner_age, nullif(btrim(p_grade_sought), ''), nullif(btrim(p_intake), ''), p_message, true, now(),
     now() + interval '24 hours')
  returning * into v_new;

  return jsonb_build_object('reference', v_new.reference, 'enquiry_id', v_new.id, 'duplicate', false, 'school', v_school.name);
end $$;

create or replace function app.refresh_missing_documents(p_application uuid) returns text[]
language plpgsql security definer set search_path = public as $$
declare
  v_app public.applications;
  v_required text[];
  v_missing  text[];
begin
  select * into v_app from public.applications where id = p_application;
  select array(select jsonb_array_elements_text(s.settings->'required_documents'))
    into v_required from public.schools s where s.id = v_app.school_id;
  select coalesce(array_agg(r), '{}') into v_missing
  from unnest(v_required) r
  where not exists (select 1 from public.application_documents d
                    where d.application_id = p_application and d.document_type = r
                      and d.verification_status <> 'rejected');
  update public.applications
     set missing_documents = v_missing,
         status = case when status in ('submitted','incomplete','complete')
                       then case when cardinality(v_missing) = 0 then 'complete' else 'incomplete' end
                       else status end
   where id = p_application;
  return v_missing;
end $$;

create or replace function public.submit_application(
  p_school_slug text, p_enquiry_reference text,
  p_learner_first_name text, p_learner_last_name text, p_date_of_birth date, p_gender text,
  p_grade_applied text, p_intake text, p_previous_school text,
  p_parent_name text, p_parent_phone text, p_parent_email text, p_consent boolean
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_school  public.schools;
  v_phone   text := app.normalise_phone(p_parent_phone);
  v_email   text := nullif(lower(btrim(p_parent_email)), '');
  v_enq     uuid;
  v_app     public.applications;
begin
  select * into v_school from public.schools where slug = p_school_slug and status in ('onboarding','active');
  if not found then raise exception 'School not found'; end if;
  if coalesce(p_consent, false) = false then raise exception 'Consent is required to process your application'; end if;
  if v_phone = 'INVALID' then raise exception 'Please enter a valid Kenyan phone number'; end if;
  if v_phone is null and v_email is null then raise exception 'Please give a phone number or email address'; end if;
  if length(btrim(coalesce(p_learner_first_name,''))) < 1 or length(btrim(coalesce(p_learner_last_name,''))) < 1
     or length(btrim(coalesce(p_parent_name,''))) < 2 or coalesce(btrim(p_grade_applied),'') = '' then
    raise exception 'Please complete all required fields';
  end if;
  if p_date_of_birth is not null and (p_date_of_birth > current_date or p_date_of_birth < current_date - interval '25 years') then
    raise exception 'Please check the date of birth';
  end if;

  -- prevent double submission of the same learner within 30 days
  if exists (select 1 from public.applications
             where school_id = v_school.id and lower(learner_first_name) = lower(btrim(p_learner_first_name))
               and lower(learner_last_name) = lower(btrim(p_learner_last_name))
               and (parent_phone = v_phone or parent_email = v_email)
               and created_at > now() - interval '30 days' and status <> 'withdrawn') then
    raise exception 'An application for this learner was already received. The school will contact you.';
  end if;

  select id into v_enq from public.admissions_enquiries
  where school_id = v_school.id and reference = upper(btrim(p_enquiry_reference));

  insert into public.applications
    (school_id, enquiry_id, learner_first_name, learner_last_name, date_of_birth, gender, grade_applied, intake,
     previous_school, parent_name, parent_phone, parent_email, consent_given)
  values
    (v_school.id, v_enq, btrim(p_learner_first_name), btrim(p_learner_last_name), p_date_of_birth,
     nullif(p_gender, ''), btrim(p_grade_applied), nullif(btrim(p_intake), ''), nullif(btrim(p_previous_school), ''),
     btrim(p_parent_name), v_phone, v_email, true)
  returning * into v_app;

  if v_enq is not null then
    update public.admissions_enquiries set status = 'converted' where id = v_enq;
  end if;

  perform app.refresh_missing_documents(v_app.id);

  return jsonb_build_object(
    'reference', v_app.reference, 'application_id', v_app.id, 'upload_token', v_app.upload_token,
    'school_id', v_school.id, 'school', v_school.name,
    'required_documents', v_school.settings->'required_documents');
end $$;

create or replace function public.register_application_document(
  p_application_id uuid, p_upload_token uuid, p_document_type text, p_storage_path text,
  p_file_name text, p_mime_type text, p_size_bytes int
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_app public.applications;
  v_missing text[];
begin
  select * into v_app from public.applications
  where id = p_application_id and upload_token = p_upload_token
    and status in ('submitted','incomplete','complete') and created_at > now() - interval '30 days';
  if not found then raise exception 'Upload link is not valid or has expired'; end if;
  if p_storage_path not like v_app.school_id || '/' || v_app.id || '/' || v_app.upload_token || '/%' then
    raise exception 'Invalid file location';
  end if;
  if p_mime_type not in ('application/pdf','image/jpeg','image/png') then
    raise exception 'Only PDF, JPG or PNG files are accepted';
  end if;
  if not exists (select 1 from public.schools s, jsonb_array_elements_text(s.settings->'required_documents') d
                 where s.id = v_app.school_id and d = p_document_type) and p_document_type <> 'other' then
    raise exception 'Unknown document type';
  end if;

  insert into public.application_documents (school_id, application_id, document_type, storage_path, file_name, mime_type, size_bytes)
  values (v_app.school_id, v_app.id, p_document_type, p_storage_path, left(p_file_name, 200), p_mime_type, p_size_bytes);

  v_missing := app.refresh_missing_documents(v_app.id);
  return jsonb_build_object('missing_documents', to_jsonb(v_missing));
end $$;

-- Staff/automation: build a reminder batch from the school's own rules.
-- The balance comes from the database. The message is a template; Make may
-- ask the AI to polish the tone of the sentence around {{balance}} only.
create or replace function public.create_reminder_batch(p_school uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_school   public.schools;
  v_interval int;
  v_grace    int;
  v_batch    uuid := gen_random_uuid();
  v_count    int;
begin
  if auth.uid() is not null and not app.in_group(p_school, 'fin_write') then
    raise exception 'Not allowed';
  end if;
  select * into v_school from public.schools where id = p_school;
  v_interval := coalesce((v_school.settings->>'reminder_interval_days')::int, 7);
  v_grace    := coalesce((v_school.settings->>'reminder_grace_days')::int, 3);

  insert into public.payment_reminders (school_id, batch_id, fee_account_id, guardian_id, balance_at_draft, channel, message_body)
  select b.school_id, v_batch, b.fee_account_id, g.id, b.balance,
         case when g.preferred_channel = 'email' and g.email is not null then 'email' else 'sms' end,
         case when g.preferred_language = 'sw' then
           format('Habari %s. Huu ni ukumbusho wa kirafiki kutoka %s kwamba salio la karo ya muhula wa %s kwa %s ni KES %s. Kama tayari umelipa, tafadhali puuza ujumbe huu. Asante.',
                  g.full_name, v_school.name, b.term, st.first_name, to_char(b.balance, 'FM999,999,990'))
         else
           format('Dear %s, this is a friendly reminder from %s that the Term %s fee balance for %s is KES %s. If you have already paid, please ignore this message. Thank you.',
                  g.full_name, v_school.name, b.term, st.first_name, to_char(b.balance, 'FM999,999,990'))
         end
  from public.v_fee_balances b
  join public.students st on st.id = b.student_id and st.status = 'enrolled'
  join public.student_guardians sg on sg.student_id = b.student_id and sg.is_fee_payer
  join public.parents_guardians g on g.id = sg.guardian_id
  where b.school_id = p_school
    and b.balance > 0
    and b.amount_pending = 0                                   -- payment awaiting confirmation: do not chase
    and not b.reminders_paused
    and b.due_date + v_grace < current_date
    and (g.phone is not null or g.email is not null)
    and not exists (select 1 from public.payment_reminders r
                    where r.fee_account_id = b.fee_account_id
                      and (r.status in ('draft','approved')
                           or (r.status = 'sent' and r.sent_at > now() - make_interval(days => v_interval))));
  get diagnostics v_count = row_count;
  return jsonb_build_object('batch_id', v_batch, 'drafts', v_count);
end $$;

-- What the public forms may know about a school: name, type, document checklist. Nothing else.
create or replace function public.get_public_school(p_school_slug text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('name', name, 'school_type', school_type, 'required_documents', settings->'required_documents')
  from public.schools where slug = p_school_slug and status in ('onboarding','active');
$$;
grant execute on function public.get_public_school(text) to anon, authenticated;

grant execute on function public.submit_enquiry(text,text,text,text,text,int,text,text,text,boolean,text) to anon, authenticated;
grant execute on function public.submit_application(text,text,text,text,date,text,text,text,text,text,text,text,boolean) to anon, authenticated;
grant execute on function public.register_application_document(uuid,uuid,text,text,text,text,int) to anon, authenticated;
-- anon and automations both have auth.uid() = null, so the reminder batch
-- must never be callable by anon (PUBLIC holds EXECUTE by default).
revoke execute on function public.create_reminder_batch(uuid) from public, anon;
grant execute on function public.create_reminder_batch(uuid) to authenticated, service_role;

-- Private helpers: nobody calls these directly except as granted
revoke execute on all functions in schema app from public;
grant execute on function app.in_group(uuid, text), app.is_super_admin(), app.group_roles(text),
                          app.my_student_ids(), app.my_class_ids(), app.next_reference(text),
                          app.normalise_phone(text) to authenticated, service_role;
grant usage on sequence app.reference_seq to authenticated, service_role;

-- Default privileges: anon gets nothing on tables (forms go through RPCs above)
revoke all on all tables in schema public from anon;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant all on all tables in schema public to service_role;
