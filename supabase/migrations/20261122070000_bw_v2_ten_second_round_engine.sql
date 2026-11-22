-- B-Will V2: server-authoritative 7s betting + 3s reveal lifecycle.
-- This migration only touches bw_* V2 objects. Legacy V1 objects remain unchanged.

begin;

alter table private.bw_settings
  drop constraint if exists bw_settings_round_duration_seconds_check;

alter table private.bw_settings
  add constraint bw_settings_round_duration_seconds_check
  check (round_duration_seconds = 10);

alter table public.bw_rounds
  add column if not exists reveal_ends_at timestamptz;

-- Preserve historical records; give the existing live round a fresh V2 cycle.
update public.bw_rounds
set reveal_ends_at = case
  when status = 'open' then clock_timestamp() + interval '10 seconds'
  else coalesce(settled_at, closes_at) + interval '3 seconds'
end
where reveal_ends_at is null;

alter table public.bw_rounds
  alter column reveal_ends_at set not null;

alter table public.bw_rounds
  drop constraint if exists bw_rounds_status_check;

alter table public.bw_rounds
  add constraint bw_rounds_status_check
  check (status = any (array['open'::text, 'revealing'::text, 'settled'::text]));

alter table public.bw_rounds
  drop constraint if exists bw_rounds_settlement_check;

alter table public.bw_rounds
  add constraint bw_rounds_settlement_check
  check (
    (status = 'open' and settled_at is null and winner_color is null and server_seed_reveal is null)
    or
    (status = 'revealing' and settled_at is null and winner_color is not null and server_seed_reveal is null)
    or
    (status = 'settled' and settled_at is not null and winner_color is not null and server_seed_reveal is not null)
  );

alter table public.bw_rounds
  add constraint bw_rounds_reveal_time_check
  check (reveal_ends_at > closes_at);

update private.bw_settings
set round_duration_seconds = 10
where id = 1;

update public.bw_rounds
set starts_at = clock_timestamp(),
    closes_at = clock_timestamp() + interval '7 seconds',
    reveal_ends_at = clock_timestamp() + interval '10 seconds'
where status = 'open';

create or replace function private.bw_begin_reveal(p_round_id bigint)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_round public.bw_rounds%rowtype;
  v_seed text;
  v_digest bytea;
  v_n bigint;
  v_counter integer := 0;
  v_color text;
begin
  select * into v_round
  from public.bw_rounds
  where id = p_round_id and status = 'open'
  for update;

  if not found then return; end if;
  if v_round.closes_at > clock_timestamp() then return; end if;

  select server_seed into v_seed
  from private.bw_round_secrets
  where round_id = p_round_id;

  if v_seed is null then
    raise exception 'Round secret missing';
  end if;

  loop
    v_digest := extensions.hmac(
      convert_to(v_round.id::text || ':' || v_round.client_seed || ':' || v_counter::text, 'UTF8'),
      decode(v_seed, 'hex'),
      'sha256'
    );
    v_n := get_byte(v_digest,0)::bigint * 16777216
         + get_byte(v_digest,1)::bigint * 65536
         + get_byte(v_digest,2)::bigint * 256
         + get_byte(v_digest,3)::bigint;
    exit when v_n < 4294967295;
    v_counter := v_counter + 1;
  end loop;

  v_color := case (v_n % 3)::integer
    when 0 then 'green'
    when 1 then 'orange'
    else 'blue'
  end;

  update public.bw_rounds
  set status = 'revealing',
      winner_color = v_color,
      reveal_ends_at = greatest(reveal_ends_at, clock_timestamp() + interval '3 seconds')
  where id = p_round_id and status = 'open';
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
  select * into v_round
  from public.bw_rounds
  where id = p_round_id and status = 'revealing'
  for update;

  if not found then return; end if;
  if v_round.reveal_ends_at > clock_timestamp() then return; end if;

  select server_seed into v_seed
  from private.bw_round_secrets
  where round_id = p_round_id;

  if v_seed is null then
    raise exception 'Round secret missing';
  end if;

  v_color := v_round.winner_color;

  select coalesce(sum(stake),0) into v_total
  from public.bw_bets where round_id = p_round_id;

  select coalesce(sum(stake),0) into v_winning
  from public.bw_bets where round_id = p_round_id and color = v_color;

  if v_winning = 0 then
    v_pool := 0;
    v_house := v_total;
    update public.bw_bets
    set status = 'lost', payout = 0
    where round_id = p_round_id;
  else
    select floor(v_total::numeric * (100 - s.house_percent) / 100)::bigint
    into v_pool
    from private.bw_settings s where s.id = 1;

    v_house := v_total - v_pool;

    with winners as (
      select b.id, b.stake,
             floor(v_pool::numeric * b.stake / v_winning)::bigint as base_payout,
             row_number() over(order by b.id) as rn
      from public.bw_bets b
      where b.round_id = p_round_id and b.color = v_color
    ),
    totals as (
      select coalesce(sum(base_payout),0) as base_total from winners
    ),
    allocations as (
      select w.id,
             w.base_payout + case when w.rn <= (v_pool - t.base_total) then 1 else 0 end as final_payout
      from winners w cross join totals t
    )
    update public.bw_bets b
    set status = case when b.color = v_color then 'won' else 'lost' end,
        payout = case when b.color = v_color then a.final_payout else 0 end
    from (select id, final_payout from allocations) a
    where b.id = a.id;

    update public.bw_bets
    set status = 'lost', payout = 0
    where round_id = p_round_id and color <> v_color;

    with user_wins as (
      select user_id, sum(payout)::bigint as amount
      from public.bw_bets
      where round_id = p_round_id and payout > 0
      group by user_id
    ),
    credited as (
      update public.bw_wallets w
      set balance = w.balance + u.amount, updated_at = now()
      from user_wins u
      where w.user_id = u.user_id
      returning w.user_id, w.balance,
        (select amount from user_wins x where x.user_id = w.user_id) as amount
    )
    insert into public.bw_ledger(user_id, entry_type, amount, balance_after, reference)
    select user_id, 'win', amount, balance, 'round:' || p_round_id::text
    from credited;
  end if;

  if v_house > 0 then
    update private.bw_house_accounts
    set balance = balance + v_house, updated_at = now()
    where id = 1;

    insert into private.bw_house_ledger(round_id, entry_type, amount)
    values (
      p_round_id,
      case when v_winning = 0 then 'dead_round' else 'round_fee' end,
      v_house
    );
  end if;

  update public.bw_rounds
  set status = 'settled',
      settled_at = now(),
      server_seed_reveal = v_seed,
      total_pot = v_total,
      winning_stake = v_winning,
      payout_pool = v_pool,
      house_amount = v_house,
      dead_round = (v_winning = 0)
  where id = p_round_id and status = 'revealing';
end;
$function$;

create or replace function private.bw_advance_round()
returns bigint
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_round public.bw_rounds%rowtype;
  v_seed text;
  v_duration integer;
  v_betting_seconds integer;
  v_reveal_seconds integer := 3;
  v_start timestamptz;
begin
  perform pg_advisory_xact_lock(7812345601);

  select round_duration_seconds into v_duration
  from private.bw_settings where id = 1;

  if v_duration <> 10 then
    raise exception 'B-Will V2 round duration must remain 10 seconds';
  end if;

  v_betting_seconds := v_duration - v_reveal_seconds;

  select * into v_round
  from public.bw_rounds
  where status in ('open','revealing')
  order by id desc
  limit 1
  for update;

  if found and v_round.status = 'open'
     and v_round.closes_at <= clock_timestamp() then
    perform private.bw_begin_reveal(v_round.id);
    select * into v_round from public.bw_rounds where id = v_round.id;
  end if;

  if found and v_round.status = 'revealing'
     and v_round.reveal_ends_at <= clock_timestamp() then
    perform private.bw_settle_round(v_round.id);
    v_round := null;
  end if;

  if v_round.id is null then
    v_start := clock_timestamp();
    v_seed := encode(extensions.gen_random_bytes(32),'hex');

    insert into public.bw_rounds(
      status, starts_at, closes_at, reveal_ends_at, server_seed_hash, client_seed
    )
    values (
      'open',
      v_start,
      v_start + make_interval(secs => v_betting_seconds),
      v_start + make_interval(secs => v_duration),
      encode(extensions.digest(decode(v_seed,'hex'),'sha256'),'hex'),
      gen_random_uuid()::text
    )
    returning * into v_round;

    insert into private.bw_round_secrets(round_id,server_seed)
    values (v_round.id,v_seed);
  end if;

  return v_round.id;
end;
$function$;

create or replace function public.bw_tick()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_round public.bw_rounds%rowtype;
  v_prev public.bw_rounds%rowtype;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;

  perform public.bw_ensure_account();
  perform private.bw_advance_round();

  select * into v_round
  from public.bw_rounds
  where status in ('open','revealing')
  order by id desc
  limit 1;

  select * into v_prev
  from public.bw_rounds
  where status = 'settled'
  order by id desc
  limit 1;

  return jsonb_build_object(
    'round', jsonb_build_object(
      'id', v_round.id,
      'status', v_round.status,
      'phase', v_round.status,
      'starts_at', v_round.starts_at,
      'closes_at', v_round.closes_at,
      'reveal_ends_at', v_round.reveal_ends_at,
      'winner_color', case when v_round.status = 'revealing' then v_round.winner_color else null end,
      'server_seed_hash', v_round.server_seed_hash,
      'client_seed', v_round.client_seed,
      'total_pot', v_round.total_pot
    ),
    'previous_round', case when v_prev.id is null then null else jsonb_build_object(
      'id', v_prev.id,
      'winner_color', v_prev.winner_color,
      'server_seed_hash', v_prev.server_seed_hash,
      'server_seed_reveal', v_prev.server_seed_reveal,
      'client_seed', v_prev.client_seed,
      'total_pot', v_prev.total_pot,
      'winning_stake', v_prev.winning_stake,
      'payout_pool', v_prev.payout_pool,
      'house_amount', v_prev.house_amount,
      'dead_round', v_prev.dead_round
    ) end
  );
end;
$function$;

revoke all on function private.bw_begin_reveal(bigint) from public, anon, authenticated;
revoke all on function private.bw_settle_round(bigint) from public, anon, authenticated;
revoke all on function private.bw_advance_round() from public, anon, authenticated;
revoke all on function public.bw_tick() from public, anon;
grant execute on function public.bw_tick() to authenticated;

select cron.alter_job(
  job_id := (select jobid from cron.job where jobname = 'bw-round-advance'),
  schedule := '1 second',
  command := 'select private.bw_advance_round();',
  active := true
);

commit;
