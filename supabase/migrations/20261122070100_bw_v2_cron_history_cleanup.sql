-- Keep the high-frequency V2 round scheduler's run history bounded.
-- Retain the most recent 48 hours for troubleshooting.
select cron.schedule(
  'bw-round-cron-history-cleanup',
  '0 3 * * *',
  $$delete from cron.job_run_details where start_time < now() - interval '48 hours'$$
);