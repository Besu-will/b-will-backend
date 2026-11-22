create or replace function public.bw_get_win_leaderboard(
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_limit integer default 100
)
returns table (
  rank bigint,
  username text,
  wins bigint
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if p_start_at is null or p_end_at is null or p_end_at <= p_start_at then
    raise exception 'Invalid leaderboard time window';
  end if;

  return query
  with player_wins as (
    select
      b.user_id,
      coalesce(max(nullif(b.username_snapshot, '')), 'Player') as player_name,
      count(*)::bigint as win_count
    from public.bw_bets b
    where b.status = 'won'
      and b.created_at >= p_start_at
      and b.created_at < p_end_at
    group by b.user_id
  ),
  ranked as (
    select
      dense_rank() over (order by pw.win_count desc) as player_rank,
      pw.player_name,
      pw.win_count
    from player_wins pw
  )
  select r.player_rank, r.player_name, r.win_count
  from ranked r
  order by r.win_count desc, r.player_name asc
  limit greatest(1, least(coalesce(p_limit, 100), 100));
end;
$$;

revoke execute on function public.bw_get_win_leaderboard(timestamptz, timestamptz, integer) from public, anon;
grant execute on function public.bw_get_win_leaderboard(timestamptz, timestamptz, integer) to authenticated;
