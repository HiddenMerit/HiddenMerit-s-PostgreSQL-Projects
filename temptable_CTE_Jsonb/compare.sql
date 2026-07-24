
-- 0. Initialization (Execute once only)
DROP TABLE IF EXISTS src_data;
DROP TABLE IF EXISTS target_result;
DROP TABLE IF EXISTS jsonb_mid;
DROP TABLE IF EXISTS test_report;

CREATE TABLE src_data (
    id bigint PRIMARY KEY,
    col1 int,
    col2 text,
    create_time timestamp
);

INSERT INTO src_data
SELECT generate_series(1,3000000),
       (random()*5000)::int,
       md5(random()::text),
       now();
ANALYZE src_data;

CREATE TABLE target_result (
    rid bigint PRIMARY KEY,
    val1 int,
    val2 text,
    update_flag int DEFAULT 0
);

CREATE TABLE jsonb_mid (
    id bigint PRIMARY KEY,
    payload jsonb
);

-- Test report table
CREATE TABLE test_report(
    test_case text,
    wal_bytes bigint,
    wal_records bigint,
    target_dead_tup bigint, -- Total dead tuples of target_result after test execution
    mid_dead_tup bigint,    -- Total dead tuples of jsonb_mid after test execution
    exec_ms bigint,
    finish_time timestamp default now()
);

-- =============================================================================
-- Scheme 1: CTE Approach
-- =============================================================================
DO $$
DECLARE
    v_lsn_before pg_lsn;
    v_lsn_after pg_lsn;
    v_wal_bytes bigint := 0;

    v_target_dead bigint;
    v_mid_dead bigint;
    v_start_ts timestamp;
BEGIN
    TRUNCATE target_result;
    TRUNCATE jsonb_mid;
    CHECKPOINT;

    v_start_ts := clock_timestamp();
    v_lsn_before := pg_current_wal_lsn();

    RAISE NOTICE 'CTE scheme starts business processing';

    WITH cte_calc AS (
        SELECT
            id AS rid,
            col1 * 3 AS val1,
            upper(col2) AS val2
        FROM src_data
        WHERE col1 > 800
    )
    INSERT INTO target_result(rid,val1,val2)
    SELECT rid,val1,val2 FROM cte_calc;

    WITH update_cte AS (
        SELECT rid FROM target_result WHERE val1 % 5 = 0
    )
    UPDATE target_result SET val1 = val1 + 10, update_flag = 1
    WHERE rid IN (SELECT rid FROM update_cte);

    WITH del_cte AS (
        SELECT rid FROM target_result WHERE val2 LIKE '%A%' LIMIT 15000
    )
    DELETE FROM target_result WHERE rid IN (SELECT rid FROM del_cte);

    v_lsn_after := pg_current_wal_lsn();
    v_wal_bytes := pg_wal_lsn_diff(v_lsn_after, v_lsn_before);

    -- Wait for statistics collector & refresh snapshot
    PERFORM pg_sleep(0.8);
    PERFORM pg_stat_clear_snapshot();

    SELECT coalesce(n_dead_tup,0) INTO v_target_dead FROM pg_stat_user_tables WHERE relname='target_result';
    SELECT coalesce(n_dead_tup,0) INTO v_mid_dead FROM pg_stat_user_tables WHERE relname='jsonb_mid';

    RAISE NOTICE 'CTE scheme finished, wal_bytes: %, target_dead: %, mid_dead: %',v_wal_bytes,v_target_dead,v_mid_dead;

    INSERT INTO test_report(
        test_case,wal_bytes,wal_records,target_dead_tup,mid_dead_tup,exec_ms
    ) VALUES (
        'CTE Scheme',
        v_wal_bytes,
        0,
        v_target_dead,
        v_mid_dead,
        extract(epoch FROM (clock_timestamp() - v_start_ts)) * 1000
    );
END $$;

SELECT * FROM test_report WHERE test_case = 'CTE Scheme' ORDER BY finish_time DESC LIMIT 1;

-- =============================================================================
-- Scheme 2: TEMP Table Approach ⚠️ Execute in a separate database session
-- =============================================================================
DO $$
DECLARE
    v_lsn_before pg_lsn;
    v_lsn_after pg_lsn;
    v_wal_bytes bigint := 0;

    v_target_dead bigint;
    v_mid_dead bigint;
    v_start_ts timestamp;
BEGIN
    TRUNCATE target_result;
    TRUNCATE jsonb_mid;
    CHECKPOINT;

    v_start_ts := clock_timestamp();
    v_lsn_before := pg_current_wal_lsn();

    RAISE NOTICE 'TEMP table scheme starts business processing';

    CREATE TEMP TABLE tmp_mid (
        rid bigint,
        val1 int,
        val2 text
    ) ON COMMIT DROP;

    INSERT INTO tmp_mid
    SELECT id AS rid, col1 * 3 AS val1, upper(col2) AS val2
    FROM src_data
    WHERE col1 > 800;

    UPDATE tmp_mid SET val1 = val1 + 10 WHERE val1 % 5 = 0;

    DELETE FROM tmp_mid
    WHERE ctid IN (
        SELECT ctid FROM tmp_mid WHERE val2 LIKE '%A%' LIMIT 15000
    );

    INSERT INTO target_result(rid,val1,val2)
    SELECT rid,val1,val2 FROM tmp_mid;

    v_lsn_after := pg_current_wal_lsn();
    v_wal_bytes := pg_wal_lsn_diff(v_lsn_after, v_lsn_before);

    PERFORM pg_sleep(0.8);
    PERFORM pg_stat_clear_snapshot();

    SELECT coalesce(n_dead_tup,0) INTO v_target_dead FROM pg_stat_user_tables WHERE relname='target_result';
    SELECT coalesce(n_dead_tup,0) INTO v_mid_dead FROM pg_stat_user_tables WHERE relname='jsonb_mid';

    RAISE NOTICE 'TEMP table scheme finished, wal_bytes: %, target_dead: %, mid_dead: %',v_wal_bytes,v_target_dead,v_mid_dead;

    INSERT INTO test_report(
        test_case,wal_bytes,wal_records,target_dead_tup,mid_dead_tup,exec_ms
    ) VALUES (
        'TEMP Relational Table Scheme',
        v_wal_bytes,
        0,
        v_target_dead,
        v_mid_dead,
        extract(epoch FROM (clock_timestamp() - v_start_ts)) * 1000
    );
END $$;

SELECT * FROM test_report WHERE test_case = 'TEMP Relational Table Scheme' ORDER BY finish_time DESC LIMIT 1;

-- =============================================================================
-- Scheme 3: Persistent Intermediate Table with JSONB
-- =============================================================================
DO $$
DECLARE
    v_lsn_before pg_lsn;
    v_lsn_after pg_lsn;
    v_wal_bytes bigint := 0;

    v_target_dead bigint;
    v_mid_dead bigint;
    v_start_ts timestamp;
BEGIN
    TRUNCATE target_result;
    TRUNCATE jsonb_mid;
    CHECKPOINT;

    v_start_ts := clock_timestamp();
    v_lsn_before := pg_current_wal_lsn();

    RAISE NOTICE 'Persistent JSONB intermediate table scheme starts business processing';

    INSERT INTO jsonb_mid(id,payload)
    SELECT
        id,
        jsonb_build_object(
            'rid', id,
            'val1', col1 * 3,
            'val2', upper(col2)
        )
    FROM src_data
    WHERE col1 > 800;

    UPDATE jsonb_mid
    SET payload = payload || jsonb_build_object('val1', (payload->>'val1')::int + 10)
    WHERE (payload->>'val1')::int % 5 = 0;

    DELETE FROM jsonb_mid
    WHERE ctid IN (
        SELECT ctid FROM jsonb_mid WHERE payload->>'val2' LIKE '%A%' LIMIT 15000
    );

    INSERT INTO target_result(rid,val1,val2)
    SELECT
        (payload->>'rid')::bigint,
        (payload->>'val1')::int,
        payload->>'val2'
    FROM jsonb_mid;

    v_lsn_after := pg_current_wal_lsn();
    v_wal_bytes := pg_wal_lsn_diff(v_lsn_after, v_lsn_before);

    PERFORM pg_sleep(0.8);
    PERFORM pg_stat_clear_snapshot();

    SELECT coalesce(n_dead_tup,0) INTO v_target_dead FROM pg_stat_user_tables WHERE relname='target_result';
    SELECT coalesce(n_dead_tup,0) INTO v_mid_dead FROM pg_stat_user_tables WHERE relname='jsonb_mid';

    RAISE NOTICE 'Persistent JSONB scheme finished, wal_bytes: %, target_dead: %, mid_dead: %',v_wal_bytes,v_target_dead,v_mid_dead;

    INSERT INTO test_report(
        test_case,wal_bytes,wal_records,target_dead_tup,mid_dead_tup,exec_ms
    ) VALUES (
        'Persistent JSONB Intermediate Table Scheme',
        v_wal_bytes,
        0,
        v_target_dead,
        v_mid_dead,
        extract(epoch FROM (clock_timestamp() - v_start_ts)) * 1000
    );
END $$;

SELECT * FROM test_report WHERE test_case = 'Persistent JSONB Intermediate Table Scheme' ORDER BY finish_time DESC LIMIT 1;

-- =============================================================================
-- Scheme 4: TEMP Table with JSONB (Non-persistent JSONB)
-- =============================================================================
DO $$
DECLARE
    v_lsn_before pg_lsn;
    v_lsn_after pg_lsn;
    v_wal_bytes bigint := 0;

    v_target_dead bigint;
    v_mid_dead bigint;
    v_start_ts timestamp;
BEGIN
    TRUNCATE target_result;
    TRUNCATE jsonb_mid;
    CHECKPOINT;

    v_start_ts := clock_timestamp();
    v_lsn_before := pg_current_wal_lsn();

    RAISE NOTICE 'TEMP table + JSONB (non-persistent) scheme starts business processing';

    -- Non-persistent: store jsonb in temp table, no permanent storage
    CREATE TEMP TABLE tmp_jsonb_mid (
        id bigint PRIMARY KEY,
        payload jsonb
    ) ON COMMIT DROP;

    -- Load temporary JSONB data (No WAL generation)
    INSERT INTO tmp_jsonb_mid(id,payload)
    SELECT
        id,
        jsonb_build_object(
            'rid', id,
            'val1', col1 * 3,
            'val2', upper(col2)
        )
    FROM src_data
    WHERE col1 > 800;

    -- Update JSONB field inside temp table (No WAL, but temporary dead tuples generated)
    UPDATE tmp_jsonb_mid
    SET payload = payload || jsonb_build_object('val1', (payload->>'val1')::int + 10)
    WHERE (payload->>'val1')::int % 5 = 0;

    -- Delete partial temporary JSONB records
    DELETE FROM tmp_jsonb_mid
    WHERE ctid IN (
        SELECT ctid FROM tmp_jsonb_mid WHERE payload->>'val2' LIKE '%A%' LIMIT 15000
    );

    -- Parse JSONB and write to permanent target table (Only step generating WAL)
    INSERT INTO target_result(rid,val1,val2)
    SELECT
        (payload->>'rid')::bigint,
        (payload->>'val1')::int,
        payload->>'val2'
    FROM tmp_jsonb_mid;

    v_lsn_after := pg_current_wal_lsn();
    v_wal_bytes := pg_wal_lsn_diff(v_lsn_after, v_lsn_before);

    -- Wait for statistics collector to refresh metrics
    PERFORM pg_sleep(1.0);
    PERFORM pg_stat_clear_snapshot();

    SELECT coalesce(n_dead_tup,0) INTO v_target_dead FROM pg_stat_user_tables WHERE relname='target_result';
    SELECT coalesce(n_dead_tup,0) INTO v_mid_dead FROM pg_stat_user_tables WHERE relname='jsonb_mid';

    RAISE NOTICE 'TEMP+JSONB scheme finished, wal_bytes: %, target_dead: %, mid_dead: %',v_wal_bytes,v_target_dead,v_mid_dead;

    INSERT INTO test_report(
        test_case,wal_bytes,wal_records,target_dead_tup,mid_dead_tup,exec_ms
    ) VALUES (
        'TEMP Table with JSONB (Non-persistent JSONB)',
        v_wal_bytes,
        0,
        v_target_dead,
        v_mid_dead,
        extract(epoch FROM (clock_timestamp() - v_start_ts)) * 1000
    );
END $$;

SELECT * FROM test_report WHERE test_case = 'TEMP Table with JSONB (Non-persistent JSONB)' ORDER BY finish_time DESC LIMIT 1;

-- =============================================================================
-- Scheme 5: In-memory jsonb_agg array, no intermediate tables created
-- =============================================================================
DO $$
DECLARE
    v_lsn_before pg_lsn;
    v_lsn_after pg_lsn;
    v_wal_bytes bigint := 0;

    v_target_dead bigint;
    v_mid_dead bigint;
    v_start_ts timestamp;

    v_big_json jsonb; -- In-memory JSONB array, no intermediate table
BEGIN
    TRUNCATE target_result;
    TRUNCATE jsonb_mid;
    CHECKPOINT;

    v_start_ts := clock_timestamp();
    v_lsn_before := pg_current_wal_lsn();

    RAISE NOTICE 'Scheme 5: In-memory jsonb_agg array (no intermediate tables) starts';

    -- Step1: Aggregate source data into single in-memory JSONB array, no physical table
    SELECT jsonb_agg(
        jsonb_build_object(
            'rid', id,
            'val1', col1 * 3,
            'val2', upper(col2)
        )
    ) INTO v_big_json
    FROM src_data
    WHERE col1 > 800;

    -- Simulate business update: unpack → calculate val1+10 → re-aggregate (simulate UPDATE logic)
    SELECT jsonb_agg(
        item || jsonb_build_object('val1', (item->>'val1')::int + 10)
    ) INTO v_big_json
    FROM jsonb_array_elements(v_big_json) AS item;

    -- Simulate DELETE: filter out 15000 matched rows
    WITH unpack AS (
        SELECT item, row_number() OVER() AS rn
        FROM jsonb_array_elements(v_big_json) item
    )
    SELECT jsonb_agg(item) INTO v_big_json
    FROM unpack
    WHERE NOT (rn <=15000 AND item->>'val2' LIKE '%A%');

    -- Final unpack array and insert into permanent target table (Only WAL-generating operation)
    INSERT INTO target_result(rid,val1,val2)
    SELECT
        (item->>'rid')::bigint,
        (item->>'val1')::int,
        item->>'val2'
    FROM jsonb_array_elements(v_big_json) AS item;

    v_lsn_after := pg_current_wal_lsn();
    v_wal_bytes := pg_wal_lsn_diff(v_lsn_after, v_lsn_before);

    PERFORM pg_sleep(1.0);
    PERFORM pg_stat_clear_snapshot();

    SELECT coalesce(n_dead_tup,0) INTO v_target_dead FROM pg_stat_user_tables WHERE relname='target_result';
    SELECT coalesce(n_dead_tup,0) INTO v_mid_dead FROM pg_stat_user_tables WHERE relname='jsonb_mid';

    RAISE NOTICE 'Scheme 5 finished, wal_bytes: %, target_dead: %, mid_dead: %',v_wal_bytes,v_target_dead,v_mid_dead;

    INSERT INTO test_report(
        test_case,wal_bytes,wal_records,target_dead_tup,mid_dead_tup,exec_ms
    ) VALUES (
        'In-memory jsonb_agg Array (No Intermediate Tables)',
        v_wal_bytes,
        0,
        v_target_dead,
        v_mid_dead,
        extract(epoch FROM (clock_timestamp() - v_start_ts)) * 1000
    );
END $$;

SELECT * FROM test_report WHERE test_case = 'In-memory jsonb_agg Array (No Intermediate Tables)' ORDER BY finish_time DESC LIMIT 1;

-- =============================================================================
-- Scheme 6: Batched Optimized TEMP+JSONB (Smooth MVCC dead tuple peak on temp table)
-- =============================================================================
DO $$
DECLARE
    v_lsn_before pg_lsn;
    v_lsn_after pg_lsn;
    v_wal_bytes bigint := 0;

    v_target_dead bigint;
    v_mid_dead bigint;
    v_start_ts timestamp;
    v_batch_size int := 20000;
    v_updated_cnt int;
    v_total_del_need int := 15000;
    v_del_done int := 0;
BEGIN
    TRUNCATE target_result;
    TRUNCATE jsonb_mid;
    CHECKPOINT;

    v_start_ts := clock_timestamp();
    v_lsn_before := pg_current_wal_lsn();

    RAISE NOTICE 'Scheme 6: Batched optimized TEMP+JSONB scheme starts business processing';

    CREATE TEMP TABLE tmp_jsonb_batch (
        id bigint PRIMARY KEY,
        payload jsonb,
        is_updated boolean DEFAULT false -- Flag to avoid repeated updates in loop
    ) ON COMMIT DROP;

    -- Load initial dataset
    INSERT INTO tmp_jsonb_batch(id,payload)
    SELECT
        id,
        jsonb_build_object(
            'rid', id,
            'val1', col1 * 3,
            'val2', upper(col2)
        )
    FROM src_data
    WHERE col1 > 800;

    -- Batched UPDATE: only update untouched rows to avoid infinite loop
    LOOP
        UPDATE tmp_jsonb_batch
        SET 
            payload = payload || jsonb_build_object('val1', (payload->>'val1')::int + 10),
            is_updated = true
        WHERE ctid IN (
            SELECT ctid FROM tmp_jsonb_batch 
            WHERE (payload->>'val1')::int % 5 = 0 AND is_updated = false
            LIMIT v_batch_size
        );
        GET DIAGNOSTICS v_updated_cnt = ROW_COUNT;
        EXIT WHEN v_updated_cnt = 0;
    END LOOP;

    -- Batched DELETE: delete up to 15000 rows directly, remove redundant marking UPDATE
    WHILE v_del_done < v_total_del_need LOOP
        DELETE FROM tmp_jsonb_batch
        WHERE ctid IN (
            SELECT ctid FROM tmp_jsonb_batch 
            WHERE payload->>'val2' LIKE '%A%'
            LIMIT LEAST(v_batch_size, v_total_del_need - v_del_done)
        );
        GET DIAGNOSTICS v_updated_cnt = ROW_COUNT;
        v_del_done := v_del_done + v_updated_cnt;
        EXIT WHEN v_updated_cnt = 0;
    END LOOP;

    -- Write final data to target table
    INSERT INTO target_result(rid,val1,val2)
    SELECT
        (payload->>'rid')::bigint,
        (payload->>'val1')::int,
        payload->>'val2'
    FROM tmp_jsonb_batch;

    v_lsn_after := pg_current_wal_lsn();
    v_wal_bytes := pg_wal_lsn_diff(v_lsn_after, v_lsn_before);

    PERFORM pg_sleep(1.0);
    PERFORM pg_stat_clear_snapshot();

    SELECT coalesce(n_dead_tup,0) INTO v_target_dead FROM pg_stat_user_tables WHERE relname='target_result';
    SELECT coalesce(n_dead_tup,0) INTO v_mid_dead FROM pg_stat_user_tables WHERE relname='jsonb_mid';

    RAISE NOTICE 'Scheme 6 finished, wal_bytes: %, target_dead: %, mid_dead: %',v_wal_bytes,v_target_dead,v_mid_dead;

    INSERT INTO test_report(
        test_case,wal_bytes,wal_records,target_dead_tup,mid_dead_tup,exec_ms
    ) VALUES (
        'Batched Optimized TEMP+JSONB (Control Temp Table Dead Tuple Peak)',
        v_wal_bytes,
        0,
        v_target_dead,
        v_mid_dead,
        extract(epoch FROM (clock_timestamp() - v_start_ts)) * 1000
    );
END $$;

SELECT * FROM test_report WHERE test_case = 'Batched Optimized TEMP+JSONB (Control Temp Table Dead Tuple Peak)' ORDER BY finish_time DESC LIMIT 1;

-- =============================================================================
-- Summary Query
-- =============================================================================
SELECT
    test_case,
    pg_size_pretty(wal_bytes::bigint) AS wal_total_size,
    target_dead_tup,
    mid_dead_tup,
    exec_ms,
    finish_time
FROM test_report
ORDER BY test_case;
