-- Supporting indexes for stream history, donation ledgers and report moderation.
create index if not exists stream_sessions_creator_idx
  on public.stream_sessions(creator_id, created_at desc);
create index if not exists stream_donations_stream_idx
  on public.stream_donations(stream_id, created_at desc);
create index if not exists stream_donations_donor_idx
  on public.stream_donations(donor_id, created_at desc);
create index if not exists stream_donations_creator_idx
  on public.stream_donations(creator_id, created_at desc);
create index if not exists stream_reports_reporter_idx
  on public.stream_reports(reporter_id, created_at desc);
