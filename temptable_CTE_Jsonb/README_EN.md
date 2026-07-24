# README_EN.md
# PostgreSQL Six Intermediate Data Processing Schemes Benchmark Test
## 1. Overview
This test suite implements **6 equivalent data transformation pipelines** for PostgreSQL, designed to compare the overhead of different intermediate data storage modes: CTE, relational temporary table, persistent JSONB table, temporary JSONB table, in-memory jsonb_agg array, batched temporary JSONB table.

**Unified business logic for all schemes**:
1. Filter source data: `src_data WHERE col1 > 800`
2. Update rows matching `val1 % 5 = 0` (val1 += 10)
3. Delete maximum 15000 rows matching `val2 LIKE '%A%'`
4. Write final dataset into permanent table `target_result`

**Test scale**: 3,000,000 source rows.
**PostgreSQL Version Requirement**: PostgreSQL 14+ (support `pg_current_wal_lsn()` and `pg_wal_lsn_diff()`).

## 2. Core Test Principle
### 2.1 WAL Measurement Method
We use **LSN difference** to calculate actual WAL volume:
```sql
v_lsn_before := pg_current_wal_lsn();
-- execute business logic
v_lsn_after := pg_current_wal_lsn();
v_wal_bytes := pg_wal_lsn_diff(v_lsn_after, v_lsn_before);
```
> Critical rule: PostgreSQL **TEMP tables skip WAL logging entirely**. All INSERT/UPDATE/DELETE on temporary tables will NOT generate WAL. Only writes to permanent tables produce WAL.

### 2.2 Dead Tuple Background (MVCC)
PostgreSQL MVCC mechanism:
- `UPDATE`: Mark original tuple dead, insert new tuple → generate dead tuple
- `DELETE`: Mark original tuple xmax → generate dead tuple
- **TEMP tables also generate dead tuples**, but temporary tables:
  1. Are invisible to `pg_stat_user_tables` (cannot observe dead tuple count via system views)
  2. All data and dead tuples are purged automatically after session disconnect
  3. Autovacuum never touches temporary tables

> Important limitation: The `target_dead_tup` / `mid_dead_tup` recorded in report **only reflects permanent tables**. Dead tuples inside temporary tables cannot be captured by built-in statistics.

### 2.3 Statistics Collector Limitation
`pg_stat_user_tables` relies on an asynchronous background collector. Metrics cannot refresh instantly after DML. The script uses `pg_sleep()` + `pg_stat_clear_snapshot()` to mitigate snapshot lag, but occasional historical residual values may still appear.

### 2.4 Consistent Control Variables
- Same source dataset `src_data`
- Same filter/update/delete rules
- Same final destination table `target_result`
- Same checkpoint before each test run
- Isolated database session for TEMP table schemes

## 3. Six Schemes Detailed Introduction
### Scheme 1: CTE Scheme
All operations run in streaming mode without intermediate storage. Update/Delete directly execute on permanent target table.
- Intermediate storage: None
- Modification target: Permanent table `target_result`
- Feature: All DML against permanent tables generates WAL.

### Scheme 2: TEMP Relational Table Scheme
Intermediate data stored in session-scoped temporary table with standard relational columns.
- Intermediate storage: `tmp_mid` (TEMP table, normal columns)
- WAL rule: Intermediate INSERT/UPDATE/DELETE → No WAL; only final INSERT into `target_result` generates WAL `target_result` generates WAL.
- Feature: Low CPU overhead, stable performance, shortest execution time. Single large transaction creates high instantaneous temporary file peak.

### Scheme3: Persistent JSONB Intermediate Table Scheme
Intermediate data stored in permanent table with `jsonb` column.
- Intermediate storage: `jsonb_mid` (permanent table)
- WAL rule: Two rounds of permanent table writes (intermediate table + target table), maximum WAL volume.
- Feature: JSONB updates produce massive persistent dead tuples, heavy autovacuum pressure. Intermediate data can be shared across sessions.

### Scheme4: TEMP Table with JSONB (Non-Persistent JSONB)
Intermediate data stored in temporary table with jsonb column, all intermediate operations skip WAL.
- Intermediate storage: `tmp_jsonb_mid` (TEMP table with jsonb)
- Feature: Same WAL overhead as normal temporary table. JSONB serialization & deserialization brings extra CPU cost. Bulk one-shot update creates high temporary dead tuple peak.

### Scheme5: In-memory jsonb_agg Array (No Intermediate Tables)
Aggregate all filtered rows into a single large `jsonb` variable inside PL/pgSQL. Transform data by unpack/re-aggregate JSON array, no physical tables created.
- Intermediate storage: In-memory PL/pgSQL jsonb variable
- Feature: Minimal theoretical WAL volume. Severe CPU overhead caused by repeated json parsing/rebuilding. Risk of spilling temporary files when `work_mem` insufficient.

### Scheme6: Batched Optimized TEMP+JSONB
Based on Scheme4, split large single-transaction UPDATE/DELETE into small batches to flatten instantaneous resource peak.
- Intermediate storage: `tmp_jsonb_batch` (TEMP table with jsonb)
- Feature: Total dead tuples equal to Scheme4, but instantaneous temporary IO spike is smoothed. Extra loop scheduling overhead leads to longer execution time than Scheme4.

## 4. Expected Test Result
### 4.1 WAL Volume Sort (Low → High)
`Scheme5 (In-memory jsonb_agg)` < `Scheme2 ≈ Scheme4 ≈ Scheme6 (TEMP table family)` < `Scheme1 (CTE)` < `Scheme3 (Persistent JSONB)`

> Explanation:
> All temporary-table-based schemes only generate WAL on final insertion into `target_result`, so WAL size is close. Scheme3 writes two permanent tables, hence maximum WAL.

### 4.2 Execution Latency Trend (Prediction)
`Scheme2 (TEMP relational table)` < `Scheme4` < `Scheme1` < `Scheme6` < `Scheme3` < `Scheme5`
- Scheme2: No JSON serialization overhead, fastest
- Scheme6: Batch loop brings extra latency compared to Scheme4
- Scheme5: Heavy JSON unpack/aggregation, longest runtime

### 4.3 Dead Tuple & Vacuum Pressure
1. **Scheme3**: Highest vacuum pressure. `jsonb_mid` accumulates persistent dead tuples, requires autovacuum cleanup.
2. **Scheme1**: Moderate dead tuples on `target_result`.
3. **Scheme2 /4 /6**: Dead tuples only exist inside temporary tables, automatically released after session exit, zero global vacuum impact.
4. **Scheme5**: No intermediate tables, dead tuples only exist on `target_result`.

### 4.4 Resource Peak Difference
- Scheme4: High instantaneous temporary directory IO spike (single massive transaction)
- Scheme6: Smoothed resource peak, suitable for high-concurrency environment
- Scheme5: High CPU pressure, risk of work_mem spill

## 5. How To Run
1. Execute initialization script **once only**
```sql
-- 0. Initialization (Execute once only)
DROP TABLE IF EXISTS src_data;
DROP TABLE IF EXISTS target_result;
DROP TABLE IF EXISTS jsonb_mid;
DROP TABLE IF EXISTS test_report;
-- full initialization SQL omitted
```
2. Run each scheme sequentially:
   - Scheme1,3,5 can run in same session
   - **Scheme2,4,6 REQUIRE SEPARATE DATABASE SESSION** (new query window in pgAdmin / new psql connection)
3. After all schemes finished, execute summary query:
```sql
SELECT
    test_case,
    pg_size_pretty(wal_bytes::bigint) AS wal_total_size,
    target_dead_tup,
    mid_dead_tup,
    exec_ms,
    finish_time
FROM test_report
ORDER BY test_case;
```

## 6. Known Limitations & Notes
1. Temporary table internal dead tuples **cannot be queried by system views**. We cannot quantify temporary dead tuple count, only judge resource pressure by temporary directory disk IO monitoring.
2. Avoid running other background jobs (autovacuum, backup, long transactions) during testing, to prevent interfering WAL and timing metrics.
3. If you observe abnormal residual dead tuple values, extend `pg_sleep()` duration to 2 seconds for statistics collector refresh.
4. `wal_records` column is reserved, cannot be obtained via LSN method, filled with 0 in current version.

## 7. Engineering Recommendation
1. Large batch ETL workload: **Scheme2 (TEMP relational table)** achieves the best balance of latency, CPU and WAL overhead.
2. Avoid Scheme3 (Persistent JSONB intermediate table) for data transformation pipelines due to excessive WAL and vacuum burden.
3. High-concurrency heavy data processing: Choose Scheme6 (batched TEMP+JSONB) if semi-structured data is required.
4. Do NOT adopt Scheme5 (in-memory jsonb_agg) for millions-scale datasets, due to extreme CPU consumption.

