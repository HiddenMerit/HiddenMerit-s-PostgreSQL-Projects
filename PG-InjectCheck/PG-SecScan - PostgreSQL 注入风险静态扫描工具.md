# PG\-SecScan \- PostgreSQL 注入风险静态扫描工具

## 📖 项目介绍

**PG\-SecScan** 是一款基于原生 PL/pgSQL 实现的 PostgreSQL 数据库静态安全审计工具，无需依赖第三方组件、无需安装客户端，直接运行于数据库内部。

工具专门用于扫描数据库自定义存储函数中存在的**动态 SQL 注入、OS 命令注入、DDL 标识符注入、弱转义防护**等安全风险，适配数据库日常安全巡检、上线代码审计、漏洞自查、合规验收场景。

区别于传统外部扫描工具，本项目直接读取数据库系统字典解析函数源码，精准识别编码层风险漏洞，是轻量、高效、无侵入的数据库安全自检方案。

## ✨ 核心特性

- **纯数据库原生实现**：全部逻辑基于 PL/pgSQL，跨系统、无依赖、部署零成本

- **全覆盖风险检测**：支持命令注入、SQL注入、DDL注入、弱防护四类核心风险

- **结构化结果输出**：自带视图与统计函数，支持精细化筛选、风险汇总

- **智能去重机制**：避免同一代码行重复告警，保证结果精准

- **灵活扫描策略**：支持指定 Schema、是否扫描注释代码、是否扫描扩展函数

- **分级风险判定**：严格区分 严重/高危/中危 三级风险，适配企业安全评级规范

## ⚙️ 代码工作原理（核心机制）

本工具为**静态源码正则审计**工具，核心执行逻辑完全透明，流程如下：

### 1\. 数据采集阶段

通过 PostgreSQL 系统字典表 `pg_proc`、`pg_namespace` 遍历数据库内所有自定义 PL/pgSQL 函数，自动过滤系统库、内置扩展库、备份/废弃函数，保证扫描范围精准有效。

### 2\. 源码解析阶段

通过内置函数 `pg_get_functiondef()` 获取每一个函数的完整源代码，将源码按换行符切割为单行数组，实现**逐行精准检测**。

### 3\. 规则匹配检测阶段

对每一行代码进行清洗（过滤空行、可配置过滤注释行），通过正则表达式匹配高危编码特征，精准识别不安全的动态拼接写法。

### 4\. 去重与结果封装

通过「函数名\+行号」唯一键做全局去重，杜绝重复告警；对命中规则的代码行标记风险类型、风险等级、详细描述，结构化返回审计结果。

### 5\. 数据聚合统计

内置专属视图与统计函数，支持按风险等级、按 Schema 维度汇总数据，快速输出数据库整体安全态势。

## 🛡️ 风险检测规则明细

|风险类型|检测规则|风险等级|风险说明|
|---|---|---|---|
|COMMAND\_INJECTION|COPY FROM PROGRAM 变量拼接（\|\|）且无 USING|CRITICAL 严重|可被利用执行任意操作系统命令，危害极高|
|COMMAND\_INJECTION|COPY TO PROGRAM 变量拼接（\|\|）且无 USING|CRITICAL 严重|可被利用执行任意操作系统命令，危害极高|
|SQL\_INJECTION|EXECUTE 动态SQL拼接变量，无 USING、无标识符转义|HIGH 高危|存在标准SQL注入漏洞，可篡改、查询、删除业务数据|
|DDL\_INJECTION|动态DDL语句拼接标识符，未使用 quote\_ident / format %I|HIGH 高危|可篡改表结构、索引结构，造成数据库结构被恶意篡改|
|WEAK\_ESCAPE|仅使用 quote\_literal 防护动态SQL，无USING参数化|MEDIUM 中危|防护手段薄弱，存在被绕过注入的风险，不符合安全规范|

## 📊 风险等级定义

- **CRITICAL（严重）**：可触发操作系统命令注入，完全接管服务器权限，需立即修复

- **HIGH（高危）**：可触发SQL/DDL注入，泄露、篡改核心业务数据与库表结构

- **MEDIUM（中危）**：安全防护不规范，存在潜在注入风险，需优化代码写法

## 📁 项目文件结构

```Plain Text
PG-SecScan/
├── pg_secscan.sql        # 核心源码（扫描函数+视图+统计函数）
├── README.md             # 中文使用文档（当前文件）
└── README_en.md          # 英文使用文档（可选）
```

## 💻 部署与安装

### 环境要求

- PostgreSQL 9\.6 及以上全系列版本

- 执行账号需具备系统字典表查询权限（建议管理员/超级用户）

### 安装方式

直接在目标数据库执行 SQL 脚本即可完成部署：

```Plain Text
\i pg_secscan.sql
```

部署后自动生成：核心扫描函数、三类风险视图、风险统计汇总函数，无需额外配置。

## 🚀 使用示例

```Plain Text
-- 1. 全局全量扫描（默认忽略注释、忽略扩展库）
SELECT * FROM scan_sql_injection_risk() LIMIT 5;

-- 2. 仅扫描 public 业务模式
SELECT * FROM scan_sql_injection_risk('public');

-- 3. 扫描包含注释内的风险代码
SELECT * FROM scan_sql_injection_risk('public', true);

-- 4. 查询所有严重风险漏洞
SELECT * FROM v_critical_sql_injection;

-- 5. 查询所有高危风险漏洞
SELECT * FROM v_high_sql_injection;

-- 6. 查看全量风险汇总（按风险等级优先级排序）
SELECT * FROM v_all_sql_injection_risks LIMIT 100;

-- 7. 全局风险统计汇总
SELECT * FROM get_risk_summary();

-- 8. 指定Schema风险统计
SELECT * FROM get_risk_summary('public');

-- 9. 按风险级别分组统计
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

## 📋 返回字段说明

|字段名|字段说明|
|---|---|
|function\_name|风险函数全名（schema\.函数名）|
|function\_oid|函数数据库唯一OID标识|
|schema\_name|函数所属模式名|
|line\_number|风险代码所在源码行号|
|risky\_line|命中风险规则的原始代码行|
|risk\_type|风险类型枚举（命令注入/SQL注入/DDL注入/弱防护）|
|description|风险详细描述与问题说明|
|risk\_level|风险等级：CRITICAL / HIGH / MEDIUM|

## ✅ 预期扫描结果

- **有结果输出**：对应代码行存在不安全拼接写法，存在真实安全风险，需人工复核并修复

- **无结果输出**：未扫描到匹配风险特征的代码，代码写法符合基础安全规范

- **结果说明**：本工具为静态代码规则扫描，存在极低概率误报/漏报，需结合人工审计确认

## 🔧 通用修复规范

1. 动态 EXECUTE 语句**强制使用 USING 参数化**，禁止直接拼接变量

2. 动态表名、字段名等标识符，统一使用 `quote_ident()` 或 `format('%I')` 转义

3. 禁止在 COPY PROGRAM 语句中拼接外部可控变量

4. 废弃 quote\_literal 单一防护写法，优先使用官方参数化方案

## ⚠️ 局限性与注意事项

- 仅支持 **PL/pgSQL** 函数扫描，不支持 Python/Java/SQL 等其他语言函数

- 基于静态正则匹配，复杂多行拼接、变量预组装SQL场景可能存在漏报

- 仅检测**代码写法风险**，无法判断运行时参数是否可控，需人工业务校验

- 默认过滤系统库、扩展库、备份废弃函数，可通过参数手动开启扫描

- 本工具为辅助审计工具，不可完全替代人工安全渗透与代码审计

## 📄 开源协议（Business Source License 1\.1）

**PG\-SecScan** 基于 **Business Source License 1\.1 \(BSL 1\.1\)** 开源授权。

### 授权说明

- **免费使用范围**：个人学习、非商业项目、企业内部安全自查、私有部署审计场景，完全免费、无功能限制

- **禁止行为**：禁止将本项目代码、工具整体或二次封装后用于**商业售卖、SaaS商业化服务、商用安全产品集成**

- **协议转换**：本项目将在发布后固定周期自动转换为 MIT 开源协议，永久开放自由使用

- **免责声明**：本工具仅用于安全自查审计，使用者因违规使用、二次篡改造成的一切风险与作者无关

完整协议文本：[Business Source License 1\.1 官方协议](https://mariadb.com/docs/legal/business-source-license-1-1/)

## 📮 结语

PG\-SecScan 致力于为 PostgreSQL 数据库提供轻量化、零成本、高效率的代码安全审计能力，帮助开发者与运维人员快速发现存储层注入漏洞，筑牢数据库安全防线。

> （注：部分内容可能由 AI 生成）
