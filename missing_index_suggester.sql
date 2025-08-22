/*
  missing_index_suggester.sql
  Purpose  : Suggest high-impact nonclustered indexes from DMVs while avoiding duplicates.
  Scope    : Current database only.
  Notes    : Review every suggestion—DMVs ignore write costs, filtered indexes, partitioning, etc.
  Tested on: SQL Server 2016+ (works on newer too).

  Parameters (tweak as needed):
    @FreshDays        : ignore suggestions older than N days
    @MinActivity      : minimum (seeks + scans)
    @MinImpactScore   : min improvement measure (avg_total_user_cost * (avg_user_impact/100) * (seeks+scans))
*/

DECLARE @FreshDays      int         = 30;
DECLARE @MinActivity   int         = 50;
DECLARE @MinImpactScore decimal(18,4) = 10.0;

;WITH recs AS (
  SELECT
      improvement_measure =
        migs.avg_total_user_cost
        * (migs.avg_user_impact / 100.0)
        * (migs.user_seeks + migs.user_scans),
      db_name   = PARSENAME(mid.statement, 3),
      sch_name  = PARSENAME(mid.statement, 2),
      tab_name  = PARSENAME(mid.statement, 1),
      key_eq    = COALESCE(mid.equality_columns, ''),
      key_ineq  = COALESCE(mid.inequality_columns, ''),
      inc_cols  = mid.included_columns,
      object_id = mid.[object_id],
      index_name = 'missing_index_' + CONVERT(varchar(20), mig.index_group_handle) + '_' +
                   CONVERT(varchar(20), mid.index_handle) + '_' +
                   LEFT(PARSENAME(mid.statement, 1), 32),
      migs.*
  FROM sys.dm_db_missing_index_groups AS mig
  JOIN sys.dm_db_missing_index_group_stats AS migs
    ON migs.group_handle = mig.index_group_handle
  JOIN sys.dm_db_missing_index_details AS mid
    ON mig.index_handle = mid.index_handle
  WHERE mid.database_id = DB_ID()
    AND OBJECTPROPERTY(mid.[object_id], 'IsMsShipped') = 0
    AND migs.last_user_seek > DATEADD(day, -@FreshDays, SYSDATETIME())
    AND (migs.user_seeks + migs.user_scans) >= @MinActivity
    AND (migs.avg_total_user_cost * (migs.avg_user_impact / 100.0) *
         (migs.user_seeks + migs.user_scans)) >= @MinImpactScore
),
-- Normalize proposed key/include lists to simple comma lists: a,b,c (no brackets/spaces)
proposed AS (
  SELECT r.*,
         proposed_keys_raw = REPLACE(REPLACE(
           NULLIF(
             COALESCE(r.key_eq,'') +
             CASE WHEN r.key_eq <> '' AND r.key_ineq <> '' THEN ',' ELSE '' END +
             COALESCE(r.key_ineq,'')
           , ''), '[',''), ' ',''),
         proposed_includes_raw = REPLACE(REPLACE(NULLIF(COALESCE(r.inc_cols,''), ''), '[',''), ' ','')
  FROM recs r
),
-- Existing nonclustered indexes on the table with their key/include lists
existing_ix AS (
  SELECT
      ix.object_id,
      ix.index_id,
      ix.name,
      key_list = REPLACE(REPLACE(
                   STUFF((
                     SELECT ',' + c.name
                     FROM sys.index_columns ic2
                     JOIN sys.columns c
                       ON c.object_id = ic2.object_id AND c.column_id = ic2.column_id
                     WHERE ic2.object_id = ix.object_id
                       AND ic2.index_id = ix.index_id
                       AND ic2.is_included_column = 0
                     ORDER BY ic2.key_ordinal
                     FOR XML PATH(''), TYPE).value('.','nvarchar(max)')
                   ,1,1,'')
                 ,'[',''), ' ',''),
      include_list = REPLACE(REPLACE(
                      STUFF((
                        SELECT ',' + c.name
                        FROM sys.index_columns ic2
                        JOIN sys.columns c
                          ON c.object_id = ic2.object_id AND c.column_id = ic2.column_id
                        WHERE ic2.object_id = ix.object_id
                          AND ic2.index_id = ix.index_id
                          AND ic2.is_included_column = 1
                        ORDER BY c.name
                        FOR XML PATH(''), TYPE).value('.','nvarchar(max)')
                      ,1,1,'')
                    ,'[',''), ' ','')
  FROM sys.indexes ix
  WHERE ix.is_hypothetical = 0
    AND ix.type_desc = 'NONCLUSTERED'
    AND OBJECTPROPERTY(ix.object_id, 'IsMsShipped') = 0
)
SELECT
  p.improvement_measure,
  create_index_statement =
      'CREATE INDEX ' + QUOTENAME(p.index_name) + ' ON '
      + QUOTENAME(DB_NAME()) + '.' + QUOTENAME(p.sch_name) + '.' + QUOTENAME(p.tab_name)
      + ' (' + p.key_eq
      + CASE WHEN p.key_eq <> '' AND p.key_ineq <> '' THEN ',' ELSE '' END
      + p.key_ineq + ')'
      + CASE WHEN p.inc_cols IS NOT NULL THEN ' INCLUDE (' + p.inc_cols + ')' ELSE '' END
      + ';',
  -- helpful context
  table_qualified = QUOTENAME(DB_NAME()) + '.' + QUOTENAME(p.sch_name) + '.' + QUOTENAME(p.tab_name),
  proposed_keys   = p.proposed_keys_raw,
  proposed_includes = p.proposed_includes_raw,
  p.user_seeks, p.user_scans, p.avg_user_impact, p.avg_total_user_cost, p.last_user_seek
FROM proposed p
WHERE
  -- Skip if an existing index already covers this suggestion
  NOT EXISTS (
    SELECT 1
    FROM existing_ix e
    WHERE e.object_id = p.object_id
      AND (
           -- (A) Exact same leading keys
           e.key_list = p.proposed_keys_raw
        OR -- (B) Existing is a strict superset with same prefix (proposed is a left-prefix of existing)
           (p.proposed_keys_raw <> '' AND
            LEFT(e.key_list, LEN(p.proposed_keys_raw) + 1) = p.proposed_keys_raw + ',')
        OR -- (C) Same keys, and existing includes cover proposed INCLUDEs
           (e.key_list = p.proposed_keys_raw
            AND (
               p.proposed_includes_raw = '' -- nothing to include
               OR ',' + e.include_list + ',' LIKE '%,' + REPLACE(p.proposed_includes_raw, ',', ',%') + ',%'
            ))
      )
  )
ORDER BY p.improvement_measure DESC;
