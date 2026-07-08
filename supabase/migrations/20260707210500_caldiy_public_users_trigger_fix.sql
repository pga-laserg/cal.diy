-- Keep the auth-to-public user mapping aligned with the Cal.diy table shape.

begin;

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  insert into public.users (
    auth_user_id,
    username,
    name,
    email,
    email_verified,
    avatar_url,
    time_zone,
    role,
    identity_provider,
    created_at,
    completed_onboarding
  )
  values (
    new.id,
    nullif(coalesce(new.raw_user_meta_data ->> 'username', new.raw_user_meta_data ->> 'user_name'), ''),
    nullif(coalesce(new.raw_user_meta_data ->> 'name', new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'display_name'), ''),
    coalesce(new.email, ''),
    new.email_confirmed_at,
    nullif(new.raw_user_meta_data ->> 'avatar_url', ''),
    coalesce(nullif(new.raw_user_meta_data ->> 'time_zone', ''), 'Europe/London'),
    'USER',
    'CAL',
    now(),
    false
  )
  on conflict (auth_user_id) do update
  set email = excluded.email,
      email_verified = excluded.email_verified,
      username = coalesce(excluded.username, public.users.username),
      name = coalesce(excluded.name, public.users.name),
      avatar_url = coalesce(excluded.avatar_url, public.users.avatar_url),
      time_zone = coalesce(excluded.time_zone, public.users.time_zone);

  return new;
end;
$$;

create or replace function private.handle_auth_user_update()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  update public.users u
  set email = coalesce(new.email, u.email),
      email_verified = new.email_confirmed_at
  where u.auth_user_id = new.id;

  return new;
end;
$$;

commit;
