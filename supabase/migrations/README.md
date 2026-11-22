# Supabase migration history

The B-Will v2 database migrations were applied to the Supabase project referenced by the project owner. The exact applied migration versions are listed below.

| Version | Migration |
|---|---|
| 20261122061938 | bw_v2_core_virtual_game |
| 20261122062108 | bw_v2_lock_private_tables |
| 20261122062147 | enable_pg_cron_for_round_scheduler |
| 20261122062233 | bw_v2_server_round_scheduler |
| 20261122062259 | bw_v2_admin_dashboard_rpcs |
| 20261122062924 | bw_v2_preserve_bet_audit_on_account_deletion |
| 20261122063008 | bw_v2_secure_live_bets_view |
| 20261122063021 | bw_v2_explicit_private_api_denials |
| 20261122112209 | bw_v2_ten_second_round_engine |
| 20261122112444 | bw_v2_cron_history_cleanup |
| 20261122112846 | bw_v2_bet_cancellation_and_history |
| 20261122113439 | bw_v2_virtual_balance_requests |
| 20261122113656 | bw_v2_balance_request_validation |
| 20261122113848 | bw_v2_rls_query_performance |

These migrations are additive. They do not drop or rewrite the legacy v1 tables. The SQL for the two new V2 round-engine migrations is stored in this directory under the exact applied version identifiers. Earlier migrations predate this source archive and are recorded here by version. Keep every future schema change as a versioned SQL file in this directory before applying it.
