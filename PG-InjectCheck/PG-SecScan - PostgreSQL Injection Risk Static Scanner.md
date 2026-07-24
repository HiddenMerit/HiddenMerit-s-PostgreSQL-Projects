# PG\-SecScan \- PostgreSQL Injection Risk Static Scanner

## 📖 Project Overview

**PG\-SecScan** is a native PL/pgSQL\-based static security auditing tool for PostgreSQL databases\. It requires no third\-party dependencies or client installation and runs entirely inside the database\.

This tool automatically detects security risks in custom stored functions, including **dynamic SQL injection, OS command injection, DDL identifier injection, and weak escape protection**\. It is widely applicable for daily database security inspection, pre\-release code auditing, vulnerability self\-checking, and compliance verification\.

Unlike traditional external scanning tools, PG\-SecScan directly parses function source code through PostgreSQL system catalogs to accurately identify coding\-level vulnerabilities, providing a lightweight, efficient, and non\-intrusive database security self\-inspection solution\.

## ✨ Core Features

- **Pure Database Native Implementation**: All logic is written in PL/pgSQL, cross\-platform, dependency\-free, and zero\-cost deployment

- **Full\-Coverage Risk Detection**: Supports four core risk types: command injection, SQL injection, DDL injection, and weak protection

- **Structured Result Output**: Built\-in views and statistical functions for precise filtering and risk aggregation

- **Intelligent Deduplication Mechanism**: Avoid duplicate alerts for the same code line to ensure accurate results

- **Flexible Scanning Strategy**: Supports specified schema scanning, commented code scanning, and extension function scanning

- **Hierarchical Risk Evaluation**: Strictly classifies risks into Critical / High / Medium levels, compliant with enterprise security rating standards

## ⚙️ Core Working Principle

PG\-SecScan is a **static source code regex auditing tool** with transparent and standardized execution logic:

### 1\. Data Collection

Traverses all custom PL/pgSQL functions in the database via system catalogs `pg_proc` and `pg_namespace`\. Automatically filters system schemas, built\-in extensions, backup and deprecated functions to ensure accurate scanning scope\.

### 2\. Source Code Parsing

Retrieves the complete source code of each function using the built\-in`pg_get_functiondef()` function\. Splits full source code into single\-line arrays to achieve **line\-by\-line precise detection**\.

### 3\. Rule Matching \& Detection

Cleans each code line \(skips empty lines, configurable comment filtering\)\. Matches high\-risk coding patterns through regular expressions to identify unsafe dynamic concatenation behaviors\.

### 4\. Deduplication \& Result Encapsulation

Uses the unique key of `function name + line number` for global deduplication to eliminate repeated alerts\. Tags matched code lines with risk type, risk level, and detailed descriptions to return structured audit results\.

### 5\. Data Aggregation \& Statistics

Provides dedicated built\-in views and statistical functions to aggregate risks by severity and schema, quickly presenting the overall database security status\.

## 🛡️ Detection Rules Details

|**Risk Type**|**Detection Rule**|**Risk Level**|**Description**|
|---|---|---|---|
|COMMAND\_INJECTION|COPY FROM PROGRAM concatenation with \|\| without USING clause|CRITICAL|Exploitable to execute arbitrary OS commands with extremely high hazard|
|COMMAND\_INJECTION|COPY TO PROGRAM concatenation with \|\| without USING clause|CRITICAL|Exploitable to execute arbitrary OS commands with extremely high hazard|
|SQL\_INJECTION|Dynamic SQL concatenation in EXECUTE without USING or identifier escaping|HIGH|Standard SQL injection vulnerability allows data query, tampering and deletion|
|DDL\_INJECTION|Dynamic DDL identifier concatenation without quote\_ident / format %I|HIGH|May cause malicious modification of database table and index structures|
|WEAK\_ESCAPE|Dynamic SQL protected only by quote\_literal without USING parameterization|MEDIUM|Insufficient protection, vulnerable to injection bypass, non\-compliant with security specifications|

## 📊 Risk Level Definition

- **CRITICAL**: OS command injection executable, full server permission takeover risk, immediate remediation required

- **HIGH**: SQL/DDL injection exploitable, leading to core business data leakage and structure tampering

- **MEDIUM**: Non\-standard security protection with potential injection risks, code optimization recommended

## 📁 Project Structure

```Plain Text
PG-SecScan/
├── pg_secscan.sql        # Core source code (scanner + views + statistics function)
├── README.md             # English documentation (current file)
└── README_zh.md          # Chinese documentation
```

## 💻 Deployment \& Installation

### Environment Requirements

- PostgreSQL 9\.6 and above all versions

- Execution account requires system catalog query privileges \(admin / superuser recommended\)

### Installation Steps

Execute the SQL script directly in the target database for one\-click deployment:

```Plain Text
\i pg_secscan.sql
```

After deployment, the core scanning function, three risk views, and risk statistics function will be automatically generated with no additional configuration required\.

## 🚀 Usage Examples

```Plain Text
-- 1. Full database scan (ignore comments and extensions by default)
SELECT * FROM scan_sql_injection_risk() LIMIT 5;

-- 2. Scan only public schema
SELECT * FROM scan_sql_injection_risk('public');

-- 3. Include commented code in scanning
SELECT * FROM scan_sql_injection_risk('public', true);

-- 4. Query all critical vulnerabilities
SELECT * FROM v_critical_sql_injection;

-- 5. Query all high-risk vulnerabilities
SELECT * FROM v_high_sql_injection;

-- 6. View full risk summary (sorted by risk priority)
SELECT * FROM v_all_sql_injection_risks LIMIT 100;

-- 7. Global risk statistics summary
SELECT * FROM get_risk_summary();

-- 8. Risk statistics for specified schema
SELECT * FROM get_risk_summary('public');

-- 9. Group statistics by risk level
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
```

## 📋 Output Field Description

|**Field Name**|**Description**|
|---|---|
|function\_name|Full qualified function name \(schema\.function\)|
|function\_oid|Unique database object ID of the function|
|schema\_name|Schema name where the function resides|
|line\_number|Source code line number of the risk point|
|risky\_line|Original code line matching risk rules|
|risk\_type|Risk category enum \(Command / SQL / DDL Injection / Weak Escape\)|
|description|Detailed risk explanation and problem description|
|risk\_level|Risk severity: CRITICAL / HIGH / MEDIUM|

## ✅ Expected Scan Results

- **Result returned**: The corresponding code line contains unsafe concatenation logic with real security risks, requiring manual review and remediation

- **Empty result**: No matched risky code patterns detected, the code complies with basic security specifications

- **Result Note**: This tool performs static rule\-based scanning with extremely low probability of false positives/negatives, manual audit verification is required

## 🔧 General Remediation Standards

1. Use **USING parameterization** for all dynamic EXECUTE statements, prohibit direct variable concatenation

2. Escape dynamic identifiers \(table/column names\) via `quote_ident()` or `format('%I')`

3. Prohibit concatenating external controllable variables in COPY PROGRAM statements

4. Abandon single quote\_literal protection, prioritize official parameterization solutions

## ⚠️ Limitations \& Notes

- Only supports **PL/pgSQL** function scanning, does not support Python, Java, pure SQL and other procedural languages

- Based on static regular matching, may miss risks in complex multi\-line concatenation and pre\-assembled SQL variables

- Only detects **coding specification risks**, cannot judge runtime parameter controllability, requires business manual verification

- System schemas, extension libraries and backup deprecated functions are filtered by default, can be manually enabled via parameters

- This tool is an auxiliary auditing tool and cannot completely replace manual security penetration and code auditing

## 📄 Open Source License \(Business Source License 1\.1\)

**PG\-SecScan** is licensed under **Business Source License 1\.1 \(BSL 1\.1\)**\.

### License Terms

- **Free Usage Scope**: Personal learning, non\-commercial projects, enterprise internal security self\-inspection, private deployment auditing — fully free with no functional restrictions

- **Prohibited Behaviors**: It is forbidden to sell, commercialize, or secondary package this tool for SaaS commercial services or commercial security product integration

- **License Conversion**: This project will automatically convert to the MIT open\-source license after a fixed cycle, achieving permanent open free usage

- **Disclaimer**: This tool is only for security self\-audit\. The author assumes no responsibility for any risks caused by illegal use or secondary modification by users

Full license text: [Business Source License 1\.1 Official Document](https://mariadb.com/docs/legal/business-source-license-1-1/)

## 📮 Closing

PG\-SecScan aims to provide lightweight, zero\-cost, and high\-efficiency code security auditing capabilities for PostgreSQL databases, helping developers and operation \& maintenance personnel quickly discover injection vulnerabilities at the storage layer and build a solid database security defense line\.

> （注：部分内容可能由 AI 生成）
