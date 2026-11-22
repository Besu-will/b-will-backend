# B-Will v2 backend

B-Will is a virtual, non-monetary colour game. Game Balance has no cash value and cannot be purchased, transferred, withdrawn, or redeemed. The backend is Supabase PostgreSQL.

## Current implementation

- Additive v2 schema; the original v1 tables and RPCs are preserved.
- Server-authoritative rounds with three equally likely outcomes: green, orange, blue.
- Two bet slots per player per round.
- Players can cancel a placed bet before the 7-second betting cutoff; the full stake is returned and the cancelled row remains in the audit history.
- Cancelled bets release their slot, are excluded from live bets and settlement, and cannot be cancelled after betting closes.
- Authenticated players can retrieve their own paginated bet history, including cancelled bets.
- Player-facing Deposit and Withdraw are Host-reviewed internal Game Balance requests only; there are no payments, cash deposits, payouts, or cash withdrawals.
- Pending Withdraw requests reserve available Balance immediately. Approval deducts the reserved amount; rejection or player cancellation releases it.
- Wallet balances and an auditable, append-only player ledger.
- Secure random server seeds, SHA-256 commitment before betting, winner determined at reveal, and seed disclosed only after settlement.
- Atomic settlement: a normal round distributes 90% of the total pot among winning stakes proportionally; the house receives 10%. If no one selected the winning colour, the round is dead and the house receives the full pot.
- Row-level security on all v2 public and private tables; the live-bets view uses invoker permissions and exposes only public activity fields, never account IDs.
- Bet audit rows and display-name snapshots survive account deletion.
- Host-only Game Balance adjustments with a required reason.
- Server-controlled 10-second rounds: 7 seconds for betting, then 3 seconds for reveal and settlement.
- Supabase Cron advances the round engine every second; a daily cleanup job bounds scheduler run-history storage.
- PostgreSQL cron job `bw-round-advance` runs every minute. Authenticated clients also request the current state; database locks make round advancement idempotent.

## Defaults

| Setting | Value |
|---|---:|
| Starting balance | 1,000 Game Balance |
| Minimum stake | 5 |
| Maximum stake | 10,000 |
| Round duration | 10 seconds total (7 betting + 3 reveal) |
| Normal house share | 10% |
| Player slots | 2 |

Settings are held in `private.bw_settings`.

## Main RPCs

- `bw_ensure_account()` — ensure the signed-in user has a profile and wallet.
- `bw_get_state()` — current round, wallet, own bets, previous result, recent history.
- `bw_tick()` — advance due rounds and return the current round.
- `bw_place_bet(p_slot, p_color, p_stake)` — atomically validate and place a bet.
- `bw_cancel_bet(p_bet_id)` — return a stake before betting closes and retain a cancellation audit record.
- `bw_get_my_history(p_limit, p_before_id)` — return the signed-in player's paginated betting history.
- `bw_submit_balance_request(p_type, p_amount, p_note)` — submit an internal Deposit or Withdraw request.
- `bw_cancel_balance_request(p_request_id)` — cancel a pending player request and release any Withdraw reservation.
- `bw_get_my_requests(p_limit, p_before_id)` — return the player's own request history.
- `bw_admin_list_balance_requests(p_status, p_limit)` — Host-only request queue.
- `bw_admin_review_balance_request(p_request_id, p_decision, p_reason)` — Host-only approval or rejection.
- `bw_admin_history(p_limit)` — Host-only rounds, bets, Balance ledger, and request history.
- `bw_set_username(p_username)` — change the player's public display name.
- `bw_is_admin()` — report whether the signed-in user is a host.
- `bw_admin_dashboard()` — host-only player, round, and house overview.
- `bw_admin_adjust(p_user_id, p_amount, p_reason)` — host-only Game Balance adjustment.

The live-bet read model is `public.bw_live_bets`; it deliberately exposes display names, selected colours, stakes and slots, but not account IDs.

## Database objects

Public tables: `bw_profiles`, `bw_wallets`, `bw_ledger`, `bw_rounds`, `bw_bets`.

Private tables: `bw_settings`, `bw_admins`, `bw_house_accounts`, `bw_house_ledger`, `bw_round_secrets`.

Additional V2 public table: `bw_balance_requests`. Player wallet rows track `balance`, `reserved_balance`, and the derived available Balance. V2 read policies use init-plan-friendly auth checks and the request table exposes one combined owner/Host read policy. The Host dashboard read model includes current round phase, active players, current betting activity, and pending request count.

Private seed material is not exposed through the API. Only the hash is published before a round; the seed is revealed in the settled round record.

## Applied Supabase migrations

- `20261122061938_bw_v2_core_virtual_game`
- `20261122062108_bw_v2_lock_private_tables`
- `20261122062147_enable_pg_cron_for_round_scheduler`
- `20261122062233_bw_v2_server_round_scheduler`
- `20261122062259_bw_v2_admin_dashboard_rpcs`
- `20261122062924_bw_v2_preserve_bet_audit_on_account_deletion`
- `20261122063008_bw_v2_secure_live_bets_view`
- `20261122063021_bw_v2_explicit_private_api_denials`
- `20261122112209_bw_v2_ten_second_round_engine`
- `20261122112444_bw_v2_cron_history_cleanup`
- `20261122112846_bw_v2_bet_cancellation_and_history`
- `20261122113439_bw_v2_virtual_balance_requests`
- `20261122113656_bw_v2_balance_request_validation`
- `20261122113848_bw_v2_rls_query_performance`
- `20261122114114_bw_v2_host_dashboard_history`

## Testing status

The database was exercised in a transaction using two existing test accounts. The tests placed four bets across two users, forced settlement, verified the seed commitment, reconciled winner payouts and wallet balances, and rolled back. A separate dead-round test checked that the full pot is credited to the virtual house with no payout. The V2 round lifecycle test verifies the betting cutoff, reveal phase, delayed seed disclosure, settlement, and player/house reconciliation inside a rolled-back transaction. The cancellation/history test verifies full stake return, slot reuse, post-cutoff rejection, preservation of cancelled records, and cancellation-aware settlement, also inside a rolled-back transaction. The Balance-request test verifies reservations, over-reservation and betting guards, player cancellation, Host rejection/approval, and ledger reconciliation; it also rolls back all test data. Admin authorization and private-table access were also checked. No test wagers or Balance adjustments were retained.

## Deployment status

The v2 frontend is being developed on the `v2-rebuild` branch of `Besu-will/b-will`. Do not point production users at it until end-to-end browser testing and a deliberate cutover. The legacy app and its tables have not been deleted or modified by the v2 build.
