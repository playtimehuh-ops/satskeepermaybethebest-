-- GainDeep streaming foundation. Run in Supabase SQL Editor after the base schema.
create table if not exists public.stream_creator_applications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 3 and 32),
  reason text not null check (char_length(reason) between 20 and 500),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  adult_verified_at timestamptz,
  constraint stream_creator_approval_requires_adult check (status <> 'approved' or adult_verified_at is not null),
  unique (user_id)
);
create table if not exists public.stream_sessions (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references auth.users(id) on delete cascade,
  creator_name text not null,
  title text not null check (char_length(title) between 3 and 100),
  provider text,
  provider_room_id text unique,
  playback_url text,
  status text not null default 'scheduled' check (status in ('scheduled','live','ended','cancelled')),
  moderation_status text not null default 'pending' check (moderation_status in ('pending','approved','blocked')),
  created_at timestamptz not null default now(),
  started_at timestamptz,
  ended_at timestamptz
);
create table if not exists public.stream_donations (
  id uuid primary key default gen_random_uuid(),
  stream_id uuid not null references public.stream_sessions(id) on delete cascade,
  donor_id uuid not null references auth.users(id) on delete restrict,
  creator_id uuid not null references auth.users(id) on delete restrict,
  points_total integer not null check (points_total between 10 and 10000 and points_total % 10 = 0),
  creator_points integer not null check (creator_points >= 0),
  platform_points integer not null check (platform_points >= 0),
  created_at timestamptz not null default now()
);
create table if not exists public.stream_reports (
  id uuid primary key default gen_random_uuid(),
  stream_id uuid not null references public.stream_sessions(id) on delete cascade,
  reporter_id uuid not null references auth.users(id) on delete restrict,
  reason text not null check (char_length(reason) between 3 and 120),
  status text not null default 'open' check (status in ('open','reviewing','resolved','dismissed')),
  created_at timestamptz not null default now(),
  unique (stream_id, reporter_id)
);
create index if not exists stream_sessions_live_idx on public.stream_sessions(status, moderation_status, created_at desc);
create index if not exists stream_reports_queue_idx on public.stream_reports(status, created_at);
alter table public.stream_creator_applications enable row level security;
alter table public.stream_sessions enable row level security;
alter table public.stream_donations enable row level security;
alter table public.stream_reports enable row level security;
revoke all on public.stream_creator_applications, public.stream_sessions, public.stream_donations, public.stream_reports from public, anon, authenticated;
grant all on public.stream_creator_applications, public.stream_sessions, public.stream_donations, public.stream_reports to service_role;

create or replace function public.donate_stream_points(p_donor_id uuid, p_stream_id uuid, p_points integer)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  s public.stream_sessions%rowtype;
  donor public.devices%rowtype;
  creator public.devices%rowtype;
  v_creator_points integer;
  v_platform_points integer;
begin
  if p_donor_id is null or p_stream_id is null or p_points is null or p_points < 10 or p_points > 10000 or p_points % 10 <> 0 then
    return jsonb_build_object('status','invalid');
  end if;
  select * into s from public.stream_sessions where id = p_stream_id for update;
  if not found or s.status <> 'live' or s.moderation_status <> 'approved' then return jsonb_build_object('status','not_live'); end if;
  if s.creator_id = p_donor_id then return jsonb_build_object('status','self_donation'); end if;
  -- Lock both accounts in stable order to avoid reciprocal-donation deadlocks.
  perform 1 from public.devices
   where device_id in (p_donor_id::text, s.creator_id::text)
   order by device_id
   for update;
  select * into donor from public.devices where device_id = p_donor_id::text;
  if not found or donor.frozen or public.available_points(p_donor_id::text) < p_points then return jsonb_build_object('status','insufficient_points'); end if;
  select * into creator from public.devices where device_id = s.creator_id::text;
  if not found or creator.frozen then return jsonb_build_object('status','creator_unavailable'); end if;
  v_creator_points := floor(p_points * 0.70)::integer;
  v_platform_points := p_points - v_creator_points;
  update public.devices set points_balance = points_balance - p_points where device_id = p_donor_id::text;
  update public.devices set points_balance = points_balance + v_creator_points where device_id = s.creator_id::text;
  insert into public.stream_donations(stream_id, donor_id, creator_id, points_total, creator_points, platform_points)
  values (p_stream_id, p_donor_id, s.creator_id, p_points, v_creator_points, v_platform_points);
  return jsonb_build_object('status','donated','points_total',p_points,'creator_points',v_creator_points,'platform_points',v_platform_points);
end;
$$;
revoke all on function public.donate_stream_points(uuid, uuid, integer) from public, anon, authenticated;
grant execute on function public.donate_stream_points(uuid, uuid, integer) to service_role;
notify pgrst, 'reload schema';
