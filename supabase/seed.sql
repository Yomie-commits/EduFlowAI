-- =====================================================================
-- EduFlow AI  |  SYNTHETIC DEMONSTRATION DATA — NOT REAL PEOPLE
-- Two fictional schools so tenant isolation can be shown in demos:
--   Mwangaza Junior Academy (CBC primary, Nairobi)  slug: mwangaza-junior
--   Baraka Little Stars Daycare (Kiambu)            slug: baraka-daycare
-- Run after migrations 001-003, as the postgres role (SQL editor).
--
-- Demo logins: first create these users in Supabase Auth (Dashboard >
-- Authentication > Add user), then run this file. Memberships are linked
-- by email at the bottom; missing users are skipped with a notice.
--   admin@mwangaza.demo       School Administrator
--   head@mwangaza.demo        Head Teacher
--   bursar@mwangaza.demo      Bursar
--   admissions@mwangaza.demo  Admissions Officer
--   teacher@mwangaza.demo     Teacher (Grade 4)
--   admin@baraka.demo         School Administrator (other school)
-- =====================================================================

do $$
declare
  s1 uuid := '11111111-1111-4111-8111-111111111111';
  s2 uuid := '22222222-2222-4222-8222-222222222222';
  first_f text[] := array['Wanjiru','Achieng','Njeri','Atieno','Wambui','Chebet','Nafula','Mumbua','Akinyi','Wairimu','Jepkoech','Kerubo'];
  first_m text[] := array['Kamau','Otieno','Mwangi','Kiprotich','Odhiambo','Mutua','Wekesa','Kariuki','Omondi','Njoroge','Kibet','Onyango'];
  surnames text[] := array['Kamau','Ochieng','Mwangi','Kiptoo','Wafula','Mutiso','Njoroge','Owino','Karanja','Chege','Barasa','Nyambura','Kimani','Odera','Maina','Langat'];
  grades text[] := array['PP1','PP2','Grade 1','Grade 2','Grade 3','Grade 4','Grade 5','Grade 6'];
  fees numeric[] := array[28000,28000,35000,35000,35000,42000,42000,42000];
  v_class uuid; v_staff uuid; v_student uuid; v_guardian uuid; v_fs uuid; v_acct uuid;
  i int; g int; n int := 0;
begin
  -- Schools ---------------------------------------------------------------
  insert into public.schools (id, name, slug, school_type, county, phone, email, website, status, settings) values
  (s1, 'Mwangaza Junior Academy', 'mwangaza-junior', 'primary', 'Nairobi', '+254700000101', 'office@mwangaza.demo', null, 'active',
   jsonb_build_object('required_documents', jsonb_build_array('birth_certificate','passport_photo','previous_report'),
                      'reminder_interval_days', 7, 'reminder_grace_days', 3, 'enquiry_retention_months', 12,
                      'briefing_hour', 7, 'timezone', 'Africa/Nairobi', 'default_language', 'en',
                      'fee_paybill', '000000 (demo)', 'admissions_contact', 'Mr. Otieno, Admissions')),
  (s2, 'Baraka Little Stars Daycare', 'baraka-daycare', 'daycare', 'Kiambu', '+254700000202', 'hello@baraka.demo', null, 'active',
   jsonb_build_object('required_documents', jsonb_build_array('birth_certificate','immunisation_card'),
                      'reminder_interval_days', 14, 'reminder_grace_days', 5, 'enquiry_retention_months', 12,
                      'briefing_hour', 7, 'timezone', 'Africa/Nairobi', 'default_language', 'sw'));

  -- Office staff ---------------------------------------------------------
  insert into public.staff (school_id, full_name, staff_number, job_title, department, phone, email) values
  (s1, 'Wanjiru Kamau',  'MJA-001', 'School Administrator', 'Administration', '+254700000111', 'admin@mwangaza.demo'),
  (s1, 'Peter Kamau',    'MJA-002', 'Head Teacher',         'Leadership',     '+254700000112', 'head@mwangaza.demo'),
  (s1, 'Mary Achieng',   'MJA-003', 'Bursar',               'Finance',        '+254700000113', 'bursar@mwangaza.demo'),
  (s1, 'James Otieno',   'MJA-004', 'Admissions Officer',   'Administration', '+254700000114', 'admissions@mwangaza.demo'),
  (s2, 'Grace Wambui',   'BLS-001', 'Centre Manager',       'Administration', '+254700000211', 'admin@baraka.demo');

  -- Classes, teachers, students, guardians, fees (Mwangaza) ---------------
  for g in 1..8 loop
    insert into public.staff (school_id, full_name, staff_number, job_title, department, email)
    values (s1, 'Tr. ' || first_f[g] || ' ' || surnames[g+4], 'MJA-1' || lpad(g::text, 2, '0'), 'Class Teacher', 'Teaching',
            case when g = 6 then 'teacher@mwangaza.demo' else null end)
    returning id into v_staff;

    insert into public.classes (school_id, name, grade, stream, academic_year, class_teacher_id, capacity)
    values (s1, grades[g] || ' Blue', grades[g], 'Blue', 2026, v_staff, 30) returning id into v_class;

    insert into public.fee_structures (school_id, name, grade, academic_year, term, amount, due_date, items)
    values (s1, grades[g] || ' Term 3 2026', grades[g], 2026, 3, fees[g], date '2026-09-08',
            jsonb_build_array(jsonb_build_object('label','Tuition','amount', fees[g] - 6000),
                              jsonb_build_object('label','Lunch','amount', 4500),
                              jsonb_build_object('label','Activity','amount', 1500)))
    returning id into v_fs;

    insert into public.fee_structures (school_id, name, grade, academic_year, term, amount, due_date)
    values (s1, grades[g] || ' Term 1 2027', grades[g], 2027, 1, fees[g] + 2000, date '2027-01-11');

    for i in 1..6 loop
      n := n + 1;
      insert into public.students (school_id, admission_number, first_name, last_name, date_of_birth, gender, grade, class_id, enrolled_on)
      values (s1, 'MJA/' || (2020 + (n % 6)) || '/' || lpad(n::text, 3, '0'),
              case when n % 2 = 0 then first_f[1 + n % 12] else first_m[1 + n % 12] end,
              surnames[1 + (n * 7) % 16],
              make_date(2021 - g, 1 + n % 12, 1 + n % 27),
              case when n % 2 = 0 then 'female' else 'male' end,
              grades[g], v_class, make_date(2020 + (n % 6), 1, 10))
      returning id into v_student;

      insert into public.parents_guardians (school_id, full_name, phone, email, preferred_channel, preferred_language, consent_given_at)
      values (s1,
              case when n % 3 = 0 then 'Mr. ' else 'Mrs. ' end || first_f[1 + (n+3) % 12] || ' ' || surnames[1 + (n * 7) % 16],
              '+2547' || lpad((10000000 + n * 137)::text, 8, '0'),
              case when n % 4 = 0 then 'parent' || n || '@example.com' else null end,
              case when n % 4 = 0 then 'email' else 'sms' end,
              case when n % 5 = 0 then 'sw' else 'en' end,
              now() - interval '200 days')
      returning id into v_guardian;

      insert into public.student_guardians (student_id, guardian_id, school_id, relationship, is_primary_contact, is_fee_payer)
      values (v_student, v_guardian, s1, case when n % 3 = 0 then 'father' else 'mother' end, true, true);

      insert into public.student_fee_accounts (school_id, student_id, fee_structure_id, academic_year, term, amount_billed, discount, due_date, reminders_paused)
      values (s1, v_student, v_fs, 2026, 3, fees[g], case when n % 11 = 0 then 5000 else 0 end, date '2026-09-08', n = 17)
      returning id into v_acct;

      -- payment pattern: 0 = cleared, 1 = half paid, 2 = nothing paid, 3 = mostly paid + one pending M-Pesa
      if n % 4 = 0 then
        insert into public.payments (school_id, fee_account_id, student_id, amount, method, reference, paid_at, status, source, confirmed_at)
        values (s1, v_acct, v_student, fees[g] - case when n % 11 = 0 then 5000 else 0 end, 'mpesa', 'DEMO' || lpad(n::text, 6, '0') || 'A',
                timestamptz '2026-09-02 10:00+03' + n * interval '3 hours', 'pending', 'manual', null);
      elsif n % 4 = 1 then
        insert into public.payments (school_id, fee_account_id, student_id, amount, method, reference, paid_at, status, source)
        values (s1, v_acct, v_student, round(fees[g] / 2), 'mpesa', 'DEMO' || lpad(n::text, 6, '0') || 'B',
                timestamptz '2026-09-05 09:00+03' + n * interval '2 hours', 'pending', 'manual');
      elsif n % 4 = 3 then
        insert into public.payments (school_id, fee_account_id, student_id, amount, method, reference, paid_at, status, source)
        values (s1, v_acct, v_student, fees[g] - 8000, 'bank', 'DEMOBANK' || n, timestamptz '2026-09-01 12:00+03', 'pending', 'manual'),
               (s1, v_acct, v_student, 3000, 'mpesa', 'DEMO' || lpad(n::text, 6, '0') || 'C', now() - interval '1 day', 'pending', 'mpesa_c2b');
      end if;
    end loop;
  end loop;

  -- Seeding runs as the database owner (no signed-in user), so the payment
  -- guard correctly refuses to confirm payments here. For demo history only,
  -- disable the guard briefly and mark the historical payments as confirmed.
  alter table public.payments disable trigger guard_payment;
  update public.payments set status = 'confirmed', confirmed_at = paid_at
   where school_id = s1 and source = 'manual';
  alter table public.payments enable trigger guard_payment;

  -- Admissions enquiries (January 2027 intake) ---------------------------
  insert into public.admissions_enquiries (school_id, source, parent_name, parent_phone, parent_email, learner_first_name, learner_age,
      grade_sought, intake, message, consent_given, consent_at, category, urgency, ai_summary, status, follow_up_due_at, created_at)
  values
  (s1,'web_form','Faith Mutiso','+254711000201',null,'Amani',5,'PP2','January 2027','Do you have space in PP2 for January? What are the fees and is lunch included?',true,now()-interval '2 hours','fees','normal','Asks about PP2 space for January 2027 and whether lunch is included in fees.','new',now()+interval '22 hours',now()-interval '2 hours'),
  (s1,'web_form','Brian Odera','+254711000202','b.odera@example.com','Tumaini',8,'Grade 3','January 2027','We are relocating from Kisumu in December. Can we book a school tour next week?',true,now()-interval '5 hours','tour_request','high','Family relocating from Kisumu; wants a school tour next week for Grade 3.','new',now()+interval '19 hours',now()-interval '5 hours'),
  (s1,'phone','Lucy Wafula','+254711000203',null,'Baraka',4,'PP1','January 2027','Called reception asking about the school bus route to Kahawa West.',true,now()-interval '1 day','transport','normal','Asks whether the school bus serves Kahawa West for a PP1 learner.','acknowledged',now()-interval '1 hour',now()-interval '1 day'),
  (s1,'web_form','Samuel Kiptoo','+254711000204',null,'Neema',10,'Grade 5','January 2027','How does the CBC assessment work for a child joining Grade 5 from another school?',true,now()-interval '2 days','curriculum','normal','Asks how CBC assessment works for a Grade 5 transfer learner.','in_progress',now()+interval '1 day',now()-interval '2 days'),
  (s1,'web_form','Rose Njoroge',null,'rose.n@example.com','Zawadi',6,'Grade 1','January 2027','What documents do I need for admission?',true,now()-interval '3 days','admission_process','low','Asks which documents are required for Grade 1 admission.','converted',null,now()-interval '3 days'),
  (s1,'walk_in','Daniel Maina','+254711000206',null,'Imani',7,'Grade 2','May 2027','Visited the office. Interested in May intake; will bring report form.',true,now()-interval '4 days','availability','low','Interested in May 2027 Grade 2 place; will bring the report form.','in_progress',now()-interval '2 days',now()-interval '4 days'),
  (s1,'web_form','Esther Langat','+254711000207',null,'Furaha',9,'Grade 4','January 2027','My child has asthma. Do you have a school nurse on site?',true,now()-interval '6 days','other','high','Sensitive: parent asks about on-site nurse for a child''s medical condition. Route to a human.','new',now()-interval '5 days',now()-interval '6 days'),
  (s1,'web_form','Kevin Barasa','+254711000208',null,'Jabari',5,'PP2','January 2027','Is there a sibling discount? Our older child is in Grade 3 with you.',true,now()-interval '8 days','fees','normal','Asks about sibling discount; older child already at the school.','closed',null,now()-interval '8 days'),
  (s1,'email','Mercy Chege',null,'mercy.c@example.com','Hope',11,'Grade 6','January 2027','Do you offer boarding or after-school care until 6pm?',true,now()-interval '10 days','boarding_meals','normal','Asks about boarding or after-school care until 6 pm.','acknowledged',now()-interval '9 days',now()-interval '10 days'),
  (s2,'web_form','Ann Kimani','+254722000301',null,'Malaika',2,'Toddlers','January 2027','Je, mnapokea watoto wa miaka miwili? Saa za kufungua ni zipi?',true,now()-interval '1 day','availability','normal','Asks (in Kiswahili) if the daycare takes 2-year-olds and its opening hours.','new',now()+interval '1 day',now()-interval '1 day');

  -- Applications ----------------------------------------------------------
  insert into public.applications (school_id, enquiry_id, learner_first_name, learner_last_name, date_of_birth, gender, grade_applied, intake,
      previous_school, parent_name, parent_phone, parent_email, consent_given, status, created_at)
  values
  (s1,(select id from public.admissions_enquiries where parent_name='Rose Njoroge'),'Zawadi','Njoroge','2020-03-14','female','Grade 1','January 2027','Little Lambs Kindergarten','Rose Njoroge',null,'rose.n@example.com',true,'submitted',now()-interval '2 days'),
  (s1,null,'Kito','Owino','2018-07-02','male','Grade 3','January 2027','Riverside Primary','Paul Owino','+254711000301',null,true,'submitted',now()-interval '5 days'),
  (s1,null,'Nia','Karanja','2016-11-20','female','Grade 5','January 2027','Hillview Academy','Joyce Karanja','+254711000302','joyce.k@example.com',true,'submitted',now()-interval '7 days'),
  (s1,null,'Baraka','Wafula','2022-05-09','male','PP1','January 2027',null,'Lucy Wafula','+254711000203',null,true,'submitted',now()-interval '1 day'),
  (s1,null,'Leo','Mutua','2017-01-30','male','Grade 4','January 2027','Sunrise School','Grace Mutua','+254711000303',null,true,'submitted',now()-interval '12 days'),
  (s2,null,'Malaika','Kimani','2024-04-11','female','Toddlers','January 2027',null,'Ann Kimani','+254722000301',null,true,'submitted',now()-interval '1 day');

  -- Documents (paths are placeholders; no files are stored for demo data)
  insert into public.application_documents (school_id, application_id, document_type, storage_path, file_name, mime_type, size_bytes, verification_status)
  select a.school_id, a.id, d.doc, a.school_id || '/' || a.id || '/' || a.upload_token || '/' || d.doc || '.pdf', d.doc || '.pdf', 'application/pdf', 120000,
         case when a.learner_first_name = 'Nia' then 'verified' else 'pending' end
  from public.applications a
  cross join lateral (values ('birth_certificate'),('passport_photo'),('previous_report')) d(doc)
  where a.school_id = s1 and (a.learner_first_name in ('Nia','Leo') or (a.learner_first_name = 'Kito' and d.doc = 'birth_certificate'));

  perform app.refresh_missing_documents(id) from public.applications;
  update public.applications set status = 'under_review' where learner_first_name = 'Nia';
  update public.applications set status = 'assessment'  where learner_first_name = 'Leo';

  -- Events, announcements, tasks -----------------------------------------
  insert into public.school_events (school_id, title, description, starts_at, ends_at, location, audience) values
  (s1, 'Closing day, Term 3',          'Learners close for the December holiday at 12:30 pm.', timestamptz '2026-11-27 08:00+03', timestamptz '2026-11-27 12:30+03', 'School grounds', 'whole_school'),
  (s1, 'Open day for January intake',  'Tours for prospective families every 30 minutes.',    timestamptz '2026-11-28 09:00+03', timestamptz '2026-11-28 13:00+03', 'Main hall',      'parents'),
  (s1, 'Staff planning meeting',       'Term 1 2027 timetable and admissions review.',        timestamptz '2026-12-02 10:00+03', timestamptz '2026-12-02 12:00+03', 'Staff room',     'staff'),
  (s1, 'Term 1 2027 opening day',      null,                                                  timestamptz '2027-01-06 07:30+03', null,                               'School grounds', 'whole_school');

  insert into public.announcements (school_id, title, body, audience, grade, channels, status, ai_assisted, created_at) values
  (s1, 'Closing day reminder', 'Dear parents, learners close for the holiday on Friday 27 November at 12:30 pm. Please pick up your child on time. Report forms will be issued on the day. Thank you.', 'whole_school', null, '{sms,email}', 'pending_approval', true, now() - interval '3 hours'),
  (s1, 'Grade 4 science trip', 'Dear Grade 4 parents, the class will visit the Nairobi National Museum on Wednesday. Please send a packed snack and a water bottle.', 'grade', 'Grade 4', '{sms}', 'draft', false, now() - interval '1 day');

  insert into public.staff_tasks (school_id, title, description, related_type, related_id, priority, status, due_at)
  select s1, 'Follow up enquiry ' || e.reference || ' (' || e.parent_name || ')', e.ai_summary, 'enquiry', e.id,
         case when e.urgency = 'high' then 'high' else 'normal' end, 'open', e.follow_up_due_at
  from public.admissions_enquiries e where e.school_id = s1 and e.status in ('new','acknowledged','in_progress');

  insert into public.staff_tasks (school_id, title, description, related_type, priority, status, due_at) values
  (s1, 'Review Term 3 fee reminder batch', 'Check the weekly reminder drafts before Monday sending.', 'other', 'normal', 'open', now() + interval '2 days'),
  (s1, 'Prepare open day welcome pack',    'Print 40 brochures and the fee structure for 2027.',     'other', 'normal', 'in_progress', now() + interval '6 days');

  -- Draft parent replies awaiting approval -------------------------------
  insert into public.communication_logs (school_id, direction, channel, recipient, subject, body, related_type, related_id, ai_generated, status, created_at)
  select s1, 'outbound', case when e.parent_email is not null then 'email' else 'sms' end,
         coalesce(e.parent_email, e.parent_phone),
         'Your enquiry ' || e.reference,
         case e.category
           when 'tour_request' then 'Dear ' || split_part(e.parent_name,' ',1) || ', thank you for your interest in Mwangaza Junior Academy. We would be happy to show you around. Tours run on weekdays between 9 am and 3 pm, and on our open day on Saturday 28 November. Please reply with a day that suits you. Warm regards, Admissions Office.'
           when 'fees' then 'Dear ' || split_part(e.parent_name,' ',1) || ', thank you for contacting Mwangaza Junior Academy. We do have PP2 places for January 2027. Our admissions officer will share the 2027 fee structure with you today, including what is covered for lunch. Kind regards, Admissions Office.'
           else 'Dear ' || split_part(e.parent_name,' ',1) || ', thank you for your enquiry. A member of our admissions team will get back to you within one working day. Kind regards, Admissions Office.'
         end,
         'enquiry', e.id, true, 'draft', now() - interval '1 hour'
  from public.admissions_enquiries e where e.school_id = s1 and e.status = 'new' and not e.needs_human and e.category <> 'other';

  -- Automation and AI log examples ---------------------------------------
  insert into public.automation_logs (school_id, scenario, execution_id, status, related_type, message, created_at) values
  (s1, 'S1_enquiry_intake', 'demo-exec-001', 'success', 'enquiry', 'Enquiry stored, classified, acknowledged by SMS, task created', now() - interval '2 hours'),
  (s1, 'S1_enquiry_intake', 'demo-exec-002', 'partial', 'enquiry', 'SMS provider timeout; acknowledgement retried successfully', now() - interval '5 hours'),
  (s1, 'S6_daily_briefing', 'demo-exec-003', 'success', null,      'Briefing emailed to 2 recipients', now() - interval '9 hours');

  update public.admissions_enquiries set needs_human = true where parent_name = 'Esther Langat';
end $$;

-- ---------------------------------------------------------------------
-- Link demo logins (create the Auth users first). Safe to re-run.
-- ---------------------------------------------------------------------
create or replace function app.link_demo_user(p_email text, p_slug text, p_role text) returns text
language plpgsql security definer set search_path = public as $$
declare v_uid uuid; v_school uuid;
begin
  select id into v_uid from auth.users where lower(email) = lower(p_email);
  if v_uid is null then
    raise notice 'Skipped %: create this user in Supabase Auth first', p_email;
    return 'skipped';
  end if;
  insert into public.user_profiles (id, email, full_name) values (v_uid, p_email, split_part(p_email, '@', 1))
  on conflict (id) do nothing;
  select id into v_school from public.schools where slug = p_slug;
  insert into public.school_memberships (school_id, user_id, role_key) values (v_school, v_uid, p_role)
  on conflict do nothing;
  update public.staff set user_id = v_uid where school_id = v_school and lower(email) = lower(p_email);
  return 'linked';
end $$;

select app.link_demo_user('admin@mwangaza.demo',      'mwangaza-junior', 'school_admin');
select app.link_demo_user('head@mwangaza.demo',       'mwangaza-junior', 'head_teacher');
select app.link_demo_user('bursar@mwangaza.demo',     'mwangaza-junior', 'bursar');
select app.link_demo_user('admissions@mwangaza.demo', 'mwangaza-junior', 'admissions_officer');
select app.link_demo_user('teacher@mwangaza.demo',    'mwangaza-junior', 'teacher');
select app.link_demo_user('admin@baraka.demo',        'baraka-daycare',  'school_admin');

update public.user_profiles p set full_name = s.full_name
from public.staff s where s.user_id = p.id;
