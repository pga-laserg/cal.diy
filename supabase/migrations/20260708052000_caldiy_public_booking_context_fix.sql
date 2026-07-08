-- Follow-up patch for the public booking context resolver.
-- This keeps the public RPCs stable while fixing the record initialization bug.

begin;

create or replace function private.resolve_public_booking_context(
  p_username text,
  p_event_slug text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_usernames text[] := private.parse_public_username_list(p_username);
  v_is_group boolean := cardinality(v_usernames) > 1;
  v_user_record record;
  v_profile_id bigint;
  v_profile_uid text;
  v_profile_username text;
  v_profile_org_id bigint;
  v_team_id bigint;
  v_team_slug text;
  v_team_name text;
  v_team_banner_url text;
  v_team_time_zone text;
  v_team_week_start text;
  v_team_hide_branding boolean;
  v_event_record record;
  v_users jsonb := '[]'::jsonb;
  v_user_ids bigint[] := '{}'::bigint[];
  v_kind text := 'user';
  v_synthetic_event jsonb;
begin
  select
    null::bigint as id,
    null::text as slug,
    null::text as title,
    null::text as description,
    null::text as interface_language,
    null::integer as position,
    null::jsonb as locations,
    null::integer as length,
    null::integer as offset_start,
    null::boolean as hidden
  into v_event_record;

  if v_is_group then
    select
      u.id,
      u.username,
      u.name,
      u.avatar_url,
      u.time_zone,
      u.allow_dynamic_booking,
      u.allow_seo_indexing,
      u.hide_branding
    into v_user_record
    from public.users u
    where u.username = any(v_usernames)
    order by array_position(v_usernames, u.username)
    limit 1;

    if v_user_record.id is null then
      return null;
    end if;

    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', u.id,
          'username', u.username,
          'name', u.name,
          'avatar_url', u.avatar_url,
          'time_zone', u.time_zone,
          'allow_dynamic_booking', u.allow_dynamic_booking,
          'allow_seo_indexing', u.allow_seo_indexing,
          'hide_branding', u.hide_branding
        )
        order by array_position(v_usernames, u.username)
      ),
      '[]'::jsonb
    )
    into v_users
    from public.users u
    where u.username = any(v_usernames);

    select array_agg((item->>'id')::bigint order by ord)
    into v_user_ids
    from jsonb_array_elements(v_users) with ordinality as user_item(item, ord);

    v_kind := 'group';
    v_synthetic_event := jsonb_build_object(
      'id', null,
      'slug', p_event_slug,
      'title', initcap(replace(p_event_slug, '-', ' ')),
      'description', null,
      'interface_language', null,
      'position', 0,
      'locations', '[]'::jsonb,
      'length', 30,
      'offset_start', 0,
      'hidden', false
    );

    return jsonb_build_object(
      'kind', v_kind,
      'usernames', to_jsonb(v_usernames),
      'user', jsonb_build_object(
        'id', v_user_record.id,
        'username', v_user_record.username,
        'name', v_user_record.name,
        'avatar_url', v_user_record.avatar_url,
        'time_zone', v_user_record.time_zone,
        'allow_dynamic_booking', v_user_record.allow_dynamic_booking,
        'allow_seo_indexing', v_user_record.allow_seo_indexing,
        'hide_branding', v_user_record.hide_branding
      ),
      'users', v_users,
      'profile', null,
      'team', null,
      'event_type', v_synthetic_event,
      'organizer_user_id', v_user_record.id,
      'user_ids', to_jsonb(coalesce(v_user_ids, '{}'::bigint[]))
    );
  end if;

  select
    u.id,
    u.username,
    u.name,
    u.avatar_url,
    u.time_zone,
    u.allow_dynamic_booking,
    u.allow_seo_indexing,
    u.hide_branding
  into v_user_record
  from public.users u
  where u.username = p_username
  limit 1;

  if v_user_record.id is not null then
    select
      p.id,
      p.uid,
      p.username,
      p.organization_id
    into
      v_profile_id,
      v_profile_uid,
      v_profile_username,
      v_profile_org_id
    from public.profiles p
    where p.user_id = v_user_record.id
      and p.username = p_username
    limit 1;

    select
      t.id,
      t.slug,
      t.name,
      t.banner_url,
      t.time_zone,
      t.week_start,
      t.hide_branding
    into
      v_team_id,
      v_team_slug,
      v_team_name,
      v_team_banner_url,
      v_team_time_zone,
      v_team_week_start,
      v_team_hide_branding
    from public.teams t
    where t.id = coalesce(
      (select u.organization_id from public.users u where u.id = v_user_record.id),
      v_profile_org_id
    )
    limit 1;
  else
    v_kind := 'team';
    select
      t.id,
      t.slug,
      t.name,
      t.banner_url,
      t.time_zone,
      t.week_start,
      t.hide_branding
    into
      v_team_id,
      v_team_slug,
      v_team_name,
      v_team_banner_url,
      v_team_time_zone,
      v_team_week_start,
      v_team_hide_branding
    from public.teams t
    where t.slug = p_username
    limit 1;
  end if;

  if v_user_record.id is not null then
    select e.id, e.slug, e.title, e.description, e.interface_language, e.position, e.locations, e.length, e.offset_start, e.hidden
    into v_event_record
    from public.event_types e
    where e.slug = p_event_slug
      and e.hidden = false
      and (
        e.user_id = v_user_record.id
        or (v_profile_id is not null and e.profile_id = v_profile_id)
        or (v_team_id is not null and e.team_id = v_team_id)
      )
    order by
      case
        when e.user_id = v_user_record.id then 0
        when v_profile_id is not null and e.profile_id = v_profile_id then 1
        when v_team_id is not null and e.team_id = v_team_id then 2
        else 3
      end
    limit 1;
  elsif v_team_id is not null then
    select e.id, e.slug, e.title, e.description, e.interface_language, e.position, e.locations, e.length, e.offset_start, e.hidden
    into v_event_record
    from public.event_types e
    where e.slug = p_event_slug
      and e.hidden = false
      and e.team_id = v_team_id
    order by e.position, e.id
    limit 1;
  end if;

  if v_event_record.id is null then
    return null;
  end if;

  return jsonb_build_object(
    'kind', v_kind,
    'usernames', to_jsonb(v_usernames),
    'user', case
      when v_user_record.id is null then null
      else jsonb_build_object(
        'id', v_user_record.id,
        'username', v_user_record.username,
        'name', v_user_record.name,
        'avatar_url', v_user_record.avatar_url,
        'time_zone', v_user_record.time_zone,
        'allow_dynamic_booking', v_user_record.allow_dynamic_booking,
        'allow_seo_indexing', v_user_record.allow_seo_indexing,
        'hide_branding', v_user_record.hide_branding
      )
    end,
    'users', coalesce(v_users, '[]'::jsonb),
    'profile', case
      when v_profile_id is null then null
      else jsonb_build_object(
        'id', v_profile_id,
        'uid', v_profile_uid,
        'username', v_profile_username,
        'organization_id', v_profile_org_id
      )
    end,
    'team', case
      when v_team_id is null then null
      else jsonb_build_object(
        'id', v_team_id,
        'slug', v_team_slug,
        'name', v_team_name,
        'banner_url', v_team_banner_url,
        'time_zone', v_team_time_zone,
        'week_start', v_team_week_start,
        'hide_branding', v_team_hide_branding
      )
    end,
    'event_type', jsonb_build_object(
      'id', v_event_record.id,
      'slug', v_event_record.slug,
      'title', v_event_record.title,
      'description', v_event_record.description,
      'interface_language', v_event_record.interface_language,
      'position', v_event_record.position,
      'locations', coalesce(v_event_record.locations, '[]'::jsonb),
      'length', v_event_record.length,
      'offset_start', v_event_record.offset_start,
      'hidden', v_event_record.hidden
    ),
    'organizer_user_id', v_user_record.id,
    'user_ids', case
      when v_user_ids is null then '[]'::jsonb
      else to_jsonb(v_user_ids)
    end
  );
end;
$$;

commit;
