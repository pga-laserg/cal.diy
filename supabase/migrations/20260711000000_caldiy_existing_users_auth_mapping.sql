-- Add Supabase Auth identity mapping to an existing Cal schema without
-- rewriting the legacy users table or removing existing users.

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
  and lower(cal_user.email) = lower(auth_user.email);

commit;
