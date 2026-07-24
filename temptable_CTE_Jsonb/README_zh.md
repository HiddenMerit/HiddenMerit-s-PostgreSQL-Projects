# README_zh.md
# PostgreSQL 6种中间数据处理方案基准测试文档
## 1. 概述
本测试脚本实现 PostgreSQL 下**6套等价的数据转换流程**，用于对比不同中间载体模式的性能开销：CTE、普通字段临时表、永久JSONB中间表、临时JSONB表、内存jsonb_agg数组、分批优化临时JSONB表。

**所有方案统一业务逻辑**：
1. 过滤源数据：`src_data WHERE col1 > 800`
2. 更新满足 `val1 % 5 = 0` 的行（val1 值 +10）
3. 删除最多15000条满足 `val2 LIKE '%A%'` 的数据
4. 将最终数据集写入永久表 `target_result`

**测试数据规模**：源表300万行
**PostgreSQL 版本要求**：PostgreSQL 14+（依赖 `pg_current_wal_lsn()`、`pg_wal_lsn_diff()`）

## 2. 核心测试原理
### 2.1 WAL 观测方式
采用 **LSN差值法** 精确统计WAL写入总量：
```sql
v_lsn_before := pg_current_wal_lsn();
-- 执行业务逻辑
v_lsn_after := pg_current_wal_lsn();
v_wal_bytes := pg_wal_lsn_diff(v_lsn_after, v_lsn_before);
```
> 关键底层规则：PostgreSQL **临时表完全跳过WAL日志写入**。临时表上所有 INSERT/UPDATE/DELETE 不会产生WAL；**只有永久表写入操作才会生成WAL**。

### 2.2 死元组（Dead Tuple）与MVCC原理
PostgreSQL MVCC机制：
- `UPDATE`：原元组标记为死亡，插入新版本 → 产生死元组
- `DELETE`：原元组打上xmax标记 → 产生死元组
- **临时表同样会产生死元组**，但临时表有如下特性：
  1. 无法在 `pg_stat_user_tables` 观测内部死元组数量
  2. 会话断开后，所有数据与死元组全部自动回收
  3. Autovacuum后台进程不会扫描、清理临时表

> 重要限制：报表中 `target_dead_tup` / `mid_dead_tup` **仅能统计永久表死元组**。临时表内部产生的死元组无法通过系统视图采集。

### 2.3 统计采集器局限性
`pg_stat_user_tables` 依靠异步后台收集器更新指标，DML执行完成后指标不会立刻刷新。脚本通过 `pg_sleep()` + `pg_stat_clear_snapshot()` 缓解快照延迟问题，但极端情况下依然可能读到上一轮测试残留历史数值。

### 2.4 控制变量保证公平性
- 使用同一套源数据表 `src_data`
- 过滤、更新、删除规则完全一致
- 最终落地目标统一为 `target_result`
- 每轮测试执行前执行CHECKPOINT
- 使用临时表的方案必须新开独立数据库会话运行

## 3. 6套方案详细说明
### 方案1：CTE方案
所有计算流式执行，无中间存储；更新、删除直接作用于永久目标表。
- 中间载体：无
- 修改对象：永久表 `target_result`
- 特点：全部DML直接作用永久表，持续产生WAL。

### 方案2：TEMP普通字段临时表方案
中间数据集存放在会话级临时表，使用标准关系字段。
- 中间载体：`tmp_mid`（临时表，普通字段）
- WAL规则：临时表内部增改删 **不产生WAL**；仅最后插入目标表产生WAL。
- 特点：CPU开销最低，执行性能稳定，耗时最短；单次大事务会产生很高瞬时临时文件峰值。

### 方案3：永久JSONB中间表方案
中间数据持久化存入带jsonb字段的永久表。
- 中间载体：`jsonb_mid`（永久表）
- WAL规则：两层永久表写入（中间表+目标表），WAL总量最高。
- 特点：JSONB更新会生成大量持久死元组，加重autovacuum压力；中间数据可以跨会话共享。

### 方案4：TEMP临时表+JSONB（非持久JSONB）
中间数据存入带有jsonb字段的临时表，中间操作不生成WAL。
- 中间载体：`tmp_jsonb_mid`（带jsonb字段临时表）
- 特点：WAL开销和普通临时表接近；JSON序列化/反序列化带来额外CPU消耗；一次性大批量更新会形成很高临时死元组瞬时峰值。

### 方案5：内存jsonb_agg聚合数组（无任何中间表）
筛选数据全部聚合为PL/pgSQL内部单个超大jsonb变量；依靠拆包、重新聚合实现数据转换，不创建任何物理表。
- 中间载体：PL/pgSQL内存jsonb变量
- 特点：理论WAL最低；反复解析、重建JSON数组带来巨大CPU开销；work_mem不足时会溢出大量临时文件。

### 方案6：分批优化TEMP+JSONB
在方案4基础上，将单次超大事务UPDATE/DELETE拆分为小批次循环执行，削平瞬时资源峰值。
- 中间载体：`tmp_jsonb_batch`（带jsonb字段临时表）
- 特点：总生成死元组总量和方案4一致，但瞬时IO压力被平滑；循环调度带来额外开销，执行耗时高于方案4。

## 4. 预期测试结果
### 4.1 WAL体积排序（从小到大）
方案5（内存jsonb_agg） < 方案2 ≈ 方案4 ≈ 方案6（临时表家族） < 方案1（CTE） < 方案3（永久JSONB）

> 原理说明：
所有基于临时表的方案，仅最后写入target_result产生WAL，因此WAL大小接近；方案3需要写入两层永久表，WAL总量最大。

### 4.2 执行耗时趋势（理论预判）
方案2（普通临时表） < 方案4 < 方案1 < 方案6 < 方案3 < 方案5
- 方案2：无JSON编解码开销，速度最快
- 方案6：分批循环带来额外延迟，慢于方案4
- 方案5：大量JSON拆包重组，耗时最长

### 4.3 死元组与Vacuum压力
1. **方案3**：真空压力最大。`jsonb_mid` 持续累积持久死元组，依赖autovacuum清理。
2. **方案1**：仅target_result产生死元组，压力中等。
3. **方案2 / 4 / 6**：死元组仅存在临时表内，会话结束自动释放，不影响全局真空。
4. **方案5**：无中间表，仅target_result产生死元组。

### 4.4 瞬时资源峰值差异
- 方案4：瞬时临时目录IO峰值极高（单次大事务）
- 方案6：资源峰值被平滑，适合高并发场景
- 方案5：CPU持续高负载，存在内存溢出风险

## 5. 运行步骤
1. **仅执行一次初始化脚本**
```sql
-- 0. Initialization (Execute once only)
DROP TABLE IF EXISTS src_data;
DROP TABLE IF EXISTS target_result;
DROP TABLE IF EXISTS jsonb_mid;
DROP TABLE IF EXISTS test_report;
-- 完整初始化SQL见测试脚本
```
2. 按顺序依次执行各个方案：
   - 方案1、3、5可在同一个会话运行
   - **方案2、4、6必须新开独立数据库会话执行**（pgAdmin新建查询窗口 / 新建psql连接）
3. 全部方案跑完后，执行汇总查询查看对比报表
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

## 6. 已知限制与注意事项
1. 临时表内部死元组**无法通过系统视图查询**，不能量化数量，只能依靠监控临时目录磁盘IO判断瞬时压力。
2. 测试期间尽量关闭后台任务（自动vacuum、备份、长事务），避免干扰WAL统计与耗时采集。
3. 如果观测到死元组数值异常残留，可将脚本内 `pg_sleep()` 时长调整为2秒，给统计收集器充足刷新时间。
4. `wal_records` 字段预留，无法通过LSN方式获取，当前版本统一填充0。

## 7.工程落地建议
1. 大批量ETL场景：优先选择**方案2（普通字段临时表）**，在耗时、CPU、WAL开销上综合最优。
2. 数据转换流水线尽量避免使用方案3（永久JSONB中间表），WAL写入量大且真空负担沉重。
3. 高并发、需要半结构化JSON载体时，选择方案6（分批TEMP+JSONB）平滑瞬时压力。
4. **百万级数据不推荐方案5（内存jsonb_agg）**，CPU损耗极高，容易触发临时文件颠簸。
