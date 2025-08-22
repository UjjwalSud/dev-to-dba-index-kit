/* 
  Purpose : Reorganize/Rebuild fragmented indexes in the current DB
  Usage   : EXEC dbo.usp_MaintainFragmentedIndexes @Execute = 0; -- preview only
            EXEC dbo.usp_MaintainFragmentedIndexes @Execute = 1; -- execute

  Notes   : - Uses dm_db_index_physical_stats in @Mode ('LIMITED' by default)
            - Reorganize 10–40%, Rebuild > 40% (tunable)
            - Skips small indexes, heaps, disabled/hypothetical indexes
            - Tries ONLINE rebuild first (if @UseOnline = 1), falls back if it errors
*/

 declare
  @Execute            bit          = 0,          -- 0 = preview, 1 = run
  @MinFragPercent     int          = 10,         -- minimum fragmentation to consider
  @RebuildThreshold   int          = 40,         -- > this = REBUILD, else REORGANIZE
  @MinPageCount       int          = 100,        -- skip tiny indexes
  @Mode               nvarchar(10) = N'LIMITED', -- LIMITED | SAMPLED | DETAILED
  @UseOnline          bit          = 1,          -- try ONLINE = ON for rebuilds
  @UseSortInTempdb    bit          = 1           -- use SORT_IN_TEMPDB on rebuilds
 
 

  IF OBJECT_ID('tempdb..#GetFragmentedIndexes') IS NOT NULL
      DROP TABLE #GetFragmentedIndexes;

  -- Build options string for REBUILD
  DECLARE @RebuildOptions nvarchar(200) = N'';
  IF @UseOnline = 1       SET @RebuildOptions += N'ONLINE = ON, ';
  IF @UseSortInTempdb = 1 SET @RebuildOptions += N'SORT_IN_TEMPDB = ON, ';
  -- trim trailing comma/space if present
  IF RIGHT(@RebuildOptions,2) = ', ' SET @RebuildOptions = LEFT(@RebuildOptions, LEN(@RebuildOptions)-2);
  IF LEN(@RebuildOptions) > 0 SET @RebuildOptions = N' WITH (' + @RebuildOptions + N')';

  -- Gather candidates (leaf level only)
  SELECT
      ROW_NUMBER() OVER (ORDER BY ips.avg_fragmentation_in_percent DESC) AS Numbering,
      DB_NAME(ips.database_id) AS [Database],
      sch.[name] AS [Schema],
      tbl.[name] AS [Table],
      ix.[name]  AS [Index],
      ips.avg_fragmentation_in_percent,
      ips.page_count,
      CASE
        WHEN ips.avg_fragmentation_in_percent >  @RebuildThreshold THEN
            N'ALTER INDEX ' + QUOTENAME(ix.[name]) + N' ON ' + QUOTENAME(sch.[name]) + N'.' + QUOTENAME(tbl.[name]) +
            N' REBUILD' + @RebuildOptions + N';'
        WHEN ips.avg_fragmentation_in_percent >= @MinFragPercent THEN
            N'ALTER INDEX ' + QUOTENAME(ix.[name]) + N' ON ' + QUOTENAME(sch.[name]) + N'.' + QUOTENAME(tbl.[name]) +
            N' REORGANIZE WITH (LOB_COMPACTION = ON);'
        ELSE NULL
      END AS ExecuteQuery,
      SYSUTCDATETIME() AS InsertionDateTime,
      CAST(NULL AS datetime2) AS UpdatedDateTime
  INTO #GetFragmentedIndexes
  FROM sys.dm_db_index_physical_stats (DB_ID(), NULL, NULL, NULL, @Mode) AS ips
  JOIN sys.indexes   AS ix  ON ix.[object_id] = ips.[object_id] AND ix.index_id = ips.index_id
  JOIN sys.tables    AS tbl ON tbl.[object_id] = ips.[object_id]
  JOIN sys.schemas   AS sch ON sch.[schema_id] = tbl.[schema_id]
  WHERE ips.database_id = DB_ID()
    AND ips.index_level = 0                      -- leaf level only
    AND ix.[name] IS NOT NULL                    -- skip heaps
    AND ix.is_hypothetical = 0
    AND ix.is_disabled = 0
    AND ips.avg_fragmentation_in_percent >= @MinFragPercent
    AND ips.page_count >= @MinPageCount
  ORDER BY ips.avg_fragmentation_in_percent DESC;

  -- If preview mode, just show the statements and exit
  IF @Execute = 0
  BEGIN
      SELECT Numbering, [Database], [Schema], [Table], [Index],
             avg_fragmentation_in_percent, page_count, ExecuteQuery
      FROM #GetFragmentedIndexes
      ORDER BY Numbering;

      DROP TABLE #GetFragmentedIndexes;
      RETURN;
  END

  -- Execute mode
  DECLARE
      @i int = 1,
      @n int = (SELECT COUNT(*) FROM #GetFragmentedIndexes),
      @ExecQuery nvarchar(max),
      @ErrMsg nvarchar(4000);

  WHILE (@i <= @n)
  BEGIN
      SELECT @ExecQuery = ExecuteQuery
      FROM #GetFragmentedIndexes WHERE Numbering = @i;

      IF @ExecQuery IS NOT NULL
      BEGIN
          BEGIN TRY
              EXEC (@ExecQuery);

              UPDATE #GetFragmentedIndexes
              SET UpdatedDateTime = SYSUTCDATETIME()
              WHERE Numbering = @i;
          END TRY
          BEGIN CATCH
              -- If ONLINE caused failure, retry without ONLINE
              IF @UseOnline = 1 AND CHARINDEX(N' REBUILD', @ExecQuery) > 0 AND CHARINDEX(N'ONLINE = ON', @ExecQuery) > 0
              BEGIN
                  DECLARE @Retry nvarchar(max) = REPLACE(@ExecQuery, N'ONLINE = ON, ', N'');
                  -- Also handle case with only ONLINE = ON present (no comma)
                  SET @Retry = REPLACE(@Retry, N'ONLINE = ON', N'');
                  -- clean up possible 'WITH ()'
                  SET @Retry = REPLACE(@Retry, N'WITH ()', N'');
                  -- remove trailing comma before ')'
                  SET @Retry = REPLACE(@Retry, N', )', N')');

                  BEGIN TRY
                      EXEC (@Retry);
                      UPDATE #GetFragmentedIndexes
                      SET UpdatedDateTime = SYSUTCDATETIME()
                      WHERE Numbering = @i;
                  END TRY
                  BEGIN CATCH
                      SET @ErrMsg = CONCAT('Index maintenance failed for row ', @i, ': ', ERROR_MESSAGE());
                      PRINT @ErrMsg;
                  END CATCH
              END
              ELSE
              BEGIN
                  SET @ErrMsg = CONCAT('Index maintenance failed for row ', @i, ': ', ERROR_MESSAGE());
                  PRINT @ErrMsg;
              END
          END CATCH
      END

      SET @i += 1;
  END

  -- Show results of what ran
  SELECT Numbering, [Database], [Schema], [Table], [Index],
         avg_fragmentation_in_percent, page_count,
         ExecuteQuery, UpdatedDateTime
  FROM #GetFragmentedIndexes
  ORDER BY Numbering;

  DROP TABLE #GetFragmentedIndexes;
