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

These migrations are additive. They do not drop or rewrite the legacy v1 tables. The original SQL has been applied to Supabase; this repository currently records the applied migration identifiers and the current backend contract. Keep future schema changes as versioned SQL files in this directory before applying them.
