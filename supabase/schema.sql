-- SatsKeeper schema. Idempotent: safe to run again on top of an older version.
-- Run it in the Supabase SQL editor. All money logic lives in the functions below
-- so it is atomic (row locks) and cannot be raced from the API layer.

-- ---------------------------------------------------------------- tables
create table if not exists devices (
  device_id text primary key,
  opted_in boolean not null default false,
  points_balance numeric not null default 0,
  streak int not null default 0,
  last_active_at timestamptz
);

create table if not exists bandwidth_logs (
  id bigserial primary key,
  device_id text not null,
  mb_shared numeric not null,
  -- Legacy field retained for migration compatibility; new awards use verified_by_rules.
  verified_by_ai boolean not null default false,
  points_awarded numeric not null default 0,
  gross_revenue_usd numeric not null default 0,
  business_revenue_usd numeric not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists redemptions (
  id bigserial primary key,
  device_id text not null,
  points_spent numeric not null,
  status text not null default 'pending',
  code text,
  product_id text,
  invoice_id text,
  created_at timestamptz not null default now()
);

alter table devices add column if not exists frozen boolean not null default false;
alter table devices add column if not exists frozen_reason text;
alter table devices add column if not exists lifetime_mb numeric not null default 0;
alter table devices add column if not exists created_at timestamptz not null default now();

alter table bandwidth_logs add column if not exists report_id text;
alter table bandwidth_logs add column if not exists status text;
alter table bandwidth_logs add column if not exists elapsed_s numeric;
alter table bandwidth_logs add column if not exists max_mb numeric;
alter table bandwidth_logs add column if not exists vests_at timestamptz;
alter table bandwidth_logs add column if not exists settled_at timestamptz;
-- New reports are checked by deterministic server rules, not an AI auditor.
alter table bandwidth_logs add column if not exists verified_by_rules boolean not null default false;
alter table bandwidth_logs add column if not exists gross_revenue_usd numeric not null default 0;
alter table bandwidth_logs add column if not exists business_revenue_usd numeric not null default 0;
update bandwidth_logs set status = case when verified_by_ai then 'awarded' else 'rejected' end
 where status is null;
alter table bandwidth_logs alter column status set default 'pending';
alter table bandwidth_logs alter column status set not null;

alter table redemptions add column if not exists updated_at timestamptz not null default now();
alter table redemptions add column if not exists note text;

-- ---------------------------------------------------------------- constraints
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'devices_values_ok') then
    alter table devices add constraint devices_values_ok
      check (points_balance >= 0 and streak >= 0 and lifetime_mb >= 0);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'bandwidth_logs_values_ok') then
    alter table bandwidth_logs add constraint bandwidth_logs_values_ok
      check (mb_shared > 0 and mb_shared <= 100000 and points_awarded >= 0);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'bandwidth_logs_status_ok') then
    alter table bandwidth_logs add constraint bandwidth_logs_status_ok
      check (status in ('pending', 'awarded', 'rejected', 'implausible'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'redemptions_values_ok') then
    alter table redemptions add constraint redemptions_values_ok
      check (points_spent > 0 and status in ('pending', 'processing', 'completed', 'failed'));
  end if;
end $$;

-- ---------------------------------------------------------------- indexes
create index if not exists bandwidth_logs_device_idx on bandwidth_logs (device_id, id desc);
create index if not exists bandwidth_logs_recent_idx on bandwidth_logs (device_id, created_at desc);
create index if not exists bandwidth_logs_vest_idx on bandwidth_logs (device_id, vests_at) where status = 'awarded';
create unique index if not exists bandwidth_logs_report_uidx
  on bandwidth_logs (device_id, report_id) where report_id is not null;
create index if not exists redemptions_device_idx on redemptions (device_id, id desc);
create index if not exists redemptions_status_idx on redemptions (status, updated_at);
create index if not exists redemptions_created_idx on redemptions (created_at);
create unique index if not exists redemptions_invoice_uidx on redemptions (invoice_id) where invoice_id is not null;

-- ---------------------------------------------------------------- RLS
-- RLS on with NO policies: the public (anon / logged-in) API can read nothing.
-- Only the service role (used by the Vercel backend) can touch these tables.
alter table devices enable row level security;
alter table bandwidth_logs enable row level security;
alter table redemptions enable row level security;

revoke all on table devices, bandwidth_logs, redemptions from public, anon, authenticated;
revoke all on sequence bandwidth_logs_id_seq, redemptions_id_seq from public, anon, authenticated;
grant all on table devices, bandwidth_logs, redemptions to service_role;
grant usage, select on sequence bandwidth_logs_id_seq, redemptions_id_seq to service_role;

-- ---------------------------------------------------------------- functions
create or replace function add_points(p_device_id text, p_delta numeric)
returns void
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if p_device_id is null or p_delta is null or abs(p_delta) > 1000000 then
    raise exception 'invalid_arguments';
  end if;
  insert into devices (device_id, points_balance)
  values (p_device_id, p_delta)
  on conflict (device_id)
  do update set points_balance = devices.points_balance + excluded.points_balance;
end;
$$;

-- Points the user may spend: balance minus points still vesting (earned < vest window ago).
create or replace function available_points(p_device_id text)
returns numeric
language sql
stable
set search_path = public, pg_temp
as $$
  select greatest(0, d.points_balance - coalesce((
    select sum(l.points_awarded)
      from bandwidth_logs l
     where l.device_id = d.device_id
       and l.status = 'awarded'
       and l.vests_at > now()
  ), 0))
  from devices d
  where d.device_id = p_device_id
$$;

-- Step 1 of a bandwidth report. Locks the device row, applies every hard limit and
-- records the report as 'pending'. Retrying the same report_id never double counts.
create or replace function begin_report(
  p_device_id text,
  p_report_id text,
  p_mb numeric,
  p_min_interval_s int,
  p_max_per_report numeric,
  p_max_per_s numeric,
  p_max_per_day numeric
)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  d devices%rowtype;
  l bandwidth_logs%rowtype;
  v_last_any timestamptz;
  v_last_good timestamptz;
  v_elapsed numeric;
  v_max numeric;
  v_day numeric;
  v_id bigint;
  v_recent jsonb;
begin
  if p_device_id is null or p_report_id is null or p_mb is null or p_mb <= 0
     or length(p_report_id) < 8 or length(p_report_id) > 64 then
    return jsonb_build_object('status', 'bad_request');
  end if;

  select * into d from devices where device_id = p_device_id for update;
  if not found then
    return jsonb_build_object('status', 'not_opted_in');
  end if;

  -- Idempotent retry of a report we already know.
  select * into l from bandwidth_logs where device_id = p_device_id and report_id = p_report_id;
  if found then
    if l.status = 'pending' and l.created_at < now() - interval '30 minutes' then
      update bandwidth_logs set status = 'rejected', settled_at = now() where id = l.id;
      l.status := 'rejected';
    end if;
    select coalesce(jsonb_agg(x.mb_shared order by x.id desc), '[]'::jsonb) into v_recent
      from (select id, mb_shared from bandwidth_logs
             where device_id = p_device_id and id <> l.id order by id desc limit 5) x;
    return jsonb_build_object(
      'status', 'existing', 'log_id', l.id, 'log_status', l.status, 'mb', l.mb_shared,
      'points_awarded', l.points_awarded, 'elapsed_s', coalesce(l.elapsed_s, 60),
      'max_mb', coalesce(l.max_mb, l.mb_shared), 'recent', v_recent);
  end if;

  if d.frozen then
    return jsonb_build_object('status', 'frozen');
  end if;
  if not d.opted_in then
    return jsonb_build_object('status', 'not_opted_in');
  end if;

  select max(created_at) into v_last_any from bandwidth_logs where device_id = p_device_id;
  if v_last_any is not null and extract(epoch from (now() - v_last_any)) < p_min_interval_s then
    return jsonb_build_object('status', 'too_frequent');
  end if;

  select max(created_at) into v_last_good
    from bandwidth_logs where device_id = p_device_id and status in ('pending', 'awarded');
  v_elapsed := case
    when v_last_good is null then 60
    else least(greatest(extract(epoch from (now() - v_last_good)), 1), 86400)
  end;
  v_max := least(p_max_per_report, v_elapsed * p_max_per_s);

  select coalesce(sum(mb_shared), 0) into v_day
    from bandwidth_logs
   where device_id = p_device_id
     and created_at > now() - interval '24 hours'
     and status in ('pending', 'awarded');
  if v_day + p_mb > p_max_per_day then
    return jsonb_build_object('status', 'daily_cap', 'used_mb', v_day);
  end if;

  if p_mb > v_max then
    insert into bandwidth_logs (device_id, mb_shared, report_id, status, elapsed_s, max_mb, settled_at)
    values (p_device_id, p_mb, p_report_id, 'implausible', v_elapsed, v_max, now());
    return jsonb_build_object('status', 'implausible');
  end if;

  select coalesce(jsonb_agg(x.mb_shared order by x.id desc), '[]'::jsonb) into v_recent
    from (select id, mb_shared from bandwidth_logs
           where device_id = p_device_id order by id desc limit 5) x;

  insert into bandwidth_logs (device_id, mb_shared, report_id, status, elapsed_s, max_mb)
  values (p_device_id, p_mb, p_report_id, 'pending', v_elapsed, v_max)
  returning id into v_id;

  return jsonb_build_object(
    'status', 'ok', 'log_id', v_id, 'mb', p_mb, 'elapsed_s', v_elapsed,
    'max_mb', v_max, 'recent', v_recent);
end;
$$;

-- Step 2: apply the deterministic server-rule verdict. Only a 'pending' report can be settled, once.
create or replace function settle_report(
  p_log_id bigint,
  p_valid boolean,
  p_points_per_mb numeric,
  p_vest_hours int
)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  l bandwidth_logs%rowtype;
  d devices%rowtype;
  v_points numeric;
  v_gross_revenue numeric;
  v_business_revenue numeric;
begin
  if p_points_per_mb is null or p_points_per_mb < 0 or p_points_per_mb > 10
     or p_vest_hours is null or p_vest_hours < 0 or p_vest_hours > 720 then
    raise exception 'invalid_arguments';
  end if;

  select * into l from bandwidth_logs where id = p_log_id for update;
  if not found then
    return jsonb_build_object('status', 'not_found', 'points_awarded', 0);
  end if;
  if l.status <> 'pending' then
    return jsonb_build_object('status', l.status, 'points_awarded', l.points_awarded);
  end if;

  select * into d from devices where device_id = l.device_id for update;

  if coalesce(p_valid, false) and found and not d.frozen and d.opted_in then
    -- Accounting estimate: $0.15 per decimal GB gross; 20% is allocated to the business.
    -- This is a configured estimate, not proof of revenue received from Mysterium.
    v_points := round(l.mb_shared * p_points_per_mb, 2);
    v_gross_revenue := round((l.mb_shared / 1000.0) * 0.15, 8);
    v_business_revenue := round(v_gross_revenue * 0.20, 8);
    update bandwidth_logs
       set status = 'awarded', verified_by_ai = false, verified_by_rules = true, points_awarded = v_points,
           gross_revenue_usd = v_gross_revenue,
           business_revenue_usd = v_business_revenue,
           vests_at = now() + make_interval(hours => p_vest_hours), settled_at = now()
     where id = l.id;
    update devices
       set points_balance = points_balance + v_points,
           lifetime_mb = lifetime_mb + l.mb_shared
     where device_id = l.device_id;
    return jsonb_build_object(
      'status', 'awarded',
      'points_awarded', v_points,
      'gross_revenue_usd', v_gross_revenue,
      'business_revenue_usd', v_business_revenue
    );
  end if;

  update bandwidth_logs set status = 'rejected', settled_at = now() where id = l.id;
  return jsonb_build_object('status', 'rejected', 'points_awarded', 0);
end;
$$;

-- Plain spend (kept for admin use). Respects freeze and vesting.
create or replace function spend_points(p_device_id text, p_points numeric)
returns boolean
language plpgsql
set search_path = public, pg_temp
as $$
declare
  d devices%rowtype;
begin
  if p_device_id is null or p_points is null or p_points <= 0 then
    return false;
  end if;
  select * into d from devices where device_id = p_device_id for update;
  if not found or d.frozen then
    return false;
  end if;
  if available_points(p_device_id) < p_points then
    return false;
  end if;
  update devices set points_balance = points_balance - p_points where device_id = p_device_id;
  return true;
end;
$$;

-- Spend points AND create the redemption row in one transaction, with per-user and
-- global daily limits. Nothing can be spent without a matching row.
create or replace function reserve_redemption(
  p_device_id text,
  p_points numeric,
  p_product_id text,
  p_user_limit int,
  p_global_limit int
)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  d devices%rowtype;
  v_avail numeric;
  v_count int;
  v_id bigint;
begin
  if p_device_id is null or p_points is null or p_points <= 0 then
    return jsonb_build_object('status', 'bad_request');
  end if;

  select * into d from devices where device_id = p_device_id for update;
  if not found then
    return jsonb_build_object('status', 'insufficient_points', 'available', 0);
  end if;
  if d.frozen then
    return jsonb_build_object('status', 'frozen');
  end if;

  perform pg_advisory_xact_lock(727001);

  select count(*) into v_count from redemptions
   where created_at > now() - interval '24 hours' and status <> 'failed';
  if v_count >= p_global_limit then
    return jsonb_build_object('status', 'limit_global');
  end if;

  select count(*) into v_count from redemptions
   where device_id = p_device_id and created_at > now() - interval '24 hours' and status <> 'failed';
  if v_count >= p_user_limit then
    return jsonb_build_object('status', 'limit_user');
  end if;

  v_avail := available_points(p_device_id);
  if v_avail < p_points then
    return jsonb_build_object('status', 'insufficient_points', 'available', v_avail);
  end if;

  update devices set points_balance = points_balance - p_points where device_id = p_device_id;
  insert into redemptions (device_id, points_spent, status, product_id)
  values (p_device_id, p_points, 'pending', left(p_product_id, 128))
  returning id into v_id;

  return jsonb_build_object('status', 'ok', 'id', v_id);
end;
$$;

-- Move a redemption forward (pending -> processing -> completed). Never backwards.
create or replace function update_redemption(
  p_id bigint,
  p_status text,
  p_invoice_id text default null,
  p_code text default null
)
returns boolean
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_rows int;
begin
  if p_status not in ('processing', 'completed') then
    raise exception 'invalid_status';
  end if;
  update redemptions
     set status = p_status,
         invoice_id = coalesce(p_invoice_id, invoice_id),
         code = coalesce(p_code, code),
         updated_at = now()
   where id = p_id
     and (status = 'pending' or (status = 'processing' and p_status = 'completed'));
  get diagnostics v_rows = row_count;
  return v_rows > 0;
end;
$$;

-- Fail a redemption and give the points back exactly once.
create or replace function refund_redemption(p_id bigint, p_note text default null)
returns boolean
language plpgsql
set search_path = public, pg_temp
as $$
declare
  r redemptions%rowtype;
begin
  select * into r from redemptions where id = p_id for update;
  if not found or r.status not in ('pending', 'processing') then
    return false;
  end if;
  update redemptions
     set status = 'failed', note = left(p_note, 200), updated_at = now()
   where id = r.id;
  update devices set points_balance = points_balance + r.points_spent where device_id = r.device_id;
  return true;
end;
$$;

-- Streak + last-seen, atomic and throttled (at most one write per 30 seconds).
create or replace function touch_device(p_device_id text)
returns int
language plpgsql
set search_path = public, pg_temp
as $$
declare
  d devices%rowtype;
  v_streak int;
  v_diff int;
begin
  if p_device_id is null then
    raise exception 'invalid_arguments';
  end if;
  insert into devices (device_id) values (p_device_id) on conflict (device_id) do nothing;
  select * into d from devices where device_id = p_device_id for update;

  if d.last_active_at is not null and d.last_active_at > now() - interval '30 seconds' then
    return d.streak;
  end if;

  if d.last_active_at is null then
    v_streak := 1;
  else
    v_diff := (now() at time zone 'utc')::date - (d.last_active_at at time zone 'utc')::date;
    if v_diff <= 0 then
      v_streak := greatest(d.streak, 1);
    elsif v_diff = 1 then
      v_streak := d.streak + 1;
    else
      v_streak := 1;
    end if;
  end if;

  update devices set streak = v_streak, last_active_at = now() where device_id = p_device_id;
  return v_streak;
end;
$$;

-- Abuse dashboard used by the admin endpoint.
create or replace function admin_overview()
returns jsonb
language sql
stable
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'devices', (select count(*) from devices),
    'opted_in', (select count(*) from devices where opted_in),
    'frozen', (select count(*) from devices where frozen),
    'mb_24h', (select coalesce(sum(mb_shared), 0) from bandwidth_logs
                where created_at > now() - interval '24 hours' and status = 'awarded'),
    'rejected_24h', (select count(*) from bandwidth_logs
                where created_at > now() - interval '24 hours' and status in ('rejected', 'implausible')),
    'redemptions_24h', (select count(*) from redemptions
                where created_at > now() - interval '24 hours' and status <> 'failed'),
    'processing', (select count(*) from redemptions where status in ('pending', 'processing')),
    'top_24h', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
                select device_id, round(sum(mb_shared)) as mb, count(*) as reports
                  from bandwidth_logs
                 where created_at > now() - interval '24 hours' and status = 'awarded'
                 group by device_id order by sum(mb_shared) desc limit 10) t)
  )
$$;

-- ---------------------------------------------------------------- lock the functions down
do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('add_points', 'available_points', 'begin_report', 'settle_report',
                         'spend_points', 'reserve_redemption', 'update_redemption',
                         'refund_redemption', 'touch_device', 'admin_overview')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;
end $$;

notify pgrst, 'reload schema';


-- ---------------------------------------------------------------- custom proxy schema and private Realtime authorization
-- SatsKeeper custom proxy accounting and private Realtime authorization.
create table if not exists public.proxy_logs (
  id bigserial primary key,
  device_id text not null,
  request_id text not null unique,
  bytes_used bigint not null check (bytes_used >= 0),
  created_at timestamptz not null default now()
);
-- Award points only from bytes measured by the server after a successful proxy relay.
-- request_id is unique in proxy_logs, making retries idempotent.
create or replace function settle_proxy_usage(
  p_device_id text,
  p_request_id text,
  p_bytes_used bigint,
  p_points_per_mb numeric default 0.1
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $
declare
  d devices%rowtype;
  v_log_id bigint;
  v_points numeric;
begin
  if p_device_id is null or p_request_id is null or p_request_id !~ '^[a-f0-9]{32}
  id bigserial primary key,
  device_id text not null,
  request_id text not null unique,
  bytes_used bigint not null check (bytes_used >= 0),
  created_at timestamptz not null default now()
);
create index if not exists proxy_logs_device_time_idx on public.proxy_logs (device_id, created_at desc);
alter table public.proxy_logs enable row level security;
revoke all on public.proxy_logs from public, anon, authenticated;
revoke all on sequence public.proxy_logs_id_seq from public, anon, authenticated;
grant all on public.proxy_logs to service_role;
grant usage, select on sequence public.proxy_logs_id_seq to service_role;

do $$ begin
  if to_regclass('realtime.messages') is null then
    raise notice 'realtime.messages not found; skipping Realtime policies';
    return;
  end if;
  execute 'drop policy if exists proxy_device_receive on realtime.messages';
  execute $p$ create policy proxy_device_receive on realtime.messages for select to authenticated
    using (realtime.messages.extension = 'broadcast' and (select realtime.topic()) = 'proxy_device_' || (select auth.uid())::text) $p$;
  execute 'drop policy if exists proxy_response_send on realtime.messages';
  execute $p$ create policy proxy_response_send on realtime.messages for insert to authenticated
    with check (realtime.messages.extension = 'broadcast' and (select realtime.topic()) like 'proxy\_response\_' || (select auth.uid())::text || '\_%') $p$;
  execute 'drop policy if exists proxy_gateway_all on realtime.messages';
  execute $p$ create policy proxy_gateway_all on realtime.messages for all to service_role using (true) with check (true) $p$;
end $$;
notify pgrst, 'reload schema';

     or p_bytes_used is null or p_bytes_used < 0 or p_bytes_used > 2200000
     or p_points_per_mb is null or p_points_per_mb < 0 or p_points_per_mb > 10 then
    return jsonb_build_object('status', 'bad_request', 'points_awarded', 0);
  end if;
  select * into d from devices where device_id = p_device_id for update;
  if not found or d.frozen or not d.opted_in then
    return jsonb_build_object('status', 'not_eligible', 'points_awarded', 0);
  end if;
  insert into proxy_logs(device_id, request_id, bytes_used)
  values (p_device_id, p_request_id, p_bytes_used)
  on conflict (request_id) do nothing
  returning id into v_log_id;
  if v_log_id is null then
    return jsonb_build_object('status', 'duplicate', 'points_awarded', 0);
  end if;
  v_points := round((p_bytes_used::numeric / 1000000) * p_points_per_mb, 2);
  if v_points > 0 then
    update devices set points_balance = points_balance + v_points,
      lifetime_mb = lifetime_mb + (p_bytes_used::numeric / 1000000)
      where device_id = p_device_id;
  end if;
  return jsonb_build_object('status', 'awarded', 'points_awarded', v_points,
    'bytes_used', p_bytes_used, 'request_id', p_request_id);
end;
$;
revoke all on function settle_proxy_usage(text, text, bigint, numeric) from public, anon, authenticated;
grant execute on function settle_proxy_usage(text, text, bigint, numeric) to service_role;

create index if not exists proxy_logs_device_time_idx on public.proxy_logs (device_id, created_at desc);
alter table public.proxy_logs enable row level security;
revoke all on public.proxy_logs from public, anon, authenticated;
revoke all on sequence public.proxy_logs_id_seq from public, anon, authenticated;
grant all on public.proxy_logs to service_role;
grant usage, select on sequence public.proxy_logs_id_seq to service_role;

do $$ begin
  if to_regclass('realtime.messages') is null then
    raise notice 'realtime.messages not found; skipping Realtime policies';
    return;
  end if;
  execute 'drop policy if exists proxy_device_receive on realtime.messages';
  execute $p$ create policy proxy_device_receive on realtime.messages for select to authenticated
    using (realtime.messages.extension = 'broadcast' and (select realtime.topic()) = 'proxy_device_' || (select auth.uid())::text) $p$;
  execute 'drop policy if exists proxy_response_send on realtime.messages';
  execute $p$ create policy proxy_response_send on realtime.messages for insert to authenticated
    with check (realtime.messages.extension = 'broadcast' and (select realtime.topic()) like 'proxy\_response\_' || (select auth.uid())::text || '\_%') $p$;
  execute 'drop policy if exists proxy_gateway_all on realtime.messages';
  execute $p$ create policy proxy_gateway_all on realtime.messages for all to service_role using (true) with check (true) $p$;
end $$;
notify pgrst, 'reload schema';
