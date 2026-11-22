-- Host V2 History read model and minimal live dashboard metrics.
begin;

create or replace function public.bw_admin_dashboard()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_round public.bw_rounds%rowtype;
begin
  if auth.uid() is null or not exists(
    select 1 from private.bw_admins where user_id=auth.uid()
  ) then raise exception 'Host access required'; end if;

  select * into v_round
  from public.bw_rounds
  where status in ('open','revealing')
  order by id desc
  limit 1;

  return jsonb_build_object(
    'game_status',case when v_round.id is null then 'starting' else v_round.status end,
    'current_round',case when v_round.id is null then null else jsonb_build_object(
      'id',v_round.id,'status',v_round.status,'starts_at',v_round.starts_at,
      'closes_at',v_round.closes_at,'reveal_ends_at',v_round.reveal_ends_at,
      'total_pot',v_round.total_pot
    ) end,
    'active_players',case when v_round.id is null then 0 else (
      select count(distinct user_id) from public.bw_bets
      where round_id=v_round.id and status='placed'
    ) end,
    'total_betting_activity',coalesce(v_round.total_pot,0),
    'pending_requests',(select count(*) from public.bw_balance_requests where status='pending'),
    'player_count',(select count(*) from public.bw_profiles),
    'round_count',(select count(*) from public.bw_rounds where status='settled'),
    'house_balance',(select balance from private.bw_house_accounts where id=1),
    'players',coalesce((
      select jsonb_agg(jsonb_build_object(
        'user_id',p.user_id,'username',p.username,
        'balance',w.balance,'reserved_balance',w.reserved_balance,
        'available_balance',w.balance-w.reserved_balance,'created_at',p.created_at
      ) order by p.created_at desc)
      from public.bw_profiles p join public.bw_wallets w using(user_id)
    ),'[]'::jsonb),
    'recent_rounds',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',id,'winner_color',winner_color,'total_pot',total_pot,
        'house_amount',house_amount,'dead_round',dead_round,'settled_at',settled_at
      ) order by id desc)
      from (select * from public.bw_rounds where status='settled' order by id desc limit 20) r
    ),'[]'::jsonb)
  );
end;
$function$;

create or replace function public.bw_admin_history(p_limit integer default 50)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_rounds jsonb;
  v_bets jsonb;
  v_ledger jsonb;
  v_requests jsonb;
begin
  if auth.uid() is null or not exists(
    select 1 from private.bw_admins where user_id=auth.uid()
  ) then raise exception 'Host access required'; end if;
  if p_limit is null or p_limit<1 or p_limit>100 then
    raise exception 'History page size must be between 1 and 100';
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.id desc),'[]'::jsonb)
  into v_rounds
  from (
    select id,status,starts_at,closes_at,reveal_ends_at,settled_at,
      winner_color,total_pot,winning_stake,payout_pool,house_amount,dead_round,
      server_seed_hash,server_seed_reveal
    from public.bw_rounds
    order by id desc limit p_limit
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.id desc),'[]'::jsonb)
  into v_bets
  from (
    select b.id,b.round_id,b.username_snapshot as username,b.slot_index,
      b.color,b.stake,b.payout,b.status,b.created_at,r.winner_color,r.settled_at
    from public.bw_bets b
    join public.bw_rounds r on r.id=b.round_id
    order by b.id desc limit p_limit
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.id desc),'[]'::jsonb)
  into v_ledger
  from (
    select l.id,p.username,l.entry_type,l.amount,l.balance_after,l.reference,l.created_at
    from public.bw_ledger l
    left join public.bw_profiles p on p.user_id=l.user_id
    order by l.id desc limit p_limit
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.id desc),'[]'::jsonb)
  into v_requests
  from (
    select id,username_snapshot as username,request_type,amount,note,status,
      created_at,processed_at,processing_note
    from public.bw_balance_requests
    order by id desc limit p_limit
  ) x;

  return jsonb_build_object(
    'rounds',v_rounds,
    'bets',v_bets,
    'balance_ledger',v_ledger,
    'requests',v_requests
  );
end;
$function$;

revoke all on function public.bw_admin_history(integer) from public,anon;
grant execute on function public.bw_admin_history(integer) to authenticated;
grant execute on function public.bw_admin_dashboard() to authenticated;

commit;
