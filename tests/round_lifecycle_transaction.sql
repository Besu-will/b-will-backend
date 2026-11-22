-- Transaction-only checks for the V2 7s betting / 3s reveal lifecycle.
-- Requires at least one existing authenticated player account.
-- All inserted test rows, bets, and balance changes are rolled back.

begin;
select pg_advisory_xact_lock(7812345601);

do $$
declare
  v_user uuid;
  v_round_id bigint;
  v_seed text;
  v_round public.bw_rounds%rowtype;
  v_before_balance bigint;
  v_after_balance bigint;
  v_before_house bigint;
  v_after_house bigint;
  v_payout_total bigint;
  v_closed_rejected boolean := false;
begin
  select id into v_user from auth.users order by created_at limit 1;
  if v_user is null then raise exception 'At least one test account is required'; end if;

  perform set_config('request.jwt.claim.sub', v_user::text, true);
  select balance into v_before_balance from public.bw_wallets where user_id = v_user;
  select balance into v_before_house from private.bw_house_accounts where id = 1;

  v_seed := encode(extensions.gen_random_bytes(32), 'hex');

  insert into public.bw_rounds(
    status, starts_at, closes_at, reveal_ends_at, server_seed_hash, client_seed
  )
  values (
    'open',
    clock_timestamp(),
    clock_timestamp() + interval '1 hour',
    clock_timestamp() + interval '1 hour 3 seconds',
    encode(extensions.digest(decode(v_seed, 'hex'), 'sha256'), 'hex'),
    gen_random_uuid()::text
  )
  returning id into v_round_id;

  insert into private.bw_round_secrets(round_id, server_seed)
  values (v_round_id, v_seed);

  -- A bet is accepted while the round is open.
  perform public.bw_place_bet(1::smallint, 'green', 5::bigint);

  -- Move the cutoff into the past while preserving valid round timestamps.
  update public.bw_rounds
  set starts_at = clock_timestamp() - interval '6 seconds',
      closes_at = clock_timestamp() - interval '5 seconds',
      reveal_ends_at = clock_timestamp() - interval '1 second'
  where id = v_round_id and status = 'open';

  -- A second bet must be rejected once the betting cutoff has passed.
  begin
    perform public.bw_place_bet(2::smallint, 'blue', 5::bigint);
    raise exception 'Bet unexpectedly accepted after betting cutoff';
  exception
    when others then
      if position('Betting is closed' in sqlerrm) = 0 then raise; end if;
      v_closed_rejected := true;
  end;

  if not v_closed_rejected then raise exception 'Closed betting cutoff was not enforced'; end if;

  perform private.bw_advance_round();
  select * into v_round from public.bw_rounds where id = v_round_id;

  if v_round.status <> 'revealing'
     or v_round.winner_color is null
     or v_round.server_seed_reveal is not null then
    raise exception 'Reveal phase transition or seed secrecy failed';
  end if;

  -- Simulate the reveal timer expiring; then settle through the server engine.
  update public.bw_rounds
  set reveal_ends_at = clock_timestamp() - interval '1 second'
  where id = v_round_id and status = 'revealing';

  perform private.bw_advance_round();
  select * into v_round from public.bw_rounds where id = v_round_id;

  if v_round.status <> 'settled'
     or v_round.server_seed_reveal is null
     or v_round.settled_at is null then
    raise exception 'Settlement transition failed';
  end if;

  if encode(extensions.digest(decode(v_round.server_seed_reveal, 'hex'), 'sha256'), 'hex')
     <> v_round.server_seed_hash then
    raise exception 'Seed commitment verification failed';
  end if;

  select coalesce(sum(payout), 0) into v_payout_total
  from public.bw_bets where round_id = v_round_id;

  if v_payout_total <> v_round.payout_pool then
    raise exception 'Player payouts do not reconcile to payout pool';
  end if;

  if v_round.payout_pool + v_round.house_amount <> v_round.total_pot then
    raise exception 'House and player allocations do not reconcile to total pot';
  end if;

  select balance into v_after_balance from public.bw_wallets where user_id = v_user;
  if v_after_balance <> v_before_balance - 5 + v_payout_total then
    raise exception 'Player Balance does not reconcile';
  end if;

  select balance into v_after_house from private.bw_house_accounts where id = 1;
  if v_after_house <> v_before_house + v_round.house_amount then
    raise exception 'House Balance does not reconcile';
  end if;
end $$;

rollback;
