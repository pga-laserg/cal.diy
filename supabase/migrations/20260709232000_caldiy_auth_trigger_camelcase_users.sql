-- Keep Supabase Auth mirroring aligned with the Cal.diy public.users schema.

begin;

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  insert into public.users (
    username,
    name,
    email,
    "emailVerified",
    "avatarUrl",
    "timeZone",
    role,
    "identityProvider",
    created,
    "completedOnboarding",
    uuid
  )
  values (
    nullif(coalesce(new.raw_user_meta_data ->> 'username', new.raw_user_meta_data ->> 'user_name'), ''),
    nullif(coalesce(new.raw_user_meta_data ->> 'name', new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'display_name'), ''),
    coalesce(new.email, ''),
    new.email_confirmed_at,
    nullif(new.raw_user_meta_data ->> 'avatar_url', ''),
    coalesce(nullif(new.raw_user_meta_data ->> 'time_zone', ''), 'Europe/London'),
    'USER',
    'CAL',
    now(),
    false,
    gen_random_uuid()
  )
  on conflict (email) do update
  set "emailVerified" = excluded."emailVerified",
      username = coalesce(excluded.username, public.users.username),
      name = coalesce(excluded.name, public.users.name),
      "avatarUrl" = coalesce(excluded."avatarUrl", public.users."avatarUrl"),
      "timeZone" = coalesce(excluded."timeZone", public.users."timeZone");

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
      "emailVerified" = new.email_confirmed_at
  where u.email = old.email or u.email = new.email;

  return new;
end;
$$;

commit;
