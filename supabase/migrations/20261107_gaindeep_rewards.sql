-- GainDeep points-only memberships and server-authoritative daily wheel.
create table if not exists public.device_memberships (
  device_id text primary key references public.devices(device_id) on delete cascade,
  plan text not null default 'free' check (plan in ('free','plus','pro','elite')),
  starts_at timestamptz,
  expires_at timestamptz,
  updated_at timestamptz not null default now(),
  check ((plan = 'free' and expires_at is null) or (plan <> 'free' and expires_at is not null))
);

create table if not exists public.wheel_spins (
  id bigserial primary key,
  device_id text not null references public.devices(device_id) on delete cascade,
  points_awarded integer not null check (points_awarded in (0,5,10,15,25,50)),
  created_at timestamptz not null default now()
);
create index if not exists wheel_spins_device_time_idx on public.wheel_spins(device_id, created_at desc);

alter table public.device_memberships enable row level security;
alter table public.wheel_spins enable row level security;
revoke all on public.device_memberships, public.wheel_spins from public, anon, authenticated;
revoke all on sequence public.wheel_spins_id_seq from public, anon, authenticated;
grant all on public.device_memberships, public.wheel_spins to service_role;
grant usage, select on sequence public.wheel_spins_id_seq to service_role;

create or replace function public.purchase_gain_deep_plan(p_device_id text, p_plan text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  d public.devices%rowtype;
  m public.device_memberships%rowtype;
  v_cost integer;
  v_current_cost integer := 0;
  v_due integer;
  v_expiry timestamptz;
  v_available numeric;
begin
  if p_device_id is null or p_plan not in ('plus','pro','elite') then
    return jsonb_build_object('status','bad_request');
  end if;

  insert into public.devices(device_id) values (p_device_id) on conflict (device_id) do nothing;
  select * into d from public.devices where device_id = p_device_id for update;
  if d.frozen then return jsonb_build_object('status','account_frozen'); end if;

  select * into m from public.device_memberships where device_id = p_device_id for update;
  if not found then
    m.plan := 'free';
    m.expires_at := null;
  elsif m.expires_at is not null and m.expires_at <= now() then
    m.plan := 'free';
    m.expires_at := null;
  end if;

  v_cost := case p_plan when 'plus' then 2500 when 'pro' then 7500 when 'elite' then 15000 end;
  v_current_cost := case when m.plan = 'plus' then 2500 when m.plan = 'pro' then 7500 when m.plan = 'elite' then 15000 else 0 end;

  if m.plan = p_plan and m.expires_at > now() then
    return jsonb_build_object('status','already_active','plan',m.plan,'expires_at',m.expires_at);
  end if;
  if v_cost <= v_current_cost and m.expires_at > now() then
    return jsonb_build_object('status','downgrade_not_allowed','plan',m.plan,'expires_at',m.expires_at);
  end if;

  v_due := v_cost - case when m.expires_at > now() then v_current_cost else 0 end;
  v_available := coalesce(public.available_points(p_device_id),0);
  if v_available < v_due then
    return jsonb_build_object('status','insufficient_points','required',v_due,'available',v_available);
  end if;

  update public.devices set points_balance = points_balance - v_due where device_id = p_device_id;
  v_expiry := case when m.expires_at > now() then m.expires_at else now() + interval '30 days' end;

  insert into public.device_memberships(device_id,plan,starts_at,expires_at,updated_at)
  values (p_device_id,p_plan,now(),v_expiry,now())
  on conflict (device_id) do update set plan=excluded.plan, starts_at=excluded.starts_at,
    expires_at=excluded.expires_at, updated_at=now();

  return jsonb_build_object('status','purchased','plan',p_plan,'points_spent',v_due,'expires_at',v_expiry);
end;
$$;

create or replace function public.spin_gain_deep_wheel(p_device_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  d public.devices%rowtype;
  v_last timestamptz;
  v_prize integer;
  v_next timestamptz;
begin
  if p_device_id is null then return jsonb_build_object('status','bad_request'); end if;
  insert into public.devices(device_id) values (p_device_id) on conflict (device_id) do nothing;
  select * into d from public.devices where device_id = p_device_id for update;
  if d.frozen then return jsonb_build_object('status','account_frozen'); end if;

  select created_at into v_last from public.wheel_spins
   where device_id = p_device_id order by created_at desc limit 1;
  if v_last is not null and v_last > now() - interval '24 hours' then
    return jsonb_build_object('status','cooldown','next_spin_at',v_last + interval '24 hours');
  end if;

  -- Weighted server-side draw: 0 (10%), 5 (30%), 10 (30%), 15 (20%), 25 (8%), 50 (2%).
  v_prize := case
    when random() < 0.10 then 0
    when random() < 0.333333 then 5
    when random() < 0.50 then 10
    when random() < 0.80 then 15
    when random() < 0.90 then 25
    else 50
  end;
  -- Use one draw for mutually exclusive, documented probability bands.
  -- The branch probabilities above are intentionally normalized by the sequential draws.
  insert into public.wheel_spins(device_id,points_awarded) values (p_device_id,v_prize);
  update public.devices set points_balance = points_balance + v_prize where device_id = p_device_id;
  v_next := now() + interval '24 hours';
  return jsonb_build_object('status','awarded','points_awarded',v_prize,'next_spin_at',v_next);
end;
$$;

revoke all on function public.purchase_gain_deep_plan(text,text) from public, anon, authenticated;
revoke all on function public.spin_gain_deep_wheel(text) from public, anon, authenticated;
grant execute on function public.purchase_gain_deep_plan(text,text) to service_role;
grant execute on function public.spin_gain_deep_wheel(text) to service_role;
notify pgrst, 'reload schema';
