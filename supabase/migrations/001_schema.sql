-- =====================================================================
-- EduFlow AI  |  Migration 001: core schema
-- A YomieVerse product. Multi-tenant: every school-owned row carries
-- school_id, and Row Level Security (migration 002) enforces isolation.
-- Run in the Supabase SQL editor, in order: 001, 002, 003, then seed.sql
-- =====================================================================

create extension if not exists pgcrypto;
create schema if not exists app;          -- private helper functions

-- ---------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------
create or replace function app.set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create sequence if not exists app.reference_seq start 1001;

-- Human-friendly references, e.g. EQ-26-01001, AP-26-01002
create or replace function app.next_reference(p_prefix text) returns text
language sql volatile as $$
  select p_prefix || '-' || to_char(now() at time zone 'Africa/Nairobi', 'YY') || '-'
         || lpad(nextval('app.reference_seq')::text, 5, '0');
$$;

-- ---------------------------------------------------------------------
-- 1. Tenancy, identity and access
-- ---------------------------------------------------------------------
create table public.schools (
  id            uuid primary key default gen_random_uuid(),
  name          text not null check (length(name) between 2 and 120),
  slug          text not null unique check (slug ~ '^[a-z0-9-]{3,60}$'),
  school_type   text not null default 'primary'
                check (school_type in ('daycare','kindergarten','primary','secondary','tuition','training','academy')),
  curriculum    text not null default 'CBC',
  county        text,
  phone         text,
  email         text,
  website       text,
  logo_path     text,
  status        text not null default 'onboarding'
                check (status in ('onboarding','active','suspended','closed')),
  -- School-defined rules used by automations (never hard-coded in Make)
  settings      jsonb not null default jsonb_build_object(
                  'required_documents', jsonb_build_array('birth_certificate','passport_photo','previous_report'),
                  'reminder_interval_days', 7,
                  'reminder_grace_days', 3,
                  'enquiry_retention_months', 12,
                  'briefing_hour', 7,
                  'timezone', 'Africa/Nairobi',
                  'default_language', 'en'),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table public.roles (
  key          text primary key,
  name         text not null,
  description  text,
  is_staff     boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table public.permissions (
  key          text primary key,             -- e.g. 'admissions.decide'
  description  text not null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table public.role_permissions (
  role_key        text not null references public.roles(key) on delete cascade,
  permission_key  text not null references public.permissions(key) on delete cascade,
  created_at      timestamptz not null default now(),
  primary key (role_key, permission_key)
);

-- One row per Supabase Auth user (created automatically by trigger below)
create table public.user_profiles (
  id              uuid primary key references auth.users(id) on delete cascade,
  full_name       text,
  email           text,
  phone           text,
  is_super_admin  boolean not null default false,  -- YomieVerse platform staff only
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create table public.school_memberships (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references public.schools(id) on delete cascade,
  user_id     uuid not null references public.user_profiles(id) on delete cascade,
  role_key    text not null references public.roles(key),
  status      text not null default 'active' check (status in ('invited','active','suspended')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (school_id, user_id, role_key),
  check (role_key <> 'super_admin')   -- super admin is platform-level, not per school
);
create index on public.school_memberships (user_id, school_id);

-- ---------------------------------------------------------------------
-- 2. People and classes
-- ---------------------------------------------------------------------
create table public.staff (
  id            uuid primary key default gen_random_uuid(),
  school_id     uuid not null references public.schools(id) on delete cascade,
  user_id       uuid references public.user_profiles(id) on delete set null,
  full_name     text not null,
  staff_number  text,
  job_title     text,
  department    text,
  phone         text,
  email         text,
  status        text not null default 'active' check (status in ('active','on_leave','left')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (school_id, staff_number)
);
create index on public.staff (school_id);

create table public.classes (
  id                uuid primary key default gen_random_uuid(),
  school_id         uuid not null references public.schools(id) on delete cascade,
  name              text not null,                 -- e.g. 'Grade 4 Blue'
  grade             text not null,                 -- e.g. 'PP1', 'Grade 4'
  stream            text,
  academic_year     int  not null check (academic_year between 2020 and 2100),
  class_teacher_id  uuid references public.staff(id) on delete set null,
  capacity          int check (capacity > 0),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (school_id, name, academic_year)
);

create table public.students (
  id                uuid primary key default gen_random_uuid(),
  school_id         uuid not null references public.schools(id) on delete cascade,
  admission_number  text,
  first_name        text not null,
  last_name         text not null,
  other_names       text,
  date_of_birth     date,
  gender            text check (gender in ('female','male','other','undisclosed')),
  grade             text,
  class_id          uuid references public.classes(id) on delete set null,
  status            text not null default 'enrolled'
                    check (status in ('enrolled','withdrawn','graduated','suspended')),
  enrolled_on       date,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (school_id, admission_number)
);
create index on public.students (school_id, class_id);

create table public.parents_guardians (
  id                  uuid primary key default gen_random_uuid(),
  school_id           uuid not null references public.schools(id) on delete cascade,
  user_id             uuid references public.user_profiles(id) on delete set null, -- for parent portal (later phase)
  full_name           text not null,
  phone               text,
  email               text,
  preferred_channel   text not null default 'sms' check (preferred_channel in ('email','sms','whatsapp')),
  preferred_language  text not null default 'en' check (preferred_language in ('en','sw')),
  consent_given_at    timestamptz,       -- lawful basis record (Kenya DPA 2019)
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  check (phone is not null or email is not null)
);
create index on public.parents_guardians (school_id, phone);
create index on public.parents_guardians (user_id);

create table public.student_guardians (
  student_id          uuid not null references public.students(id) on delete cascade,
  guardian_id         uuid not null references public.parents_guardians(id) on delete cascade,
  school_id           uuid not null references public.schools(id) on delete cascade,
  relationship        text not null default 'parent',
  is_primary_contact  boolean not null default false,
  is_fee_payer        boolean not null default false,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  primary key (student_id, guardian_id)
);
create index on public.student_guardians (guardian_id);

-- ---------------------------------------------------------------------
-- 3. Admissions
-- ---------------------------------------------------------------------
create table public.admissions_enquiries (
  id                  uuid primary key default gen_random_uuid(),
  school_id           uuid not null references public.schools(id) on delete cascade,
  reference           text not null unique default app.next_reference('EQ'),
  source              text not null default 'web_form'
                      check (source in ('web_form','email','phone','walk_in','whatsapp','sms','social')),
  parent_name         text not null,
  parent_phone        text,
  parent_email        text,
  learner_first_name  text,
  learner_age         int check (learner_age between 0 and 25),
  grade_sought        text,
  intake              text,                          -- e.g. 'January 2027'
  message             text check (length(message) <= 4000),
  consent_given       boolean not null default false,
  consent_at          timestamptz,
  category            text not null default 'unclassified'
                      check (category in ('fees','availability','transport','tour_request','curriculum',
                                          'admission_process','boarding_meals','other','unclassified')),
  urgency             text not null default 'normal' check (urgency in ('low','normal','high')),
  ai_summary          text,
  needs_human         boolean not null default false,  -- AI flagged as sensitive/uncertain
  status              text not null default 'new'
                      check (status in ('new','acknowledged','in_progress','converted','closed','spam')),
  assigned_to         uuid references public.user_profiles(id) on delete set null,
  follow_up_due_at    timestamptz,
  last_contacted_at   timestamptz,
  merge_count         int not null default 0,          -- duplicate submissions merged into this one
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  check (parent_phone is not null or parent_email is not null)
);
create index on public.admissions_enquiries (school_id, status, created_at desc);
create index on public.admissions_enquiries (school_id, parent_phone);

create table public.applications (
  id                  uuid primary key default gen_random_uuid(),
  school_id           uuid not null references public.schools(id) on delete cascade,
  reference           text not null unique default app.next_reference('AP'),
  enquiry_id          uuid references public.admissions_enquiries(id) on delete set null,
  student_id          uuid references public.students(id) on delete set null,   -- set on enrolment
  guardian_id         uuid references public.parents_guardians(id) on delete set null,
  learner_first_name  text not null,
  learner_last_name   text not null,
  date_of_birth       date,
  gender              text check (gender in ('female','male','other','undisclosed')),
  grade_applied       text not null,
  intake              text,
  previous_school     text,
  parent_name         text not null,
  parent_phone        text,
  parent_email        text,
  consent_given       boolean not null default false,
  status              text not null default 'submitted'
                      check (status in ('submitted','incomplete','complete','under_review','assessment',
                                        'offered','waitlisted','declined','enrolled','withdrawn')),
  missing_documents   text[] not null default '{}',
  upload_token        uuid not null default gen_random_uuid(),  -- lets the applicant upload documents, nothing else
  decided_by          uuid references public.user_profiles(id),
  decided_at          timestamptz,
  decision_notes      text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  check (parent_phone is not null or parent_email is not null)
);
create index on public.applications (school_id, status, created_at desc);

create table public.application_documents (
  id                   uuid primary key default gen_random_uuid(),
  school_id            uuid not null references public.schools(id) on delete cascade,
  application_id       uuid not null references public.applications(id) on delete cascade,
  document_type        text not null,          -- matches schools.settings.required_documents
  storage_path         text not null unique,   -- {school_id}/{application_id}/{upload_token}/{file}
  file_name            text,
  mime_type            text,
  size_bytes           int check (size_bytes between 1 and 10485760),
  verification_status  text not null default 'pending' check (verification_status in ('pending','verified','rejected')),
  verified_by          uuid references public.user_profiles(id),
  verified_at          timestamptz,
  notes                text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
create index on public.application_documents (application_id);

-- ---------------------------------------------------------------------
-- 4. Fees and payments
-- ---------------------------------------------------------------------
create table public.fee_structures (
  id             uuid primary key default gen_random_uuid(),
  school_id      uuid not null references public.schools(id) on delete cascade,
  name           text not null,                  -- e.g. 'Grade 4 Term 1 2027'
  grade          text not null,
  academic_year  int not null,
  term           int not null check (term between 1 and 3),
  amount         numeric(12,2) not null check (amount >= 0),
  due_date       date not null,
  items          jsonb not null default '[]',    -- [{"label":"Tuition","amount":30000}, ...]
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (school_id, grade, academic_year, term)
);

create table public.student_fee_accounts (
  id                uuid primary key default gen_random_uuid(),
  school_id         uuid not null references public.schools(id) on delete cascade,
  student_id        uuid not null references public.students(id) on delete cascade,
  fee_structure_id  uuid references public.fee_structures(id) on delete set null,
  academic_year     int not null,
  term              int not null check (term between 1 and 3),
  amount_billed     numeric(12,2) not null check (amount_billed >= 0),
  discount          numeric(12,2) not null default 0 check (discount >= 0),
  due_date          date not null,
  reminders_paused  boolean not null default false,  -- e.g. agreed payment plan
  notes             text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (student_id, academic_year, term)
);
create index on public.student_fee_accounts (school_id, academic_year, term);

create table public.invoices (
  id              uuid primary key default gen_random_uuid(),
  school_id       uuid not null references public.schools(id) on delete cascade,
  fee_account_id  uuid not null references public.student_fee_accounts(id) on delete cascade,
  invoice_number  text not null,
  issue_date      date not null default current_date,
  due_date        date not null,
  amount          numeric(12,2) not null check (amount >= 0),
  status          text not null default 'draft' check (status in ('draft','issued','void')),
  pdf_path        text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (school_id, invoice_number)
);

create table public.payments (
  id                  uuid primary key default gen_random_uuid(),
  school_id           uuid not null references public.schools(id) on delete cascade,
  fee_account_id      uuid not null references public.student_fee_accounts(id) on delete restrict,
  student_id          uuid not null references public.students(id) on delete restrict,
  amount              numeric(12,2) not null check (amount > 0),
  method              text not null check (method in ('mpesa','bank','cash','cheque','other')),
  reference           text,                       -- M-Pesa receipt / bank ref
  payer_phone         text,
  paid_at             timestamptz not null default now(),
  status              text not null default 'pending' check (status in ('pending','confirmed','reversed','rejected')),
  source              text not null default 'manual' check (source in ('manual','csv_import','mpesa_c2b')),
  recorded_by         uuid references public.user_profiles(id),
  confirmed_by        uuid references public.user_profiles(id),
  confirmed_at        timestamptz,
  reversal_reason     text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create unique index payments_unique_reference on public.payments (school_id, method, reference) where reference is not null;
create index on public.payments (fee_account_id, status);

create table public.payment_reminders (
  id                  uuid primary key default gen_random_uuid(),
  school_id           uuid not null references public.schools(id) on delete cascade,
  batch_id            uuid not null,
  fee_account_id      uuid not null references public.student_fee_accounts(id) on delete cascade,
  guardian_id         uuid not null references public.parents_guardians(id) on delete cascade,
  balance_at_draft    numeric(12,2) not null check (balance_at_draft > 0),  -- copied from the database, never from AI
  channel             text not null check (channel in ('email','sms','whatsapp')),
  message_body        text not null,
  drafted_by          text not null default 'template' check (drafted_by in ('template','ai')),
  status              text not null default 'draft' check (status in ('draft','approved','rejected','sent','failed','cancelled')),
  approved_by         uuid references public.user_profiles(id),
  approved_at         timestamptz,
  sent_at             timestamptz,
  communication_log_id uuid,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index on public.payment_reminders (school_id, status);
create index on public.payment_reminders (fee_account_id, created_at desc);

-- ---------------------------------------------------------------------
-- 5. Attendance (later phase, schema ready)
-- ---------------------------------------------------------------------
create table public.attendance_records (
  id            uuid primary key default gen_random_uuid(),
  school_id     uuid not null references public.schools(id) on delete cascade,
  student_id    uuid not null references public.students(id) on delete cascade,
  class_id      uuid references public.classes(id) on delete set null,
  date          date not null,
  status        text not null check (status in ('present','absent','late','excused')),
  arrival_time  time,
  recorded_by   uuid references public.user_profiles(id),
  is_final      boolean not null default false,   -- notifications only fire on finalised registers
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (student_id, date)
);
create index on public.attendance_records (school_id, date, class_id);

-- ---------------------------------------------------------------------
-- 6. Staff tasks, announcements, events, notifications, communications
-- ---------------------------------------------------------------------
create table public.staff_tasks (
  id            uuid primary key default gen_random_uuid(),
  school_id     uuid not null references public.schools(id) on delete cascade,
  title         text not null,
  description   text,
  related_type  text check (related_type in ('enquiry','application','fee_account','announcement','other')),
  related_id    uuid,
  assigned_to   uuid references public.user_profiles(id) on delete set null,
  created_by    uuid references public.user_profiles(id) on delete set null,
  due_at        timestamptz,
  priority      text not null default 'normal' check (priority in ('low','normal','high')),
  status        text not null default 'open' check (status in ('open','in_progress','done','cancelled')),
  completed_at  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index on public.staff_tasks (school_id, status, due_at);
create index on public.staff_tasks (assigned_to, status);

create table public.announcements (
  id               uuid primary key default gen_random_uuid(),
  school_id        uuid not null references public.schools(id) on delete cascade,
  title            text not null,
  body             text not null,
  audience         text not null default 'whole_school' check (audience in ('whole_school','class','grade','staff')),
  class_id         uuid references public.classes(id) on delete set null,
  grade            text,
  channels         text[] not null default '{email}',
  status           text not null default 'draft'
                   check (status in ('draft','pending_approval','approved','sent','cancelled')),
  ai_assisted      boolean not null default false,
  created_by       uuid references public.user_profiles(id),
  approved_by      uuid references public.user_profiles(id),
  approved_at      timestamptz,
  scheduled_for    timestamptz,
  sent_at          timestamptz,
  recipient_count  int,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (audience <> 'class' or class_id is not null),
  check (audience <> 'grade' or grade is not null)
);
create index on public.announcements (school_id, status);

create table public.school_events (
  id           uuid primary key default gen_random_uuid(),
  school_id    uuid not null references public.schools(id) on delete cascade,
  title        text not null,
  description  text,
  starts_at    timestamptz not null,
  ends_at      timestamptz,
  location     text,
  audience     text not null default 'whole_school' check (audience in ('whole_school','staff','parents','class')),
  created_by   uuid references public.user_profiles(id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check (ends_at is null or ends_at >= starts_at)
);
create index on public.school_events (school_id, starts_at);

create table public.notifications (           -- in-app notifications for staff
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references public.schools(id) on delete cascade,
  user_id     uuid not null references public.user_profiles(id) on delete cascade,
  kind        text not null default 'info' check (kind in ('info','task','approval','alert')),
  title       text not null,
  body        text,
  link        text,
  read_at     timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index on public.notifications (user_id, read_at);

-- Every outbound and inbound message, including drafts awaiting approval
create table public.communication_logs (
  id                   uuid primary key default gen_random_uuid(),
  school_id            uuid not null references public.schools(id) on delete cascade,
  direction            text not null check (direction in ('outbound','inbound')),
  channel              text not null check (channel in ('email','sms','whatsapp','in_app')),
  guardian_id          uuid references public.parents_guardians(id) on delete set null,
  recipient            text,                     -- address / phone used
  subject              text,
  body                 text not null,
  related_type         text check (related_type in ('enquiry','application','fee_account','announcement','payment_reminder','attendance','other')),
  related_id           uuid,
  ai_generated         boolean not null default false,
  requires_approval    boolean not null default true,  -- false only for fixed, pre-approved templates
  template_key         text,
  status               text not null default 'draft'
                       check (status in ('draft','approved','rejected','queued','sent','delivered','failed','received')),
  approved_by          uuid references public.user_profiles(id),
  approved_at          timestamptz,
  provider_message_id  text,
  error                text,
  attempt_count        int not null default 0,
  idempotency_key      text unique,               -- blocks duplicate sends
  sent_at              timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  check (not (ai_generated and not requires_approval))  -- AI text can never skip approval
);
create index on public.communication_logs (school_id, status, created_at desc);
create index on public.communication_logs (related_type, related_id);

-- ---------------------------------------------------------------------
-- 7. Logs
-- ---------------------------------------------------------------------
create table public.automation_logs (
  id            uuid primary key default gen_random_uuid(),
  school_id     uuid references public.schools(id) on delete cascade,
  scenario      text not null,                  -- e.g. 'S1_enquiry_intake'
  execution_id  text,                           -- Make execution id
  status        text not null check (status in ('started','success','partial','failed','skipped')),
  related_type  text,
  related_id    uuid,
  message       text,
  details       jsonb not null default '{}',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index on public.automation_logs (school_id, created_at desc);
create index on public.automation_logs (scenario, status, created_at desc);

create table public.audit_logs (
  id             uuid primary key default gen_random_uuid(),
  school_id      uuid,
  actor_user_id  uuid,
  actor_type     text not null check (actor_type in ('user','automation','system')),
  action         text not null,                 -- INSERT / UPDATE / DELETE / custom
  table_name     text not null,
  record_id      uuid,
  old_data       jsonb,
  new_data       jsonb,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index on public.audit_logs (school_id, created_at desc);
create index on public.audit_logs (table_name, record_id);

create table public.ai_interaction_logs (
  id              uuid primary key default gen_random_uuid(),
  school_id       uuid references public.schools(id) on delete cascade,
  user_id         uuid references public.user_profiles(id) on delete set null,
  scenario        text not null,
  prompt_key      text not null,                -- e.g. 'enquiry_classifier'
  prompt_version  text not null,                -- e.g. 'v1.0'
  model           text,
  related_type    text,
  related_id      uuid,
  input_redacted  jsonb,                        -- what was sent, minus personal identifiers
  output          jsonb,
  valid_json      boolean,
  tokens_in       int,
  tokens_out      int,
  latency_ms      int,
  outcome         text not null default 'pending'
                  check (outcome in ('pending','accepted','edited','rejected','error','fallback')),
  reviewed_by     uuid references public.user_profiles(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index on public.ai_interaction_logs (school_id, created_at desc);

-- ---------------------------------------------------------------------
-- updated_at triggers on every table that has the column
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  for t in
    select c.table_name from information_schema.columns c
    where c.table_schema = 'public' and c.column_name = 'updated_at'
  loop
    execute format('create trigger set_updated_at before update on public.%I
                    for each row execute function app.set_updated_at()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- New Supabase Auth user -> user_profiles row
-- ---------------------------------------------------------------------
create or replace function app.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.user_profiles (id, email, full_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function app.handle_new_user();

-- ---------------------------------------------------------------------
-- Reference data: roles and permissions
-- ---------------------------------------------------------------------
insert into public.roles (key, name, description, is_staff) values
  ('super_admin',        'Super Administrator',  'YomieVerse platform staff. Set on user_profiles.is_super_admin, never per school.', true),
  ('school_admin',       'School Administrator', 'Runs school operations, admissions, communication and settings.', true),
  ('head_teacher',       'Headteacher / Principal', 'Reviews summaries and reports; can make admission decisions.', true),
  ('bursar',             'Bursar / Accountant',  'Manages fee records, payments and reminders.', true),
  ('admissions_officer', 'Admissions Officer',   'Manages enquiries, applications and parent replies.', true),
  ('teacher',            'Teacher',              'Sees assigned classes; records attendance.', true),
  ('parent',             'Parent / Guardian',    'Sees own children''s authorised information (portal, later phase).', false);

insert into public.permissions (key, description) values
  ('school.configure',      'Edit school profile, settings and staff roles'),
  ('admissions.view',       'View enquiries and applications'),
  ('admissions.manage',     'Create and update enquiries and applications'),
  ('admissions.decide',     'Set offered / waitlisted / declined / enrolled'),
  ('comms.draft',           'Draft parent messages and announcements'),
  ('comms.approve',         'Approve messages and announcements for sending'),
  ('fees.view',             'View fee accounts, balances and payments'),
  ('fees.manage',           'Record and confirm payments, edit fee accounts'),
  ('fees.remind',           'Approve fee reminder batches'),
  ('attendance.record',     'Record attendance for assigned classes'),
  ('reports.view',          'View dashboards and briefings'),
  ('audit.view',            'View audit and automation logs'),
  ('children.view_own',     'View own children''s records');

insert into public.role_permissions (role_key, permission_key)
select r, p from (values
  ('school_admin','school.configure'),('school_admin','admissions.view'),('school_admin','admissions.manage'),
  ('school_admin','admissions.decide'),('school_admin','comms.draft'),('school_admin','comms.approve'),
  ('school_admin','fees.view'),('school_admin','reports.view'),('school_admin','audit.view'),
  ('head_teacher','admissions.view'),('head_teacher','admissions.decide'),('head_teacher','comms.approve'),
  ('head_teacher','fees.view'),('head_teacher','reports.view'),('head_teacher','audit.view'),
  ('bursar','fees.view'),('bursar','fees.manage'),('bursar','fees.remind'),('bursar','comms.draft'),('bursar','reports.view'),
  ('admissions_officer','admissions.view'),('admissions_officer','admissions.manage'),('admissions_officer','admissions.decide'),
  ('admissions_officer','comms.draft'),('admissions_officer','comms.approve'),
  ('teacher','attendance.record'),
  ('parent','children.view_own')
) as t(r, p);
