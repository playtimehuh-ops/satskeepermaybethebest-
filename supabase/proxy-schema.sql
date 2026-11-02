-- SatsKeeper custom proxy accounting and private Realtime authorization.
create table if not exists public.proxy_logs (
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
