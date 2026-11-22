-- Set a player's username from signup metadata and prevent later self-edits.
begin;

create or replace function private.bw_handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_start bigint;
  v_username text;
begin
  select starting_balance into v_start from private.bw_settings where id=1;

  v_username := nullif(btrim(new.raw_user_meta_data->>'username'),'');
  if v_username is null or v_username !~ '^[A-Za-z0-9_]{3,20}$' then
    v_username := 'Player' || substr(replace(new.id::text,'-',''),1,8);
  end if;

  insert into public.bw_profiles(user_id,username)
  values(new.id,v_username)
  on conflict(user_id) do nothing;

  insert into public.bw_wallets(user_id,balance)
  values(new.id,coalesce(v_start,1000))
  on conflict(user_id) do nothing;

  if not exists(
    select 1 from public.bw_ledger
    where user_id=new.id and entry_type='starting_grant'
  ) then
    insert into public.bw_ledger(user_id,entry_type,amount,balance_after,reference)
    select new.id,'starting_grant',coalesce(v_start,1000),coalesce(v_start,1000),'welcome Balance'
    where coalesce(v_start,1000)>0;
  end if;

  return new;
end;
$function$;

create or replace function public.bw_ensure_account()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_uid uuid:=auth.uid();
  v_start bigint;
  v_requested_username text;
  v_username text;
  v_wallet public.bw_wallets%rowtype;
  v_profile public.bw_profiles%rowtype;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;

  select starting_balance into v_start from private.bw_settings where id=1;
  select raw_user_meta_data->>'username' into v_requested_username
  from auth.users where id=v_uid;

  if v_requested_username is not null
     and v_requested_username ~ '^[A-Za-z0-9_]{3,20}$' then
    v_username:=v_requested_username;
  else
    v_username:='Player'||substr(replace(v_uid::text,'-',''),1,8);
  end if;

  insert into public.bw_profiles(user_id,username)
  values(v_uid,v_username)
  on conflict(user_id) do nothing;

  insert into public.bw_wallets(user_id,balance)
  values(v_uid,coalesce(v_start,1000))
  on conflict(user_id) do nothing;

  if not exists(
    select 1 from public.bw_ledger
    where user_id=v_uid and entry_type='starting_grant'
  ) then
    insert into public.bw_ledger(user_id,entry_type,amount,balance_after,reference)
    select v_uid,'starting_grant',w.balance,w.balance,'initial B-Will Balance'
    from public.bw_wallets w where w.user_id=v_uid and w.balance>0;
  end if;

  select * into v_wallet from public.bw_wallets where user_id=v_uid;
  select * into v_profile from public.bw_profiles where user_id=v_uid;

  return jsonb_build_object(
    'user_id',v_uid,'username',v_profile.username,'balance',v_wallet.balance,
    'reserved_balance',v_wallet.reserved_balance,
    'available_balance',v_wallet.balance-v_wallet.reserved_balance
  );
end;
$function$;

revoke all on function public.bw_set_username(text) from public,anon,authenticated;
revoke all on function public.bw_ensure_account() from public,anon;
grant execute on function public.bw_ensure_account() to authenticated;

commit;
