-- Transaction-only tests for virtual Balance requests and withdrawal reservations.
-- Requires one non-Host player account with at least 5 Balance and one Host account.
-- All test requests, ledger entries, and Balance changes are rolled back.

begin;
select pg_advisory_xact_lock(7812345601);

do $$
declare
  v_player uuid;
  v_host uuid;
  v_round_id bigint;
  v_req jsonb;
  v_result jsonb;
  v_history jsonb;
  v_host_list jsonb;
  v_req_cancel bigint;
  v_req_reject bigint;
  v_req_approve bigint;
  v_req_deposit bigint;
  v_before bigint;
  v_after bigint;
  v_reserved bigint;
  v_rejected boolean := false;
begin
  select user_id into v_host from private.bw_admins limit 1;
  select w.user_id into v_player
  from public.bw_wallets w
  where w.balance>=5
    and not exists(select 1 from private.bw_admins a where a.user_id=w.user_id)
  order by w.balance desc
  limit 1;

  if v_host is null or v_player is null then
    raise exception 'A Host and a non-Host player account are required';
  end if;

  -- Ensure the game has an open round for the available-Balance betting guard test.
  perform private.bw_advance_round();
  select id into v_round_id from public.bw_rounds where status='open';
  if v_round_id is null then
    update public.bw_rounds
    set reveal_ends_at=clock_timestamp()-interval '1 second'
    where status='revealing';
    perform private.bw_advance_round();
    select id into v_round_id from public.bw_rounds where status='open';
  end if;
  if v_round_id is null then raise exception 'Unable to prepare open test round'; end if;
  update public.bw_rounds
  set closes_at=clock_timestamp()+interval '1 hour',
      reveal_ends_at=clock_timestamp()+interval '1 hour 3 seconds'
  where id=v_round_id and status='open';

  perform set_config('request.jwt.claim.sub',v_player::text,true);
  select balance into v_before from public.bw_wallets where user_id=v_player;

  -- Withdraw request reserves Balance without reducing total Balance.
  v_req:=public.bw_submit_balance_request('withdraw',5,'Test reservation');
  v_req_cancel:=(v_req->>'request_id')::bigint;
  if (v_req->>'balance')::bigint<>v_before
     or (v_req->>'reserved_balance')::bigint<>5
     or (v_req->>'available_balance')::bigint<>v_before-5 then
    raise exception 'Withdraw reservation values are incorrect';
  end if;

  -- The same Balance cannot be reserved twice.
  begin
    perform public.bw_submit_balance_request('withdraw',v_before,'Over-reservation');
    raise exception 'Over-reservation unexpectedly succeeded';
  exception when others then
    if position('Insufficient available Balance' in sqlerrm)=0 then raise; end if;
    v_rejected:=true;
  end;
  if not v_rejected then raise exception 'Over-reservation was not rejected'; end if;

  -- Betting must use available Balance, not total Balance.
  v_rejected:=false;
  begin
    perform public.bw_place_bet(1::smallint,'green',v_before);
    raise exception 'Bet unexpectedly spent reserved Balance';
  exception when others then
    if position('Insufficient available Balance' in sqlerrm)=0 then raise; end if;
    v_rejected:=true;
  end;
  if not v_rejected then raise exception 'Reserved Balance was spendable'; end if;

  -- Host adjustments cannot reduce total Balance below reserved Balance.
  perform set_config('request.jwt.claim.sub',v_host::text,true);
  v_rejected:=false;
  begin
    perform public.bw_admin_adjust(v_player,-(v_before-4),'Reserved Balance guard');
    raise exception 'Host adjustment unexpectedly consumed reserved Balance';
  exception when others then
    if position('reserved Balance' in sqlerrm)=0 then raise; end if;
    v_rejected:=true;
  end;
  if not v_rejected then raise exception 'Reserved Balance adjustment guard failed'; end if;

  -- Player cancellation releases the reservation.
  perform set_config('request.jwt.claim.sub',v_player::text,true);
  v_result:=public.bw_cancel_balance_request(v_req_cancel);
  if (v_result->>'available_balance')::bigint<>v_before
     or (v_result->>'reserved_balance')::bigint<>0 then
    raise exception 'Player cancellation did not release reservation';
  end if;

  -- Host rejection also releases a pending Withdraw reservation.
  v_req:=public.bw_submit_balance_request('withdraw',5,'Test rejection');
  v_req_reject:=(v_req->>'request_id')::bigint;
  perform set_config('request.jwt.claim.sub',v_host::text,true);
  v_result:=public.bw_admin_review_balance_request(v_req_reject,'reject','Test rejection');
  if (v_result->>'available_balance')::bigint<>v_before
     or (v_result->>'reserved_balance')::bigint<>0 then
    raise exception 'Host rejection did not release reservation';
  end if;

  -- Host approval deducts the reserved amount.
  perform set_config('request.jwt.claim.sub',v_player::text,true);
  v_req:=public.bw_submit_balance_request('withdraw',5,'Test approved Withdraw');
  v_req_approve:=(v_req->>'request_id')::bigint;
  perform set_config('request.jwt.claim.sub',v_host::text,true);
  v_result:=public.bw_admin_review_balance_request(v_req_approve,'approve',null);
  if (v_result->>'balance')::bigint<>v_before-5
     or (v_result->>'reserved_balance')::bigint<>0 then
    raise exception 'Approved Withdraw did not deduct correctly';
  end if;

  -- Host approval credits a Deposit request to the virtual Balance.
  perform set_config('request.jwt.claim.sub',v_player::text,true);
  v_req:=public.bw_submit_balance_request('deposit',50,'Test approved Deposit');
  v_req_deposit:=(v_req->>'request_id')::bigint;
  perform set_config('request.jwt.claim.sub',v_host::text,true);
  v_result:=public.bw_admin_review_balance_request(v_req_deposit,'approve',null);
  if (v_result->>'balance')::bigint<>v_before+45 then
    raise exception 'Approved Deposit did not credit correctly';
  end if;

  v_host_list:=public.bw_admin_list_balance_requests('all',100);
  if jsonb_array_length(v_host_list->'requests')<4 then
    raise exception 'Host request list is incomplete';
  end if;

  perform set_config('request.jwt.claim.sub',v_player::text,true);
  v_history:=public.bw_get_my_requests(100,null);
  if not exists(select 1 from jsonb_array_elements(v_history->'items') e
    where (e->>'request_id')::bigint=v_req_cancel and e->>'status'='cancelled') then
    raise exception 'Player request history omitted cancelled request';
  end if;
  if not exists(select 1 from jsonb_array_elements(v_history->'items') e
    where (e->>'request_id')::bigint=v_req_approve and e->>'status'='approved') then
    raise exception 'Player request history omitted approved request';
  end if;

  select balance,reserved_balance into v_after,v_reserved
  from public.bw_wallets where user_id=v_player;
  if v_after<>v_before+45 or v_reserved<>0 then
    raise exception 'Final Balance or reservation mismatch';
  end if;
end $$;

rollback;
