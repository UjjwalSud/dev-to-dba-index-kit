DECLARE @sql nvarchar(max) = N'';
SELECT @sql = @sql + N'UPDATE STATISTICS '
    + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name) + N' '
    + QUOTENAME(st.name) + N' WITH RESAMPLE;' + CHAR(10)
FROM sys.stats st
JOIN sys.tables t ON t.object_id = st.object_id
LEFT JOIN sys.indexes i
  ON i.object_id = st.object_id AND i.index_id = st.stats_id   -- index-backed stats share id
WHERE i.index_id IS NULL; 

select @sql

EXEC sp_executesql @sql;
