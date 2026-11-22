-- Transaction-only tests for bet cancellation, slot reuse, cutoff enforcement,
-- personal history, and cancellation-aware settlement. Everything is rolled back.

begin;
select pg_advisory_xact_lock(7812345601);

do $$
declare
  v_user uuid;
  v_round_id bigint;
  v_bet jsonb;
  v_cancel jsonb;
  v_cancelled_id bigint;
  v_second_id bigint;
  v_round public.bw_rounds%rowtype;
  v_before_balance bigint;
  v_after_balance bigint;
  v_before_house bigint;
  v_after_house bigint;
  v_payout_total bigint;
  v_history jsonb;
  v_closed_rejected boolean := false;
begin
  select p.user_id into v_user
  from public.bw_profiles p
  join public.bw_wallets w on w.user_id=p.user_id
  where w.balance >= 12
    and not exists (
      select 1 from public.bw_rounds r
      join public.bw_bets b on b.round_id=r.id
      where r.status='open' and b.user_id=p.user_id and b.status='placed'
    )
  order by w.balance desc
  limit 1;

  if v_user is null then raise exception 'A test player with at least 12 Balance is required'; end if;
  perform set_config('request.jwt.claim.sub',v_user::text,true);

  -- If the scheduler is between phases, finish that reveal inside this rollback-only
  -- transaction so the test can safely use the next open round.
  perform private.bw_advance_round();
  select id into v_round_id from public.bw_rounds where status='open';
  if v_round_id is null then
    update public.bw_rounds
    set reveal_ends_at=clock_timestamp()-interval '1 second'
    where status='revealing';
    perform private.bw_advance_round();
    select id into v_round_id from public.bw_rounds where status='open';
  end if;
  if v_round_id is null then raise exception 'Unable to prepare an open test round'; end if;

  select balance into v_before_balance from public.bw_wallets where user_id=v_user;
  select balance into v_before_house from private.bw_house_accounts where id=1;

  update public.bw_rounds
  set closes_at=clock_timestamp()+interval '1 hour',
      reveal_ends_at=clock_timestamp()+interval '1 hour 3 seconds'
  where id=v_round_id and status='open';

  v_bet:=public.bw_place_bet(1::smallint,'green',5::bigint);
  v_cancelled_id:=(v_bet->'bet'->>'id')::bigint;
  v_cancel:=public.bw_cancel_bet(v_cancelled_id);

  if v_cancel->>'status'<>'cancelled'
     or (v_cancel->>'stake_returned')::bigint<>5 then
    raise exception 'Cancellation did not return the full stake';
  end if;
  if (select status from public.bw_bets where id=v_cancelled_id)<>'cancelled' then
    raise exception 'Cancelled bet audit row missing';
  end if;

  -- A cancelled slot can be used again without deleting the old audit row.
  v_bet:=public.bw_place_bet(1::smallint,'orange',7::bigint);
  v_bet:=public.bw_place_bet(2::smallint,'blue',5::bigint);
  v_second_id:=(v_bet->'bet'->>'id')::bigint;

  update public.bw_rounds
  set starts_at=clock_timestamp()-interval '6 seconds',
      closes_at=clock_timestamp()-interval '5 seconds',
      reveal_ends_at=clock_timestamp()-interval '1 second'
  where id=v_round_id and status='open';

  begin
    perform public.bw_cancel_bet(v_second_id);
    raise exception 'Cancellation unexpectedly succeeded after cutoff';
  exception
    when others then
      if position('cancellation is unavailable' in lower(sqlerrm))=0 then raise; end if;
      v_closed_rejected:=true;
  end;
  if not v_closed_rejected then raise exception 'Post-cutoff cancellation was not rejected'; end if;

  perform private.bw_advance_round();
  select * into v_round from public.bw_rounds where id=v_round_id;
  if v_round.status<>'revealing' or v_round.server_seed_reveal is not null then
    raise exception 'Reveal phase did not preserve seed secrecy';
  end if;

  update public.bw_rounds set reveal_ends_at=clock_timestamp()-interval '1 second'
  where id=v_round_id and status='revealing';
  perform private.bw_advance_round();

  select * into v_round from public.bw_rounds where id=v_round_id;
  if v_round.status<>'settled' then raise exception 'Round did not settle'; end if;
  if v_round.total_pot<>12 then raise exception 'Cancelled stake was included in the pot'; end if;
  if (select status from public.bw_bets where id=v_cancelled_id)<>'cancelled' then
    raise exception 'Settlement overwrote the cancelled bet status';
  end if;

  select coalesce(sum(payout),0) into v_payout_total
  from public.bw_bets where round_id=v_round_id and status='won';
  if v_payout_total<>v_round.payout_pool then raise exception 'Winner payouts do not reconcile'; end if;
  if v_round.payout_pool+v_round.house_amount<>12 then raise exception 'House/pool allocation does not reconcile'; end if;

  select balance into v_after_balance from public.bw_wallets where user_id=v_user;
  if v_after_balance<>v_before_balance-12+v_payout_total then
    raise exception 'Player Balance does not reconcile';
  end if;

  select balance into v_after_house from private.bw_house_accounts where id=1;
  if v_after_house<>v_before_house+v_round.house_amount then
    raise exception 'House Balance does not reconcile';
  end if;

  v_history:=public.bw_get_my_history(100,null);
  if not exists (
    select 1 from jsonb_array_elements(v_history->'items') e
    where (e->>'bet_id')::bigint=v_cancelled_id and e->>'status'='cancelled'
  ) then raise exception 'Personal history omitted the cancelled bet'; end if;
end $$;

rollback;
