-- =====================================================================
-- EduFlow AI  |  Migration 005: onboarding schools and staff
-- The platform operator (user_profiles.is_super_admin) creates schools
-- through normal RLS (schools_insert policy). Staff are added by email:
-- the person must already have a Supabase Auth login (invited from
-- Supabase > Authentication > Users > Invite user). This function then
-- links them to the school with a role. Only a school administrator of
-- that school, or the platform operator, may call it.
-- =====================================================================

create or replace function public.admin_add_member(p_school uuid, p_email text, p_role text, p_full_name text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid   uuid;
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_name  text;
begin
  if auth.uid() is null or not app.in_group(p_school, 'admin') then
    raise exception 'Only the school administrator or the platform operator can add staff';
  end if;
  if p_role not in ('school_admin','head_teacher','bursar','admissions_officer','teacher') then
    raise exception 'Unknown role';
  end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Please enter a valid email address';
  end if;

  select id into v_uid from auth.users where lower(email) = v_email;
  if v_uid is null then
    return jsonb_build_object('status', 'not_found');
  end if;

  v_name := coalesce(nullif(btrim(p_full_name), ''), split_part(v_email, '@', 1));
  insert into public.user_profiles (id, email, full_name) values (v_uid, v_email, v_name)
  on conflict (id) do update set full_name = coalesce(nullif(btrim(p_full_name), ''), user_profiles.full_name),
                                 email = coalesce(user_profiles.email, excluded.email);

  insert into public.school_memberships (school_id, user_id, role_key) values (p_school, v_uid, p_role)
  on conflict (school_id, user_id, role_key) do update set status = 'active';

  insert into public.staff (school_id, user_id, full_name, email, job_title)
  select p_school, v_uid, v_name, v_email, initcap(replace(p_role, '_', ' '))
  where not exists (select 1 from public.staff where school_id = p_school and user_id = v_uid);

  return jsonb_build_object('status', 'added', 'user_id', v_uid);
end $$;

revoke execute on function public.admin_add_member(uuid, text, text, text) from public, anon;
grant execute on function public.admin_add_member(uuid, text, text, text) to authenticated;

-- The operator and school admins need to see who is in a school (names + emails)
create or replace function public.school_members(p_school uuid)
returns table (membership_id uuid, user_id uuid, email text, full_name text, role_key text, status text)
language sql stable security definer set search_path = public as $$
  select m.id, m.user_id, p.email, p.full_name, m.role_key, m.status
  from public.school_memberships m join public.user_profiles p on p.id = m.user_id
  where m.school_id = p_school and app.in_group(p_school, 'leaders')
  order by p.full_name;
$$;
revoke execute on function public.school_members(uuid) from public, anon;
grant execute on function public.school_members(uuid) to authenticated;

-- Whoever is signed in can read their own operator flag
create or replace function public.my_profile()
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', id, 'email', email, 'full_name', full_name, 'is_super_admin', is_super_admin)
  from public.user_profiles where id = auth.uid();
$$;
revoke execute on function public.my_profile() from public, anon;
grant execute on function public.my_profile() to authenticated;
