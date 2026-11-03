-- SatsKeeper custom proxy accounting and private Realtime authorization.
create table if not exists public.proxy_logs (
  id bigserial primary key,
  device_id text not null,
  request_id text not null unique,
  bytes_used bigint not null check (bytes_used >= 0),
  credited boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists proxy_logs_device_time_idx on public.proxy_logs (device_id, created_at desc);
alter table public.proxy_logs add column if not exists credited boolean not null default false;

-- Atomic, idempotent crediting: lock the measured log, mark it credited, and add points
-- in the same transaction. Client-reported byte counts are never accepted.
create or replace function public.credit_proxy_log(
  p_device_id text,
  p_request_id text,
  p_points_per_mb numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $
declare
  l public.proxy_logs%rowtype;
  v_points numeric;
begin
  if p_device_id is null or p_request_id is null or p_points_per_mb is null
     or p_points_per_mb < 0 or p_points_per_mb > 10 then
    raise exception 'invalid_arguments';
  end if;

  select * into l
    from public.proxy_logs
   where request_id = p_request_id
   for update;

  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if l.device_id <> p_device_id then
    return jsonb_build_object('status', 'wrong_device');
  end if;
  if l.credited then
    return jsonb_build_object('status', 'already_credited', 'bytes_used', l.bytes_used, 'points_awarded', 0);
  end if;

  v_points := round((l.bytes_used::numeric / 1000000) * p_points_per_mb, 2);
  update public.proxy_logs set credited = true where id = l.id;
  if v_points > 0 then
    perform public.add_points(p_device_id, v_points);
  end if;

  return jsonb_build_object('status', 'credited', 'bytes_used', l.bytes_used, 'points_awarded', v_points);
end;
$;

revoke all on function public.credit_proxy_log(text, text, numeric) from public, anon, authenticated;
grant execute on function public.credit_proxy_log(text, text, numeric) to service_role;
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
