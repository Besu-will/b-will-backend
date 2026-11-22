-- B-Will V2: safe pre-cutoff bet cancellation and player bet history.
-- Cancelled wagers remain auditable and are excluded from settlement.

begin;

alter table public.bw_bets drop constraint if exists bw_bets_status_check;
alter table public.bw_bets
  add constraint bw_bets_status_check
  check (status = any (array['placed'::text, 'won'::text, 'lost'::text, 'cancelled'::text]));

alter table public.bw_bets drop constraint if exists bw_bets_round_id_user_id_slot_index_key;
create unique index if not exists bw_bets_one_active_slot
  on public.bw_bets(round_id, user_id, slot_index)
  where status = 'placed';

alter table public.bw_ledger drop constraint if exists bw_ledger_entry_type_check;
alter table public.bw_ledger
  add constraint bw_ledger_entry_type_check
  check (entry_type = any (array[
    'starting_grant'::text,
    'bet'::text,
    'bet_cancel'::text,
    'win'::text,
    'admin_adjustment'::text
  ]));

create or replace function public.bw_place_bet(p_slot smallint, p_color text, p_stake bigint)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_state jsonb;
  v_round_id bigint;
  v_balance bigint;
  v_min bigint;
  v_max bigint;
  v_closes timestamptz;
  v_name text;
  v_bet public.bw_bets%rowtype;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if p_slot not in (1,2) then raise exception 'Invalid betting slot'; end if;
  if p_color not in ('green','orange','blue') then raise exception 'Invalid colour'; end if;

  select min_stake,max_stake into v_min,v_max from private.bw_settings where id=1;
  if p_stake < v_min or p_stake > v_max then raise exception 'Stake is outside the allowed range'; end if;

  v_state := public.bw_tick();
  v_round_id := (v_state->'round'->>'id')::bigint;
  perform pg_advisory_xact_lock(7812345601);

  select closes_at into v_closes
  from public.bw_rounds
  where id=v_round_id and status='open'
  for update;
  if not found or v_closes <= clock_timestamp() then
    raise exception 'Betting is closed for this round';
  end if;

  select balance into v_balance
  from public.bw_wallets where user_id=v_uid for update;
  if v_balance < p_stake then raise exception 'Insufficient balance'; end if;

  if exists(
    select 1 from public.bw_bets
    where round_id=v_round_id and user_id=v_uid
      and slot_index=p_slot and status='placed'
  ) then
    raise exception 'This betting slot is already in use';
  end if;

  select username into v_name from public.bw_profiles where user_id=v_uid;

  update public.bw_wallets
  set balance=balance-p_stake,updated_at=now()
  where user_id=v_uid returning balance into v_balance;

  insert into public.bw_ledger(user_id,entry_type,amount,balance_after,reference)
  values(v_uid,'bet',-p_stake,v_balance,'round:'||v_round_id::text||':slot:'||p_slot::text);

  insert into public.bw_bets(round_id,user_id,username_snapshot,slot_index,color,stake)
  values(v_round_id,v_uid,coalesce(v_name,'Player'),p_slot,p_color,p_stake)
  returning * into v_bet;

  update public.bw_rounds set total_pot=total_pot+p_stake where id=v_round_id;

  return jsonb_build_object(
    'bet',jsonb_build_object(
      'id',v_bet.id,'round_id',v_bet.round_id,'slot_index',v_bet.slot_index,
      'color',v_bet.color,'stake',v_bet.stake,'status',v_bet.status
    ),
    'balance',v_balance
  );
end;
$function$;

create or replace function public.bw_cancel_bet(p_bet_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_bet public.bw_bets%rowtype;
  v_round public.bw_rounds%rowtype;
  v_balance bigint;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if p_bet_id is null or p_bet_id <= 0 then raise exception 'Invalid bet'; end if;

  perform pg_advisory_xact_lock(7812345601);

  select * into v_bet
  from public.bw_bets
  where id=p_bet_id and user_id=v_uid
  for update;

  if not found or v_bet.status <> 'placed' then
    raise exception 'This bet can no longer be cancelled';
  end if;

  select * into v_round
  from public.bw_rounds
  where id=v_bet.round_id
  for update;

  if not found or v_round.status <> 'open'
     or v_round.closes_at <= clock_timestamp() then
    raise exception 'Betting is closed; cancellation is unavailable';
  end if;

  select balance into v_balance
  from public.bw_wallets
  where user_id=v_uid
  for update;

  update public.bw_wallets
  set balance=balance+v_bet.stake,updated_at=now()
  where user_id=v_uid
  returning balance into v_balance;

  update public.bw_rounds
  set total_pot=total_pot-v_bet.stake
  where id=v_bet.round_id and total_pot >= v_bet.stake;

  if not found then raise exception 'Round pot reconciliation failed'; end if;

  update public.bw_bets
  set status='cancelled',payout=0
  where id=v_bet.id and status='placed';

  insert into public.bw_ledger(user_id,entry_type,amount,balance_after,reference)
  values(v_uid,'bet_cancel',v_bet.stake,v_balance,'bet:'||v_bet.id::text||':cancel');

  return jsonb_build_object(
    'bet_id',v_bet.id,
    'round_id',v_bet.round_id,
    'slot_index',v_bet.slot_index,
    'stake_returned',v_bet.stake,
    'balance',v_balance,
    'status','cancelled'
  );
end;
$function$;

create or replace function public.bw_get_my_history(
  p_limit integer default 50,
  p_before_id bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_items jsonb;
  v_next bigint;
  v_count integer;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'History page size must be between 1 and 100';
  end if;

  with page as (
    select
      b.id,b.round_id,b.slot_index,b.color,b.stake,b.payout,b.status,b.created_at,
      r.status as round_status,r.winner_color,r.dead_round,r.total_pot,r.settled_at
    from public.bw_bets b
    join public.bw_rounds r on r.id=b.round_id
    where b.user_id=v_uid
      and (p_before_id is null or b.id < p_before_id)
    order by b.id desc
    limit p_limit
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'bet_id',id,'round_id',round_id,'slot_index',slot_index,'color',color,
      'stake',stake,'payout',payout,'status',status,'created_at',created_at,
      'round_status',round_status,'winner_color',winner_color,
      'dead_round',dead_round,'total_pot',total_pot,'settled_at',settled_at
    ) order by id desc),'[]'::jsonb),
    min(id),
    count(*)::integer
  into v_items,v_next,v_count
  from page;

  return jsonb_build_object(
    'items',v_items,
    'next_before_id',case when v_count=p_limit then v_next else null end
  );
end;
$function$;

create or replace function public.bw_get_state()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_state jsonb;
  v_wallet bigint;
  v_profile text;
  v_round_id bigint;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;

  v_state := public.bw_tick();
  v_round_id := (v_state->'round'->>'id')::bigint;

  select balance into v_wallet from public.bw_wallets where user_id=v_uid;
  select username into v_profile from public.bw_profiles where user_id=v_uid;

  return v_state || jsonb_build_object(
    'wallet',v_wallet,
    'username',v_profile,
    'my_bets',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',id,'slot_index',slot_index,'color',color,'stake',stake,'status',status,'payout',payout
      ) order by slot_index)
      from public.bw_bets
      where round_id=v_round_id and user_id=v_uid and status='placed'
    ),'[]'::jsonb),
    'recent_rounds',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',id,'winner_color',winner_color,'total_pot',total_pot,'dead_round',dead_round,
        'server_seed_hash',server_seed_hash,'server_seed_reveal',server_seed_reveal,'client_seed',client_seed
      ) order by id desc)
      from (select * from public.bw_rounds where status='settled' order by id desc limit 10) h
    ),'[]'::jsonb)
  );
end;
$function$;

create or replace function private.bw_settle_round(p_round_id bigint)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_round public.bw_rounds%rowtype;
  v_seed text;
  v_total bigint;
  v_winning bigint;
  v_pool bigint;
  v_house bigint;
  v_color text;
begin
  select * into v_round from public.bw_rounds
  where id = p_round_id and status = 'revealing'
  for update;
  if not found or v_round.reveal_ends_at > clock_timestamp() then return; end if;

  select server_seed into v_seed from private.bw_round_secrets where round_id = p_round_id;
  if v_seed is null then raise exception 'Round secret missing'; end if;
  v_color := v_round.winner_color;

  select coalesce(sum(stake),0) into v_total
  from public.bw_bets where round_id = p_round_id and status = 'placed';
  select coalesce(sum(stake),0) into v_winning
  from public.bw_bets where round_id = p_round_id and status = 'placed' and color = v_color;

  if v_winning = 0 then
    v_pool := 0;
    v_house := v_total;
    update public.bw_bets set status = 'lost', payout = 0
    where round_id = p_round_id and status = 'placed';
  else
    select floor(v_total::numeric * (100 - s.house_percent) / 100)::bigint
    into v_pool from private.bw_settings s where s.id = 1;
    v_house := v_total - v_pool;

    with winners as (
      select b.id,b.stake,
             floor(v_pool::numeric * b.stake / v_winning)::bigint as base_payout,
             row_number() over(order by b.id) as rn
      from public.bw_bets b
      where b.round_id = p_round_id and b.status = 'placed' and b.color = v_color
    ),
    totals as (select coalesce(sum(base_payout),0) as base_total from winners),
    allocations as (
      select w.id,
             w.base_payout + case when w.rn <= (v_pool - t.base_total) then 1 else 0 end as final_payout
      from winners w cross join totals t
    )
    update public.bw_bets b
    set status = case when b.color = v_color then 'won' else 'lost' end,
        payout = case when b.color = v_color then a.final_payout else 0 end
    from (select id,final_payout from allocations) a
    where b.id = a.id;

    update public.bw_bets
    set status = 'lost',payout = 0
    where round_id = p_round_id and status = 'placed' and color <> v_color;

    with user_wins as (
      select user_id,sum(payout)::bigint as amount
      from public.bw_bets
      where round_id = p_round_id and status = 'won' and payout > 0
      group by user_id
    ),
    credited as (
      update public.bw_wallets w
      set balance = w.balance + u.amount,updated_at = now()
      from user_wins u where w.user_id = u.user_id
      returning w.user_id,w.balance,
        (select amount from user_wins x where x.user_id = w.user_id) as amount
    )
    insert into public.bw_ledger(user_id,entry_type,amount,balance_after,reference)
    select user_id,'win',amount,balance,'round:' || p_round_id::text from credited;
  end if;

  if v_house > 0 then
    update private.bw_house_accounts
    set balance = balance + v_house,updated_at = now()
    where id = 1;

    insert into private.bw_house_ledger(round_id,entry_type,amount)
    values (p_round_id,case when v_winning = 0 then 'dead_round' else 'round_fee' end,v_house);
  end if;

  update public.bw_rounds
  set status = 'settled',settled_at = now(),server_seed_reveal = v_seed,
      total_pot = v_total,winning_stake = v_winning,payout_pool = v_pool,
      house_amount = v_house,dead_round = (v_winning = 0)
  where id = p_round_id and status = 'revealing';
end;
$function$;

create or replace view public.bw_live_bets
with (security_invoker=true, security_barrier=true)
as
select id,round_id,username_snapshot as username,slot_index,color,stake,status,created_at,payout
from public.bw_bets
where status='placed';

revoke all on function public.bw_cancel_bet(bigint) from public,anon;
revoke all on function public.bw_get_my_history(integer,bigint) from public,anon;
grant execute on function public.bw_cancel_bet(bigint) to authenticated;
grant execute on function public.bw_get_my_history(integer,bigint) to authenticated;
grant execute on function public.bw_place_bet(smallint,text,bigint) to authenticated;
grant execute on function public.bw_get_state() to authenticated;
revoke all on function private.bw_settle_round(bigint) from public,anon,authenticated;

commit;
