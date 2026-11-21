-- =====================================================================
-- EduFlow AI  |  Migration 004: automation bridge (Supabase <-> Make)
--
-- Design:
--  * The database decides WHEN Make is needed (triggers with WHEN clauses),
--    and calls one Make webhook with only {event, id}. No personal data is
--    sent in the webhook itself.
--  * Make calls back with the Supabase SECRET key (service role) to the
--    automation_* functions below. Only service_role can execute them.
--  * Every rule (templates, idempotency, demo redirect, approvals) lives
--    here, where it is tested, not inside Make modules.
-- Requires the pg_net extension (Supabase: Database > Extensions > pg_net).
-- =====================================================================

do $$ begin
  create extension if not exists pg_net;
exception when others then
  raise notice 'pg_net not available here (fine for local tests): %', sqlerrm;
end $$;

-- Private configuration (not exposed through the API)
create table if not exists app.config (
  key         text primary key,
  value       text not null,
  updated_at  timestamptz not null default now()
);
revoke all on app.config from public, anon, authenticated;

create or replace function app.config_value(p_key text) returns text
language sql stable security definer set search_path = public as $$
  select value from app.config where key = p_key;
$$;

create or replace function app.html_escape(p text) returns text
language sql immutable as $$
  select replace(replace(replace(replace(coalesce(p, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;');
$$;

-- ---------------------------------------------------------------------
-- Outbound: notify Make
-- ---------------------------------------------------------------------
create or replace function app.notify_make(p_event text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_url text := app.config_value('make_webhook_url');
begin
  if v_url is null or v_url = '' then
    return;  -- automations not connected yet: records are still saved
  end if;
  perform net.http_post(
    url     := v_url,
    body    := jsonb_build_object('event', p_event, 'id', p_id),
    headers := '{"Content-Type": "application/json"}'::jsonb,
    timeout_milliseconds := 5000);
end $$;

create or replace function app.on_enquiry_created() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform app.notify_make('enquiry.created', new.id);
  return new;
end $$;

create or replace function app.on_message_ready() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform app.notify_make('message.ready', new.id);
  return new;
end $$;

drop trigger if exists make_enquiry_created on public.admissions_enquiries;
create trigger make_enquiry_created after insert on public.admissions_enquiries
  for each row when (new.category = 'unclassified' and new.status = 'new')
  execute function app.on_enquiry_created();

drop trigger if exists make_message_ready on public.communication_logs;
create trigger make_message_ready after insert or update on public.communication_logs
  for each row when (new.direction = 'outbound' and new.attempt_count = 0
                     and (new.status = 'approved' or (new.status = 'queued' and not new.requires_approval)))
  execute function app.on_message_ready();

-- ---------------------------------------------------------------------
-- Approved fee reminders and announcements become individual messages
-- (runs in the approving staff member's transaction, so approvals stay human)
-- ---------------------------------------------------------------------
create or replace function app.on_reminder_approved() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_log uuid; g public.parents_guardians;
begin
  select * into g from public.parents_guardians where id = new.guardian_id;
  insert into public.communication_logs (school_id, direction, channel, guardian_id, recipient, subject, body,
      related_type, related_id, ai_generated, requires_approval, template_key, status, idempotency_key)
  values (new.school_id, 'outbound', new.channel, g.id,
          case when new.channel = 'email' then g.email else g.phone end,
          'Fee reminder', new.message_body, 'payment_reminder', new.id, false, true, 'fee_reminder',
          'approved', 'reminder:' || new.id)
  on conflict (idempotency_key) do nothing
  returning id into v_log;
  if v_log is not null then
    update public.payment_reminders set communication_log_id = v_log where id = new.id;
  end if;
  return new;
end $$;

drop trigger if exists reminder_approved_to_message on public.payment_reminders;
create trigger reminder_approved_to_message after update of status on public.payment_reminders
  for each row when (new.status = 'approved' and old.status is distinct from 'approved')
  execute function app.on_reminder_approved();

create or replace function app.on_announcement_approved() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_count int;
begin
  insert into public.communication_logs (school_id, direction, channel, guardian_id, recipient, subject, body,
      related_type, related_id, ai_generated, requires_approval, template_key, status, idempotency_key)
  select distinct on (g.id)
         new.school_id, 'outbound',
         case when 'email' = any(new.channels) and g.email is not null then 'email' else 'sms' end,
         g.id,
         case when 'email' = any(new.channels) and g.email is not null then g.email else g.phone end,
         new.title, new.body, 'announcement', new.id, new.ai_assisted, true, 'announcement', 'approved',
         'announcement:' || new.id || ':' || g.id
  from public.parents_guardians g
  join public.student_guardians sg on sg.guardian_id = g.id
  join public.students st on st.id = sg.student_id and st.status = 'enrolled'
  where g.school_id = new.school_id
    and sg.is_primary_contact
    and (new.audience = 'whole_school'
         or (new.audience = 'grade' and st.grade = new.grade)
         or (new.audience = 'class' and st.class_id = new.class_id))
  on conflict (idempotency_key) do nothing;
  get diagnostics v_count = row_count;
  update public.announcements set recipient_count = coalesce(recipient_count, 0) + v_count where id = new.id;
  return new;
end $$;

drop trigger if exists announcement_approved_to_messages on public.announcements;
create trigger announcement_approved_to_messages after update of status on public.announcements
  for each row when (new.status = 'approved' and old.status is distinct from 'approved' and new.audience <> 'staff')
  execute function app.on_announcement_approved();

-- ---------------------------------------------------------------------
-- Functions Make calls (service_role only)
-- ---------------------------------------------------------------------

-- S1 step 1: what the classifier may see (no names, phones or emails)
create or replace function public.automation_enquiry_context(p_enquiry uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', e.id, 'reference', e.reference, 'school_name', s.name, 'source', e.source,
    'grade_sought', coalesce(e.grade_sought, ''), 'intake', coalesce(e.intake, ''),
    'learner_age', coalesce(e.learner_age::text, ''), 'message', coalesce(e.message, ''),
    'needs_classification', (e.category = 'unclassified'))
  from public.admissions_enquiries e join public.schools s on s.id = e.school_id
  where e.id = p_enquiry;
$$;

-- S1 step 2: apply the AI result (validated here), acknowledge, create task, log
create or replace function public.automation_apply_classification(p_enquiry uuid, p_ai jsonb default null, p_execution_id text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  e public.admissions_enquiries;
  s public.schools;
  v_valid boolean;
  v_cat text; v_urg text; v_human boolean; v_sum text; v_lang text;
  v_first text; v_body text; v_subject text; v_channel text; v_recipient text; v_msg uuid;
begin
  select * into e from public.admissions_enquiries where id = p_enquiry for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'enquiry not found'); end if;
  if e.category <> 'unclassified' then return jsonb_build_object('ok', true, 'skipped', true); end if;
  select * into s from public.schools where id = e.school_id;

  v_valid := p_ai is not null and jsonb_typeof(p_ai) = 'object'
    and p_ai->>'category' in ('fees','availability','transport','tour_request','curriculum','admission_process','boarding_meals','other')
    and p_ai->>'urgency' in ('low','normal','high')
    and jsonb_typeof(p_ai->'needs_human') = 'boolean'
    and length(coalesce(p_ai->>'summary', '')) between 1 and 300;

  if v_valid then
    v_cat := p_ai->>'category'; v_urg := p_ai->>'urgency'; v_human := (p_ai->>'needs_human')::boolean;
    v_sum := p_ai->>'summary'; v_lang := case when p_ai->>'language' = 'sw' then 'sw' else 'en' end;
  else
    v_cat := 'unclassified'; v_urg := 'normal'; v_human := true; v_sum := null;
    v_lang := coalesce(s.settings->>'default_language', 'en');
  end if;

  update public.admissions_enquiries
     set category = case when v_valid then v_cat else 'other' end,
         urgency = v_urg, needs_human = v_human, ai_summary = v_sum,
         status = case when status = 'new' then 'acknowledged' else status end
   where id = e.id;

  insert into public.ai_interaction_logs (school_id, scenario, prompt_key, prompt_version, model, related_type, related_id,
      input_redacted, output, valid_json, outcome)
  values (e.school_id, 'S1_enquiry_intake', 'enquiry_classifier', 'v1.0', 'make-ai-provider:medium', 'enquiry', e.id,
          jsonb_build_object('grade_sought', e.grade_sought, 'intake', e.intake, 'message_chars', length(coalesce(e.message, ''))),
          p_ai, v_valid, case when v_valid then 'accepted' else 'fallback' end);

  -- Fixed acknowledgement template (not AI): allowed to send without approval
  v_first := split_part(e.parent_name, ' ', 1);
  if v_lang = 'sw' then
    v_subject := 'Tumepokea ujumbe wako (' || e.reference || ')';
    v_body := 'Habari ' || v_first || ', asante kwa kuwasiliana na ' || s.name || '. Nambari yako ya kumbukumbu ni ' || e.reference
              || '. Ofisi ya usajili itakujibu ndani ya siku moja ya kazi.';
  else
    v_subject := 'We received your enquiry (' || e.reference || ')';
    v_body := 'Dear ' || v_first || ', thank you for your enquiry to ' || s.name || '. Your reference is ' || e.reference
              || '. Our admissions office will reply within one working day.';
  end if;
  v_channel := case when e.parent_email is not null then 'email' else 'sms' end;
  v_recipient := coalesce(e.parent_email, e.parent_phone);

  insert into public.communication_logs (school_id, direction, channel, recipient, subject, body, related_type, related_id,
      ai_generated, requires_approval, template_key, status, idempotency_key)
  values (e.school_id, 'outbound', v_channel, v_recipient, v_subject, v_body, 'enquiry', e.id,
          false, false, 'enquiry_ack', 'queued', 'ack:' || e.id)
  on conflict (idempotency_key) do nothing
  returning id into v_msg;

  insert into public.staff_tasks (school_id, title, description, related_type, related_id, priority, status, due_at)
  select e.school_id, 'Follow up enquiry ' || e.reference || ' (' || e.parent_name || ')',
         coalesce(v_sum, 'Not classified automatically. Please read the message.') ||
           case when v_human then ' Needs a personal reply.' else '' end,
         'enquiry', e.id, case when v_urg = 'high' or v_human then 'high' else 'normal' end, 'open',
         coalesce(e.follow_up_due_at, now() + interval '24 hours')
  where not exists (select 1 from public.staff_tasks t where t.related_type = 'enquiry' and t.related_id = e.id);

  insert into public.automation_logs (school_id, scenario, execution_id, status, related_type, related_id, message)
  values (e.school_id, 'S1_enquiry_intake', p_execution_id, case when v_valid then 'success' else 'partial' end, 'enquiry', e.id,
          case when v_valid then 'Classified as ' || v_cat || ' (' || v_urg || '), acknowledgement queued, task created'
               else 'AI result unusable: marked for a person, acknowledgement queued, task created' end);

  return jsonb_build_object('ok', true, 'valid_ai', v_valid, 'category', v_cat, 'needs_human', v_human, 'ack_message_id', v_msg);
end $$;

-- S0 step 1: claim a message for sending (exactly once) and say how to send it
create or replace function public.automation_claim_message(p_message uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  m public.communication_logs;
  s public.schools;
  v_redirect text;
  v_to text; v_subject text; v_html text;
begin
  update public.communication_logs
     set attempt_count = attempt_count + 1,
         status = 'queued'
   where id = p_message and direction = 'outbound' and attempt_count = 0
     and (status = 'approved' or (status = 'queued' and not requires_approval))
  returning * into m;
  if not found then return jsonb_build_object('send', false, 'reason', 'not ready or already claimed'); end if;

  select * into s from public.schools where id = m.school_id;
  v_redirect := nullif(s.settings->>'demo_redirect_email', '');

  if v_redirect is not null then
    -- Demo school: every message (email or SMS) goes to the operator's inbox, clearly labelled
    v_to := v_redirect;
    v_subject := '[DEMO ' || upper(m.channel) || ' to ' || coalesce(m.recipient, 'unknown') || '] ' || coalesce(m.subject, s.name);
  elsif m.channel = 'email' and m.recipient ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    v_to := m.recipient;
    v_subject := coalesce(m.subject, s.name);
  else
    update public.communication_logs
       set status = 'failed',
           error = case when m.channel = 'sms' then 'SMS provider not connected yet (Africa''s Talking)' else 'No valid email address' end
     where id = m.id;
    insert into public.automation_logs (school_id, scenario, status, related_type, related_id, message)
    values (m.school_id, 'S0_dispatch', 'skipped', 'message', m.id,
            case when m.channel = 'sms' then 'SMS not sent: SMS provider not connected yet' else 'Not sent: no valid email address' end);
    return jsonb_build_object('send', false, 'reason', 'channel not available');
  end if;

  v_html := '<div style="font-family:Arial,sans-serif;font-size:15px;line-height:1.5;color:#0f2a3a">'
            || replace(app.html_escape(m.body), E'\n', '<br>')
            || '<p style="color:#6b7f8c;font-size:12px;margin-top:24px">' || app.html_escape(s.name)
            || case when v_redirect is not null then ' · Demonstration school (fictional). Sent by EduFlow AI.' else ' · Sent with EduFlow AI' end
            || '</p></div>';

  return jsonb_build_object('send', true, 'to', v_to, 'subject', v_subject, 'html', v_html, 'message_id', m.id);
end $$;

-- S0 step 2: record the outcome
create or replace function public.automation_mark_sent(p_message uuid, p_ok boolean, p_provider_id text default null, p_error text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare m public.communication_logs;
begin
  update public.communication_logs
     set status = case when p_ok then 'sent' else 'failed' end,
         sent_at = case when p_ok then now() else sent_at end,
         provider_message_id = p_provider_id,
         error = case when p_ok then null else left(coalesce(p_error, 'Send failed'), 500) end
   where id = p_message and status = 'queued'
  returning * into m;
  if not found then return jsonb_build_object('ok', false); end if;

  if m.related_type = 'enquiry' and p_ok then
    update public.admissions_enquiries set last_contacted_at = now() where id = m.related_id;
  elsif m.related_type = 'payment_reminder' then
    update public.payment_reminders set status = case when p_ok then 'sent' else 'failed' end,
           sent_at = case when p_ok then now() else sent_at end
     where id = m.related_id and status = 'approved';
  end if;

  insert into public.automation_logs (school_id, scenario, status, related_type, related_id, message)
  values (m.school_id, 'S0_dispatch', case when p_ok then 'success' else 'failed' end, 'message', m.id,
          case when p_ok then 'Sent ' || coalesce(m.template_key, m.related_type, 'message') || ' by ' || m.channel
               else 'Send failed: ' || left(coalesce(p_error, 'unknown error'), 200) end);
  return jsonb_build_object('ok', true, 'status', m.status);
end $$;

-- S3 + S6: the daily job. Builds Monday reminder batches, then one briefing per recipient.
create or replace function public.automation_daily_run(p_force_reminders boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s public.schools;
  d public.v_school_dashboard;
  v_items jsonb := '[]'::jsonb;
  v_batch jsonb;
  v_recipients text[];
  v_html text; v_subject text; v_events text; v_overdue text;
  v_today date := (now() at time zone 'Africa/Nairobi')::date;
begin
  for s in select * from public.schools where status = 'active' loop
    v_batch := null;
    if extract(isodow from v_today) = 1 or p_force_reminders then
      v_batch := public.create_reminder_batch(s.id);
    end if;

    select * into d from public.v_school_dashboard where school_id = s.id;

    select coalesce(string_agg('<li>' || to_char(ev.starts_at at time zone 'Africa/Nairobi', 'Dy DD Mon, HH24:MI') || ': '
                               || app.html_escape(ev.title) || '</li>', '' order by ev.starts_at), '<li>None in the next 7 days</li>')
      into v_events
      from public.school_events ev
     where ev.school_id = s.id and ev.starts_at >= now() and ev.starts_at < now() + interval '7 days';

    select coalesce(string_agg('<li>' || e.reference || ' · ' || replace(e.category, '_', ' ')
                               || case when e.needs_human then ' · needs a personal reply' else '' end || '</li>', '' order by e.follow_up_due_at), '')
      into v_overdue
      from public.admissions_enquiries e
     where e.school_id = s.id and e.status in ('new','acknowledged','in_progress') and e.follow_up_due_at < now();

    v_subject := s.name || ' · morning briefing ' || to_char(v_today, 'Dy DD Mon');
    v_html := '<div style="font-family:Arial,sans-serif;font-size:15px;line-height:1.5;color:#0f2a3a;max-width:640px">'
      || '<h2 style="margin:0 0 4px">Good morning</h2><p style="margin:0 0 16px;color:#4a6372">'
      || app.html_escape(s.name) || ' · ' || to_char(v_today, 'FMDay DD FMMonth YYYY') || '</p>'
      || '<p><b>First:</b> ' || case
           when d.overdue_follow_ups > 0 then d.overdue_follow_ups || ' enquiry follow-up(s) are overdue.'
           when d.messages_awaiting_approval + d.reminders_awaiting_approval > 0 then (d.messages_awaiting_approval + d.reminders_awaiting_approval) || ' item(s) are waiting for your approval.'
           else 'nothing urgent. Have a good day.' end || '</p>'
      || '<h3 style="margin:16px 0 4px">Admissions</h3><ul>'
      || '<li>Open enquiries: ' || d.open_enquiries || ' (' || d.enquiries_7d || ' received in the last 7 days)</li>'
      || '<li>Applications in progress: ' || d.pending_applications || ' (' || d.incomplete_applications || ' missing documents)</li></ul>'
      || case when v_overdue <> '' then '<p style="margin:0">Overdue follow-ups:</p><ul>' || v_overdue || '</ul>' else '' end
      || '<h3 style="margin:16px 0 4px">Waiting for approval</h3><ul>'
      || '<li>Parent replies: ' || d.messages_awaiting_approval || '</li>'
      || '<li>Fee reminders: ' || d.reminders_awaiting_approval
      || case when v_batch is not null and (v_batch->>'drafts')::int > 0 then ' (' || (v_batch->>'drafts') || ' new this morning)' else '' end || '</li></ul>'
      || '<h3 style="margin:16px 0 4px">Fees (totals only)</h3><ul><li>Overdue balances: KES '
      || to_char(d.overdue_fees, 'FM999,999,999,990') || '</li></ul>'
      || '<h3 style="margin:16px 0 4px">This week</h3><ul>' || v_events || '</ul>'
      || '<h3 style="margin:16px 0 4px">Tasks</h3><ul><li>Open tasks: ' || d.open_tasks || '</li></ul>'
      || '<p style="color:#6b7f8c;font-size:12px;margin-top:24px">Sent by EduFlow AI. Totals only: no learner names or individual balances are included in this email.'
      || case when s.settings ? 'demo_redirect_email' then ' This is a fictional demonstration school.' else '' end || '</p></div>';

    select array(select distinct x from (
             select jsonb_array_elements_text(coalesce(s.settings->'briefing_recipients', '[]'::jsonb)) x
             union
             select p.email from public.school_memberships m join public.user_profiles p on p.id = m.user_id
              where m.school_id = s.id and m.status = 'active' and m.role_key in ('school_admin','head_teacher') and p.email is not null
           ) r where x ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')
      into v_recipients;
    if nullif(s.settings->>'demo_redirect_email', '') is not null then
      v_recipients := array[s.settings->>'demo_redirect_email'];
    end if;

    if cardinality(v_recipients) > 0 then
      select v_items || coalesce(jsonb_agg(jsonb_build_object('school_id', s.id, 'to', r, 'subject', v_subject, 'html', v_html)), '[]'::jsonb)
        into v_items from unnest(v_recipients) r;
    end if;

    insert into public.automation_logs (school_id, scenario, status, message, details)
    values (s.id, 'S6_daily_briefing', case when cardinality(v_recipients) > 0 then 'success' else 'skipped' end,
            case when cardinality(v_recipients) > 0 then 'Briefing prepared for ' || cardinality(v_recipients) || ' recipient(s)'
                 else 'No briefing recipients set' end
            || case when v_batch is not null then '; reminder batch: ' || (v_batch->>'drafts') || ' draft(s)' else '' end,
            coalesce(jsonb_build_object('reminder_batch', v_batch), '{}'::jsonb));
  end loop;
  return jsonb_build_object('items', v_items, 'count', jsonb_array_length(v_items));
end $$;

-- Generic log entry from Make error handlers
create or replace function public.automation_log(p_scenario text, p_status text, p_message text, p_related_id uuid default null)
returns void
language sql security definer set search_path = public as $$
  insert into public.automation_logs (school_id, scenario, status, related_id, message)
  values (null, left(p_scenario, 60), case when p_status in ('started','success','partial','failed','skipped') then p_status else 'failed' end,
          p_related_id, left(p_message, 500));
$$;

-- Only Make (service_role) may call the automation functions
do $$
declare f text;
begin
  foreach f in array array['automation_enquiry_context(uuid)', 'automation_apply_classification(uuid,jsonb,text)',
                           'automation_claim_message(uuid)', 'automation_mark_sent(uuid,boolean,text,text)',
                           'automation_daily_run(boolean)', 'automation_log(text,text,text,uuid)']
  loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
revoke execute on function app.notify_make(text, uuid), app.config_value(text) from public, anon, authenticated;
