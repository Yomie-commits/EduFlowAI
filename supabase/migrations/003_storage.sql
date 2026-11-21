-- =====================================================================
-- EduFlow AI  |  Migration 003: private document storage
-- Bucket: application-documents (private, 5 MB, PDF/JPG/PNG)
-- Path:   {school_id}/{application_id}/{upload_token}/{file_name}
-- Parents can UPLOAD only into their own application's folder (they hold
-- the upload_token). Nobody anonymous can read. Admissions staff of that
-- school read through short-lived signed URLs.
-- =====================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('application-documents', 'application-documents', false, 5242880,
        array['application/pdf','image/jpeg','image/png'])
on conflict (id) do update set public = false;

create or replace function app.can_upload_application_doc(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.applications a
    where a.school_id::text      = split_part(p_name, '/', 1)
      and a.id::text             = split_part(p_name, '/', 2)
      and a.upload_token::text   = split_part(p_name, '/', 3)
      and a.status in ('submitted','incomplete','complete')
      and a.created_at > now() - interval '30 days');
$$;

create or replace function app.can_read_school_folder(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select split_part(p_name, '/', 1) ~ '^[0-9a-f-]{36}$'
     and app.in_group(split_part(p_name, '/', 1)::uuid, 'admissions');
$$;

grant execute on function app.can_upload_application_doc(text) to anon, authenticated;
grant execute on function app.can_read_school_folder(text) to authenticated;

create policy "applicants upload own documents"
  on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'application-documents' and app.can_upload_application_doc(name));

create policy "admissions staff read documents"
  on storage.objects for select to authenticated
  using (bucket_id = 'application-documents' and app.can_read_school_folder(name));

create policy "admissions staff delete documents"
  on storage.objects for delete to authenticated
  using (bucket_id = 'application-documents' and app.can_read_school_folder(name));
