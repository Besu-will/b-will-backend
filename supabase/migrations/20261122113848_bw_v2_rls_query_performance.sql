-- Tighten V2 read-policy evaluation and index request review references.
begin;

drop policy if exists bw_balance_requests_owner_read on public.bw_balance_requests;
drop policy if exists bw_balance_requests_host_read on public.bw_balance_requests;
create policy bw_balance_requests_read
  on public.bw_balance_requests for select to authenticated
  using (
    user_id = (select auth.uid())
    or (select public.bw_is_admin())
  );

drop policy if exists bw_profiles_self_read on public.bw_profiles;
create policy bw_profiles_self_read
  on public.bw_profiles for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists bw_wallets_self_read on public.bw_wallets;
create policy bw_wallets_self_read
  on public.bw_wallets for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists bw_ledger_self_read on public.bw_ledger;
create policy bw_ledger_self_read
  on public.bw_ledger for select to authenticated
  using (user_id = (select auth.uid()));

create index if not exists bw_balance_requests_processed_by_idx
  on public.bw_balance_requests(processed_by)
  where processed_by is not null;

commit;
