# SQL Helper

A collection of handy SQL scripts that I (a developer-turned-DBA) use to troubleshoot and tune SQL Server.

## 🎯 Scripts

### `missing_index_suggester.sql`

Suggests high-impact nonclustered indexes based on SQL Server DMVs.

* **Ranks** by potential improvement (cost × impact × usage).
* **Skips duplicates** by checking against existing indexes (same/prefix keys or superset includes).
* **Scopes** to the current database only.
* **Adds filters** to ignore stale or low-value suggestions.
* **Outputs** ready-to-run `CREATE INDEX` statements.

### `rebuild_or_reorg_indexes.sql`

REORGANIZE (10–40%) or REBUILD (>40%) fragmented indexes.

* **Finds** leaf-level fragmentation via `sys.dm_db_index_physical_stats` (`LIMITED` by default).
* **Chooses action**: REORGANIZE 10–40% (`LOB_COMPACTION = ON`), REBUILD >40% (`ONLINE = ON`, `SORT_IN_TEMPDB = ON` when allowed).
* **Preview vs. execute**: `@Execute = 0` prints commands; `@Execute = 1` runs them and timestamps results.
* **Skips noise**: heaps, disabled/hypothetical indexes, and tiny indexes (`page_count < @MinPageCount`).
* **Edition-aware fallback**: automatically retries rebuilds without `ONLINE` if unsupported.
* **Tunable**: thresholds, min page count, stats mode (`LIMITED`/`SAMPLED`/`DETAILED`), online & tempdb options.
* **Outputs** ready-to-run `ALTER INDEX` statements.

### `refresh_statistics.sql`

Guides/statements for refreshing statistics **after index maintenance**.

* **When to use**

  * After **REORGANIZE** runs → update stats (reorganize doesn’t refresh them).
  * After **REBUILD** runs → skip index stats (rebuild refreshes them with FULLSCAN), but consider refreshing **non-index (column) stats**.

* **What this covers**

  * Keeps index stats fresh without double work after REBUILDs.
  * Ensures column stats (from AUTO\_CREATE\_STATISTICS / CREATE STATISTICS) are not forgotten.

> Tip: Schedule stats refresh separately for heavy ETL days or ascending-key tables.
## 
⚠️ **Important:** These are *suggestions*, not guarantees. Always:

* Review the queries/plans before creating.
* Watch write-heavy tables (indexes add maintenance cost).
* Consider filtered/columnstore/partitioning options.

## 📜 License

free to use 
