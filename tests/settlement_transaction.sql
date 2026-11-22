-- Transaction-only settlement checks. Requires at least two existing auth users.
-- All changes are rolled back; no test wagers or coin adjustments persist.

begin;
do $$
declare
  u1 uuid; u2 uuid; st jsonb; rid bigint; r public.bw_rounds%rowtype;
  payouts bigint; wallet_before bigint; wallet_after bigint;
begin
  select id into u1 from auth.users order by created_at limit 1;
  select id into u2 from auth.users order by created_at offset 1 limit 1;
  if u1 is null or u2 is null then raise exception 'Two test accounts required'; end if;
  perform set_config('request.jwt.claim.sub',u1::text,true);
  select coalesce(sum(balance),0) into wallet_before from public.bw_wallets where user_id in (u1,u2);
  st:=public.bw_get_state();
  rid:=(st->'round'->>'id')::bigint;
  perform public.bw_place_bet(1::smallint,'green',5::bigint);
  perform public.bw_place_bet(2::smallint,'orange',5::bigint);
  perform set_config('request.jwt.claim.sub',u2::text,true);
  perform public.bw_place_bet(1::smallint,'blue',5::bigint);
  perform public.bw_place_bet(2::smallint,'green',5::bigint);
  update public.bw_rounds set starts_at=now()-interval '2 minutes',closes_at=now()-interval '1 second' where id=rid;
  perform set_config('request.jwt.claim.sub',u1::text,true);
  perform public.bw_tick();
  select * into r from public.bw_rounds where id=rid;
  if r.status<>'settled' or r.total_pot<>20 or r.payout_pool<>18 or r.house_amount<>2 then
    raise exception 'Settlement totals incorrect';
  end if;
  if encode(extensions.digest(decode(r.server_seed_reveal,'hex'),'sha256'),'hex')<>r.server_seed_hash then
    raise exception 'Commit/reveal mismatch';
  end if;
  select coalesce(sum(payout),0) into payouts from public.bw_bets where round_id=rid;
  if payouts<>r.payout_pool then raise exception 'Payouts do not reconcile to pool'; end if;
  select coalesce(sum(balance),0) into wallet_after from public.bw_wallets where user_id in (u1,u2);
  if wallet_after<>wallet_before-20+r.payout_pool then raise exception 'Wallet conservation failed'; end if;
end $$;
rollback;

-- Dead-round check: bet against the deterministic outcome, settle, then verify
-- the full pot is credited to the virtual house and no player receives a payout.
begin;
do $$
declare
  u uuid; st jsonb; rid bigint; r public.bw_rounds%rowtype; seed text;
  dig bytea; n bigint; counter integer:=0; winning text; losing text;
  house_before bigint; house_after bigint; paid bigint;
begin
  select id into u from auth.users order by created_at limit 1;
  perform set_config('request.jwt.claim.sub',u::text,true);
  st:=public.bw_get_state(); rid:=(st->'round'->>'id')::bigint;
  select server_seed into seed from private.bw_round_secrets where round_id=rid;
  select balance into house_before from private.bw_house_accounts where id=1;
  loop
    dig:=extensions.hmac(convert_to((select id::text||':'||client_seed||':'||counter::text from public.bw_rounds where id=rid),'UTF8'),decode(seed,'hex'),'sha256');
    n:=get_byte(dig,0)::bigint*16777216+get_byte(dig,1)::bigint*65536+get_byte(dig,2)::bigint*256+get_byte(dig,3)::bigint;
    exit when n<4294967295;
    counter:=counter+1;
  end loop;
  winning:=case (n%3)::integer when 0 then 'green' when 1 then 'orange' else 'blue' end;
  losing:=case winning when 'green' then 'orange' when 'orange' then 'blue' else 'green' end;
  perform public.bw_place_bet(1::smallint,losing,5::bigint);
  update public.bw_rounds set starts_at=now()-interval '2 minutes',closes_at=now()-interval '1 second' where id=rid;
  perform public.bw_tick();
  select * into r from public.bw_rounds where id=rid;
  select coalesce(sum(payout),0) into paid from public.bw_bets where round_id=rid;
  select balance into house_after from private.bw_house_accounts where id=1;
  if not r.dead_round or r.house_amount<>5 or r.payout_pool<>0 or paid<>0 or house_after-house_before<>5 then
    raise exception 'Dead-round accounting failed';
  end if;
end $$;
rollback;
