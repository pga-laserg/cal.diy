-- Link every Supabase identity to exactly one legacy Cal user. The trigger is
-- intentionally idempotent so it also repairs accounts created before mapping
-- support was deployed.

begin;

alter table public.users
  add column if not exists auth_user_id uuid;

create unique index if not exists users_auth_user_id_key
  on public.users (auth_user_id)
  where auth_user_id is not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'users_auth_user_id_fkey'
      and conrelid = 'public.users'::regclass
  ) then
    alter table public.users
      add constraint users_auth_user_id_fkey
      foreign key (auth_user_id)
      references auth.users(id)
      on delete set null;
  end if;
end;
$$;

update public.users as cal_user
set auth_user_id = auth_user.id
from auth.users as auth_user
where cal_user.auth_user_id is null
  and auth_user.email is not null
  and lower(cal_user.email) = lower(auth_user.email);

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
    uuid,
    auth_user_id
  )
  values (
    nullif(coalesce(new.raw_user_meta_data ->> 'username', new.raw_user_meta_data ->> 'user_name'), ''),
    nullif(coalesce(new.raw_user_meta_data ->> 'name', new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'display_name'), ''),
    coalesce(new.email, concat('phone-', new.id::text, '@auth.local')),
    new.email_confirmed_at,
    nullif(new.raw_user_meta_data ->> 'avatar_url', ''),
    coalesce(nullif(new.raw_user_meta_data ->> 'time_zone', ''), 'Europe/London'),
    'USER',
    'CAL',
    now(),
    false,
    gen_random_uuid(),
    new.id
  )
  on conflict (email) do update
  set auth_user_id = excluded.auth_user_id,
      "emailVerified" = excluded."emailVerified",
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
  update public.users as cal_user
  set email = coalesce(new.email, cal_user.email),
      "emailVerified" = new.email_confirmed_at,
      auth_user_id = new.id
  where cal_user.auth_user_id = new.id
     or (old.email is not null and lower(cal_user.email) = lower(old.email))
     or (new.email is not null and lower(cal_user.email) = lower(new.email));

  return new;
end;
$$;

commit;
