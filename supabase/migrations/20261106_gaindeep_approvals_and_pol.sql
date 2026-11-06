-- GainDeep account approval and POL payout metadata migration.
-- Additive migration: does not modify existing balances, reports, or redemptions.
-- Run manually in the Supabase SQL Editor. This does NOT alter the live project.

-- Manual account approval records. Store only a SHA-256 hash of each one-time code,
-- never the plaintext code. The backend must hash submitted codes before lookup.
create table if not exists public.account_approvals (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  status text not null default 'pending',
  approval_code_hash text,
  code_expires_at timestamptz,
  requested_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by text,
  approved_at timestamptz,
  constraint account_approvals_status_ok
    check (status in ('pending', 'approved', 'rejected')),
  constraint account_approvals_code_hash_format
    check (approval_code_hash is null or approval_code_hash ~ '^[0-9a-f]{64}$')
);

create index if not exists account_approvals_status_requested_idx
  on public.account_approvals (status, requested_at desc);

alter table public.account_approvals enable row level security;
revoke all on table public.account_approvals from public, anon, authenticated;
grant all on table public.account_approvals to service_role;

-- Preserve existing gift-card columns; add separate metadata for POL payouts.
alter table public.redemptions
  add column if not exists payout_method text not null default 'gift_card',
  add column if not exists wallet_address text,
  add column if not exists pol_amount numeric(30, 18),
  add column if not exists pol_usd_price numeric(30, 12),
  add column if not exists quote_timestamp timestamptz;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'redemptions_payout_method_ok'
       and conrelid = 'public.redemptions'::regclass
  ) then
    alter table public.redemptions
      add constraint redemptions_payout_method_ok
      check (payout_method in ('gift_card', 'pol'));
  end if;

  if not exists (
    select 1 from pg_constraint
     where conname = 'redemptions_pol_fields_ok'
       and conrelid = 'public.redemptions'::regclass
  ) then
    alter table public.redemptions
      add constraint redemptions_pol_fields_ok
      check (
        (payout_method = 'gift_card'
          and wallet_address is null
          and pol_amount is null
          and pol_usd_price is null
          and quote_timestamp is null)
        or
        (payout_method = 'pol'
          and wallet_address ~* '^0x[0-9a-f]{40}$'
          and pol_amount > 0
          and pol_usd_price > 0
          and quote_timestamp is not null)
      );
  end if;
end $$;

create index if not exists redemptions_payout_method_idx
  on public.redemptions (payout_method, status, created_at desc);

-- No private keys or recovery phrases belong in this database.
