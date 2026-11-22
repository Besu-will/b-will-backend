# B-Will v2 backend

B-Will is a virtual-coin colour game. Coins have no cash value and cannot be purchased, transferred, withdrawn, or redeemed. The backend is Supabase PostgreSQL.

## Current implementation

- Additive v2 schema; the original v1 tables and RPCs are preserved.
- Server-authoritative rounds with three equally likely outcomes: green, orange, blue.
- Two bet slots per player per round.
- Wallet balances and an auditable, append-only player ledger.
- Secure random server seeds, SHA-256 commit before betting, reveal after settlement.
- Atomic settlement: a normal round distributes 90% of the total pot among winning stakes proportionally; the house receives 10%. If no one selected the winning colour, the round is dead and the house receives the full pot.
- Row-level security on all v2 public and private tables.
- Admin-only virtual coin adjustments with a required reason.
- PostgreSQL cron job `bw-round-advance` runs every minute. Authenticated clients also request the current state; database locks make round advancement idempotent.

## Defaults

| Setting | Value |
|---|---:|
| Starting balance | 1,000 virtual coins |
| Minimum stake | 5 |
| Maximum stake | 10,000 |
| Round duration | 60 seconds |
| Normal house share | 10% |
| Player slots | 2 |

Settings are held in `private.bw_settings`.

## Main RPCs

- `bw_ensure_account()` — ensure the signed-in user has a profile and wallet.
- `bw_get_state()` — current round, wallet, own bets, previous result, recent history.
- `bw_tick()` — advance due rounds and return the current round.
- `bw_place_bet(p_slot, p_color, p_stake)` — atomically validate and place a bet.
- `bw_set_username(p_username)` — change the player's public display name.
- `bw_is_admin()` — report whether the signed-in user is a host.
- `bw_admin_dashboard()` — host-only player, round, and house overview.
- `bw_admin_adjust(p_user_id, p_amount, p_reason)` — host-only coin adjustment.

The live-bet read model is `public.bw_live_bets`; it deliberately exposes display names, selected colours, stakes and slots, but not account IDs.

## Database objects

Public tables: `bw_profiles`, `bw_wallets`, `bw_ledger`, `bw_rounds`, `bw_bets`.

Private tables: `bw_settings`, `bw_admins`, `bw_house_accounts`, `bw_house_ledger`, `bw_round_secrets`.

Private seed material is not exposed through the API. Only the hash is published before a round; the seed is revealed in the settled round record.

## Applied Supabase migrations

- `20261122061938_bw_v2_core_virtual_game`
- `20261122062108_bw_v2_lock_private_tables`
- `20261122062147_enable_pg_cron_for_round_scheduler`
- `20261122062233_bw_v2_server_round_scheduler`
- `20261122062259_bw_v2_admin_dashboard_rpcs`

## Testing status

The database was exercised in a transaction using two existing test accounts. The test placed four bets across two users, forced the round to expire, settled it, verified the seed commitment, checked that all winner payouts summed to the payout pool, checked wallet conservation, and rolled back the test transaction. No test bets or rounds were retained.

## Deployment status

The v2 frontend is being developed on the `v2-rebuild` branch of `Besu-will/b-will`. Do not point production users at it until end-to-end browser testing and a deliberate cutover. The legacy app and its tables have not been deleted or modified by the v2 build.
