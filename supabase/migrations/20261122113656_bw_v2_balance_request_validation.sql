-- Tighten null-input validation and avoid bigint ABS overflow in Host adjustments.
begin;

do $$
declare
  v_def text;
  v_old text;
begin
  select pg_get_functiondef('public.bw_submit_balance_request(text,bigint,text)'::regprocedure)
  into v_def;
  v_old := 'if v_type not in (''deposit'',''withdraw'') then';
  if position(v_old in v_def)=0 then raise exception 'Expected Balance request validation text not found'; end if;
  execute replace(v_def,v_old,'if v_type is null or v_type not in (''deposit'',''withdraw'') then');

  select pg_get_functiondef('public.bw_admin_review_balance_request(bigint,text,text)'::regprocedure)
  into v_def;
  v_old := 'if v_decision not in (''approve'',''reject'') then';
  if position(v_old in v_def)=0 then raise exception 'Expected Host decision validation text not found'; end if;
  execute replace(v_def,v_old,'if v_decision is null or v_decision not in (''approve'',''reject'') then');

  select pg_get_functiondef('public.bw_admin_adjust(uuid,bigint,text)'::regprocedure)
  into v_def;
  v_old := 'if p_amount is null or p_amount=0 or abs(p_amount)>1000000 then';
  if position(v_old in v_def)=0 then raise exception 'Expected Host adjustment validation text not found'; end if;
  execute replace(v_def,v_old,'if p_amount is null or p_amount=0 or p_amount>1000000 or p_amount < -1000000 then');
end $$;

commit;
