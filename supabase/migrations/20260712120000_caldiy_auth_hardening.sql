-- Close direct Data API write paths into identity and authorization records.

begin;

alter table public.users enable row level security;

do $$
begin
  if to_regclass('public.teams') is not null then
    execute 'alter table public.teams enable row level security';
  end if;
end;
$$;

alter table public.users
  alter column auth_user_id drop not null;

do $$
begin
  if exists (
    select 1
    from pg_constraint
    where conname = 'users_auth_user_id_fkey'
      and conrelid = 'public.users'::regclass
  ) then
    alter table public.users drop constraint users_auth_user_id_fkey;
  end if;
end;
$$;

alter table public.users
  add constraint users_auth_user_id_fkey
  foreign key (auth_user_id)
  references auth.users(id)
  on delete set null;

drop policy if exists "users_self_insert" on public.users;
drop policy if exists "users_self_update" on public.users;

revoke insert, update, delete on public.users from authenticated;

do $$
begin
  if to_regclass('public.teams') is not null then
    execute 'drop policy if exists "teams_authenticated_insert" on public.teams';
    execute 'revoke insert, update, delete on public.teams from authenticated';
  end if;
end;
$$;

-- Only the immutable Supabase subject may resolve an existing Cal user.
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
begin
  insert into public.users (
    auth_user_id,
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
    new.id,
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
    gen_random_uuid()
  )
  on conflict (auth_user_id) where auth_user_id is not null do update
  set email = excluded.email,
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
set search_path = pg_catalog, public, auth
as $$
begin
  update public.users
  set email = coalesce(new.email, email),
      "emailVerified" = new.email_confirmed_at
  where auth_user_id = new.id;

  return new;
end;
$$;

revoke all on function private.handle_new_user() from public, authenticated;
revoke all on function private.handle_auth_user_update() from public, authenticated;

commit;
