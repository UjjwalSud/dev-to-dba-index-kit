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

⚠️ **Important:** These are *suggestions*, not guarantees. Always:

* Review the queries/plans before creating.
* Watch write-heavy tables (indexes add maintenance cost).
* Consider filtered/columnstore/partitioning options.

---

## 📜 License

free to use 
