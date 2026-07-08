-- Public booking lookup bridge for the Cal.diy-shaped Supabase port.
-- Keep the returned payload narrow so the web app can render the booking page
-- without exposing the raw user, team, or event tables to anonymous clients.

begin;

create or replace function public.get_public_booking_page(
  p_username text,
  p_event_slug text
)
returns jsonb
language sql
stable
security definer
set search_path = public, auth
as $$
  select jsonb_build_object(
    'user',
      jsonb_build_object(
        'id', u.id,
        'username', u.username,
        'name', u.name,
        'avatar_url', u.avatar_url,
        'time_zone', u.time_zone,
        'allow_dynamic_booking', u.allow_dynamic_booking,
        'allow_seo_indexing', u.allow_seo_indexing,
        'hide_branding', u.hide_branding
      ),
    'profile',
      case
        when p.id is null then null
        else jsonb_build_object(
          'id', p.id,
          'username', p.username,
          'organization_id', p.organization_id
        )
      end,
    'team',
      case
        when t.id is null then null
        else jsonb_build_object(
          'id', t.id,
          'slug', t.slug,
          'name', t.name,
          'banner_url', t.banner_url,
          'time_zone', t.time_zone,
          'week_start', t.week_start,
          'hide_branding', t.hide_branding
        )
      end,
    'event_type',
      jsonb_build_object(
        'id', e.id,
        'slug', e.slug,
        'title', e.title,
        'description', e.description,
        'length', e.length,
        'offset_start', e.offset_start,
        'hidden', e.hidden,
        'locations', e.locations,
        'interface_language', e.interface_language,
        'position', e.position
      )
  )
  from public.users u
  join public.event_types e
    on e.user_id = u.id
   and e.slug = p_event_slug
   and e.hidden = false
  left join public.profiles p
    on p.user_id = u.id
   and p.username = p_username
  left join public.teams t
    on t.id = coalesce(u.organization_id, p.organization_id)
  where u.username = p_username
  limit 1;
$$;

grant execute on function public.get_public_booking_page(text, text) to anon, authenticated;

commit;
