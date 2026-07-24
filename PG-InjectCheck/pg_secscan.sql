-- =====================================================
-- Create scanning function
-- =====================================================
CREATE OR REPLACE FUNCTION scan_sql_injection_risk(
    p_target_schema TEXT DEFAULT NULL,
    p_include_commented BOOLEAN DEFAULT FALSE,
    p_include_extension BOOLEAN DEFAULT FALSE
)
RETURNS TABLE(
    function_name TEXT,
    function_oid OID,
    schema_name TEXT,
    line_number INT,
    risky_line TEXT,
    risk_type TEXT,
    description TEXT,
    risk_level TEXT
) AS $function$
DECLARE
    func_record RECORD;
    func_source TEXT;
    line_text TEXT;
    is_commented BOOLEAN;
    already_reported TEXT[];
    lines_array TEXT[];
    i INT;
    v_function_name TEXT;
    v_schema_name TEXT;
    v_function_oid OID;
BEGIN
    -- Initialize array
    already_reported := ARRAY[]::TEXT[];
    
    -- Iterate all PL/pgSQL functions in target schema
    FOR func_record IN
        SELECT 
            p.oid,
            n.nspname || '.' || p.proname AS full_name,
            n.nspname AS schema_name,
            p.proname AS func_name,
            p.oid AS func_oid,
            pg_get_functiondef(p.oid) AS definition
        FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE (p_target_schema IS NULL OR n.nspname = p_target_schema)
          AND n.nspname NOT IN ('pg_catalog', 'information_schema')
          AND (p_include_extension OR n.nspname NOT IN ('repack', 'pg_repack', 'dblink', 'postgres_fdw', 'pg_stat_statements'))
          AND p.prolang = (SELECT oid FROM pg_language WHERE lanname = 'plpgsql')
          AND p.prokind IN ('f', 'p')
          AND p.proname NOT IN ('scan_sql_injection_risk')
          AND p.proname NOT LIKE '%_old'
          AND p.proname NOT LIKE '%_backup'
    LOOP
        -- Skip extension schemas
        IF NOT p_include_extension AND func_record.schema_name IN ('repack', 'pg_repack') THEN
            CONTINUE;
        END IF;
        
        -- Get function source code
        func_source := func_record.definition;
        IF func_source IS NULL OR func_source = '' THEN
            CONTINUE;
        END IF;
        
        -- Split source into lines using regexp_split_to_array
        BEGIN
            lines_array := regexp_split_to_array(func_source, E'\n');
        EXCEPTION WHEN OTHERS THEN
            CONTINUE;
        END;
        
        -- Check empty array
        IF lines_array IS NULL OR array_length(lines_array, 1) IS NULL THEN
            CONTINUE;
        END IF;
        
        -- Analyze line by line
        FOR i IN 1 .. array_length(lines_array, 1) LOOP
            line_text := COALESCE(lines_array[i], '');
            
            -- Skip empty lines
            IF TRIM(line_text) = '' THEN
                CONTINUE;
            END IF;
            
            -- Check if line is comment
            is_commented := (TRIM(line_text) ~ '^--');
            IF is_commented AND NOT p_include_commented THEN
                CONTINUE;
            END IF;
            
            -- Only process lines containing target keywords
            IF line_text ~* '(EXECUTE|COPY\s+.*PROGRAM|CREATE\s+DIRECTORY|DROP\s+.*IF|CREATE\s+TABLE\s+\S+\s+AS)' THEN
                
                -- Deduplication check
                DECLARE
                    unique_key TEXT;
                    already_exists BOOLEAN;
                BEGIN
                    unique_key := func_record.full_name || '_' || i;
                    already_exists := FALSE;
                    
                    IF array_length(already_reported, 1) IS NOT NULL THEN
                        FOR idx IN 1 .. array_length(already_reported, 1) LOOP
                            IF already_reported[idx] = unique_key THEN
                                already_exists := TRUE;
                                EXIT;
                            END IF;
                        END LOOP;
                    END IF;
                    
                    IF NOT already_exists THEN
                        -- Risk 1: Command injection via COPY FROM PROGRAM with variable concatenation
                        IF line_text ~* 'COPY\s+.*FROM\s+PROGRAM.*\|\|' 
                           AND line_text !~* 'USING\s+' 
                           AND NOT is_commented THEN
                            
                            function_name := func_record.full_name;
                            function_oid := func_record.func_oid;
                            schema_name := func_record.schema_name;
                            line_number := i;
                            risky_line := TRIM(line_text);
                            risk_type := 'COMMAND_INJECTION';
                            description := '[CRITICAL] Variable concatenation found in COPY FROM PROGRAM, may lead to OS command injection!';
                            risk_level := 'CRITICAL';
                            RETURN NEXT;
                            already_reported := array_append(already_reported, unique_key);
                            CONTINUE;
                        END IF;
                        
                        -- Risk 2: Command injection via COPY TO PROGRAM with variable concatenation
                        IF line_text ~* 'COPY\s+.*TO\s+PROGRAM.*\|\|' 
                           AND line_text !~* 'USING\s+'
                           AND NOT is_commented THEN
                            
                            function_name := func_record.full_name;
                            function_oid := func_record.func_oid;
                            schema_name := func_record.schema_name;
                            line_number := i;
                            risky_line := TRIM(line_text);
                            risk_type := 'COMMAND_INJECTION';
                            description := '[CRITICAL] Variable concatenation found in COPY TO PROGRAM, may lead to OS command injection!';
                            risk_level := 'CRITICAL';
                            RETURN NEXT;
                            already_reported := array_append(already_reported, unique_key);
                            CONTINUE;
                        END IF;
                        
                        -- Risk 3: EXECUTE with || without USING (exclude commented lines)
                        IF line_text ~* 'EXECUTE\s+.*\|\|' 
                           AND line_text !~* 'USING\s+' 
                           AND line_text !~* 'format\(.*%I' 
                           AND line_text !~* 'quote_ident\(' 
                           AND NOT is_commented THEN
                            
                            function_name := func_record.full_name;
                            function_oid := func_record.func_oid;
                            schema_name := func_record.schema_name;
                            line_number := i;
                            risky_line := TRIM(line_text);
                            risk_type := 'SQL_INJECTION';
                            description := '[HIGH] SQL concatenated with || inside EXECUTE without USING clause, SQL injection risk exists.';
                            risk_level := 'HIGH';
                            RETURN NEXT;
                            already_reported := array_append(already_reported, unique_key);
                            CONTINUE;
                        END IF;
                        
                        -- Risk 4: Dynamic DDL without quote_ident
                        IF line_text ~* '(CREATE\s+TABLE|CREATE\s+INDEX|ALTER\s+TABLE|DROP\s+TABLE).*\|\|'
                           AND line_text !~* 'quote_ident\(|format\(.*%I'
                           AND NOT is_commented THEN
                            
                            function_name := func_record.full_name;
                            function_oid := func_record.func_oid;
                            schema_name := func_record.schema_name;
                            line_number := i;
                            risky_line := TRIM(line_text);
                            risk_type := 'DDL_INJECTION';
                            description := '[HIGH] Identifiers concatenated directly in dynamic DDL. Use format(''%%I'') or quote_ident().';
                            risk_level := 'HIGH';
                            RETURN NEXT;
                            already_reported := array_append(already_reported, unique_key);
                            CONTINUE;
                        END IF;
                        
                        -- Risk 5: Usage of quote_literal
                        IF line_text ~* 'quote_literal\(' 
                           AND line_text ~* 'EXECUTE' 
                           AND line_text !~* 'USING\s+'
                           AND NOT is_commented THEN
                            
                            function_name := func_record.full_name;
                            function_oid := func_record.func_oid;
                            schema_name := func_record.schema_name;
                            line_number := i;
                            risky_line := TRIM(line_text);
                            risk_type := 'WEAK_ESCAPE';
                            description := '[MEDIUM] quote_literal() provides insufficient protection. USING clause is recommended.';
                            risk_level := 'MEDIUM';
                            RETURN NEXT;
                            already_reported := array_append(already_reported, unique_key);
                            CONTINUE;
                        END IF;
                    END IF;
                END;
            END IF;
        END LOOP;
    END LOOP;

END;
$function$ LANGUAGE plpgsql;


-- Create view: Critical risks
CREATE OR REPLACE VIEW v_critical_sql_injection AS
SELECT 
    function_name,
    schema_name,
    line_number,
    risky_line,
    risk_type,
    description,
    risk_level
FROM scan_sql_injection_risk()
WHERE risk_level = 'CRITICAL'
ORDER BY function_name, line_number;


-- Create view: High risks
CREATE OR REPLACE VIEW v_high_sql_injection AS
SELECT 
    function_name,
    schema_name,
    line_number,
    risky_line,
    risk_type,
    description,
    risk_level
FROM scan_sql_injection_risk()
WHERE risk_level = 'HIGH'
ORDER BY function_name, line_number;


-- Create view: All risks
CREATE OR REPLACE VIEW v_all_sql_injection_risks AS
SELECT 
    function_name,
    schema_name,
    line_number,
    risky_line,
    risk_type,
    description,
    risk_level
FROM scan_sql_injection_risk()
ORDER BY 
    CASE risk_level
        WHEN 'CRITICAL' THEN 1
        WHEN 'HIGH' THEN 2
        WHEN 'MEDIUM' THEN 3
        ELSE 4
    END,
    function_name,
    line_number;


CREATE OR REPLACE FUNCTION get_risk_summary(p_target_schema TEXT DEFAULT NULL)
RETURNS TABLE(
    schema_name TEXT,
    critical_count BIGINT,
    high_count BIGINT,
    medium_count BIGINT,
    total_count BIGINT
) AS $function$
BEGIN
    RETURN QUERY
    SELECT 
        COALESCE(t.schema_name, 'TOTAL') AS schema_name,
        SUM(CASE WHEN t.risk_level = 'CRITICAL' THEN 1 ELSE 0 END)::BIGINT AS critical_count,
        SUM(CASE WHEN t.risk_level = 'HIGH' THEN 1 ELSE 0 END)::BIGINT AS high_count,
        SUM(CASE WHEN t.risk_level = 'MEDIUM' THEN 1 ELSE 0 END)::BIGINT AS medium_count,
        COUNT(*)::BIGINT AS total_count
    FROM (
        SELECT 
            srs.schema_name,
            srs.risk_level
        FROM scan_sql_injection_risk(p_target_schema, FALSE, FALSE) srs
    ) t
    GROUP BY ROLLUP(t.schema_name)
    ORDER BY 
        CASE WHEN COALESCE(t.schema_name, 'TOTAL') = 'TOTAL' THEN 999 ELSE 1 END,
        t.schema_name;
END;
$function$ LANGUAGE plpgsql;



-- 1. Test basic scan
SELECT * FROM scan_sql_injection_risk() LIMIT 5;

-- 2. View critical risks
SELECT * FROM v_critical_sql_injection;

-- 3. View high risks
SELECT * FROM v_high_sql_injection;

-- 4. View all risks
SELECT * FROM v_all_sql_injection_risks LIMIT 100;

-- 5. Test risk summary (should work normally after fixes)
SELECT * FROM get_risk_summary();

-- 6. Statistics only for public schema
SELECT * FROM get_risk_summary('public');

-- 7. Aggregate statistics by risk level
SELECT 
    risk_level,
    COUNT(*) as count,
    STRING_AGG(DISTINCT schema_name, ', ' ORDER BY schema_name) as schemas
FROM scan_sql_injection_risk()
GROUP BY risk_level
ORDER BY 
    CASE risk_level
        WHEN 'CRITICAL' THEN 1
        WHEN 'HIGH' THEN 2
        WHEN 'MEDIUM' THEN 3
        ELSE 4
    END;
