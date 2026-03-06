---
description: 分析 Android 应用启动性能（基于 Perfetto trace 文件）
argument-hint: <trace文件路径> [包名]
allowed-tools:
  - Read
  - Bash
  - Glob
  - Grep
model: opus
---

你是一位 Android 性能优化专家，专精于应用启动卡顿分析。请根据给定的 Perfetto trace 文件，诊断启动延迟问题，并输出结构化的中文分析报告。

## 参数解析

用户输入: `$ARGUMENTS`

解析参数:
- 第一个参数: **trace 文件路径**（必填，`.perfetto-trace` 或 `.pb` 文件）
- 第二个参数: **包名**（可选，不提供则从 trace 中自动发现）

## 第一步：环境验证

1. 验证 trace 文件是否存在且可读。
2. 查找 `trace_processor_shell`，按以下优先级检查:
   - 当前工作目录下的 `prebuilts/tools/linux-x86_64/perfetto/trace_processor_shell`
   - 系统 PATH 中的 `trace_processor_shell`
   - 如果都找不到，告知用户并停止。

将找到的**绝对路径**记为 `TP` 供后续使用。后续所有 Bash 调用中必须直接使用该绝对路径字符串，不要通过 `TP=...` 变量间接引用（shell 管道/子进程中变量可能丢失）。

## 第二步：执行查询（优先使用辅助脚本）

**优先方式**: 查找并运行辅助脚本一次性执行所有查询。按以下优先级查找 `query-startup.sh`:

1. `~/.claude/plugins/local/analyze-startup/scripts/query-startup.sh`
2. `~/.claude/plugins/local/*/scripts/query-startup.sh`（匹配任意插件名）
3. `~/.claude/plugins/marketplaces/*/plugins/analyze-startup/scripts/query-startup.sh`

找到脚本后执行:

```bash
bash "<脚本路径>" "$TP" "<trace文件>" [包名]
```

**备用方式**: 如果脚本不存在或执行失败，手动逐条运行 SQL 查询:

```bash
"$TP" -q "<sql语句>" "<trace文件>"
```

## 第三步：SQL 查询

查询 1-11、14、16 由辅助脚本自动执行，查询 12-13 根据 Binder 分析结果按需手动执行，查询 15 根据调度优先级分析结果按需手动执行，递归依赖链追踪根据锁竞争和唤醒链分析结果按需手动执行。所有查询使用 Perfetto SQL stdlib（自动可用）。需要 startup_id 的查询使用查询 1 中发现的值。需要包名过滤的查询使用用户参数或查询 1 中发现的包名。

### 查询 1：启动概览

```sql
INCLUDE PERFETTO MODULE android.startup.startups;
INCLUDE PERFETTO MODULE android.startup.time_to_display;

SELECT
  s.startup_id,
  s.package,
  s.startup_type,
  s.dur / 1e6 AS total_dur_ms,
  COALESCE(m.time_to_initial_display / 1e6, 0) AS ttid_ms,
  COALESCE(m.time_to_full_display / 1e6, 0) AS ttfd_ms
FROM android_startups AS s
LEFT JOIN android_startup_time_to_display AS m USING (startup_id)
ORDER BY s.ts;
```

如果用户未提供包名，使用第一行结果的 `package`。如果存在多次启动，优先分析**冷启动**，否则分析耗时最长的启动。

### 查询 2：生命周期阶段分解

```sql
INCLUDE PERFETTO MODULE android.startup.startups;

SELECT
  slice_name,
  slice_dur / 1e6 AS dur_ms,
  thread_name
FROM android_thread_slices_for_all_startups
WHERE startup_id = <STARTUP_ID>
  AND is_main_thread = TRUE
  AND slice_name IN (
    'bindApplication',
    'activityStart',
    'activityResume',
    'inflate',
    'ResourcesManager#getResources',
    'OpenDexFilesFromOat',
    'PostFork',
    'Choreographer#doFrame',
    'traversal',
    'draw'
  )
ORDER BY slice_dur DESC;
```

### 查询 3：主线程耗时 Slice（>1ms）

```sql
INCLUDE PERFETTO MODULE android.startup.startups;

SELECT
  slice_name,
  slice_dur / 1e6 AS dur_ms,
  thread_name,
  slice_id
FROM android_thread_slices_for_all_startups
WHERE startup_id = <STARTUP_ID>
  AND is_main_thread = TRUE
  AND slice_dur > 1000000
ORDER BY slice_dur DESC
LIMIT 30;
```

### 查询 4：线程状态分布

```sql
INCLUDE PERFETTO MODULE android.startup.startups;

SELECT
  t.thread_name,
  t.is_main_thread,
  ts.state,
  ts.io_wait,
  SUM(
    MIN(ts.ts + ts.dur, s.ts + s.dur) - MAX(ts.ts, s.ts)
  ) / 1e6 AS total_ms
FROM android_startup_threads AS t
JOIN android_startups AS s USING (startup_id)
JOIN thread_state AS ts ON ts.utid = t.utid
WHERE t.startup_id = <STARTUP_ID>
  AND ts.ts < s.ts + s.dur
  AND ts.ts + ts.dur > s.ts
  AND t.is_main_thread = TRUE
GROUP BY t.thread_name, ts.state, ts.io_wait
ORDER BY total_ms DESC;
```

### 查询 5：锁竞争

```sql
INCLUDE PERFETTO MODULE android.startup.startups;

SELECT
  slice_name,
  slice_dur / 1e6 AS dur_ms,
  thread_name
FROM android_thread_slices_for_all_startups
WHERE startup_id = <STARTUP_ID>
  AND (slice_name GLOB 'monitor contention*'
    OR slice_name GLOB 'Lock contention*'
    OR slice_name GLOB 'Contending for pthread mutex*')
ORDER BY slice_dur DESC
LIMIT 20;
```

### 查询 6：GC 活动

```sql
INCLUDE PERFETTO MODULE android.startup.startups;

SELECT
  slice_name,
  slice_dur / 1e6 AS dur_ms,
  thread_name
FROM android_thread_slices_for_all_startups
WHERE startup_id = <STARTUP_ID>
  AND (slice_name GLOB 'GC*' OR slice_name GLOB 'GC:*')
ORDER BY slice_dur DESC;
```

### 查询 7：Binder 事务（>5ms）

```sql
INCLUDE PERFETTO MODULE android.startup.startups;

SELECT
  id,
  slice_dur / 1e6 AS dur_ms,
  thread_name,
  process,
  is_main_thread
FROM android_binder_transaction_slices_for_startup(<STARTUP_ID>, 5e6)
ORDER BY slice_dur DESC
LIMIT 20;
```

### 查询 8：归因分解（按原因分类）

```sql
INCLUDE PERFETTO MODULE android.startup.startup_breakdowns;

SELECT
  reason,
  SUM(dur) / 1e6 AS total_ms,
  COUNT(*) AS occurrences,
  ROUND(SUM(dur) * 100.0 / (SELECT dur FROM android_startups WHERE startup_id = <STARTUP_ID>), 1) AS pct
FROM android_startup_opinionated_breakdown
WHERE startup_id = <STARTUP_ID>
GROUP BY reason
ORDER BY total_ms DESC;
```

### 查询 9：DEX / 类加载

```sql
INCLUDE PERFETTO MODULE android.startup.startups;

SELECT
  slice_name,
  COUNT(*) AS count,
  SUM(slice_dur) / 1e6 AS total_ms,
  MAX(slice_dur) / 1e6 AS max_ms
FROM android_thread_slices_for_all_startups
WHERE startup_id = <STARTUP_ID>
  AND (slice_name GLOB 'OpenDexFilesFromOat*'
    OR slice_name GLOB 'VerifyClass*'
    OR slice_name GLOB 'JIT compiling*')
GROUP BY slice_name
ORDER BY total_ms DESC
LIMIT 20;
```

### 查询 10：内置指标（JSON 格式）

此查询作为独立命令运行（非 SQL）:

```bash
"$TP" --run-metrics android_startup --metrics-output=json "<trace文件>"
```

这会输出 Perfetto 官方的 android_startup 指标 JSON。

### 查询 11a：Binder 调用链（自动执行）

对启动期间主线程 >5ms 的 binder 事务，追溯其祖先调用链（最多 5 层），找出调用发起点:

```sql
INCLUDE PERFETTO MODULE android.startup.startups;

WITH binder_txns AS (
  SELECT id AS slice_id
  FROM android_binder_transaction_slices_for_startup(<STARTUP_ID>, 5e6)
  WHERE is_main_thread = 1
  ORDER BY slice_dur DESC
  LIMIT 10
),
ancestors AS (
  SELECT b.slice_id AS txn_id, s.id, s.name, s.dur, s.parent_id, s.depth, 0 AS level
  FROM binder_txns b JOIN slice s ON s.id = b.slice_id
  UNION ALL
  SELECT a.txn_id, s.id, s.name, s.dur, s.parent_id, s.depth, a.level + 1
  FROM ancestors a JOIN slice s ON s.id = a.parent_id
  WHERE a.level < 5
)
SELECT txn_id AS binder_slice_id, level, name AS ancestor_name, dur / 1e6 AS ancestor_dur_ms
FROM ancestors ORDER BY txn_id, level;
```

### 查询 11b：服务端 AIDL 接口（自动执行）

通过 flow 表关联到服务端 reply slice，从其子 slice 提取 AIDL 接口名:

```sql
INCLUDE PERFETTO MODULE android.startup.startups;

WITH binder_txns AS (
  SELECT id AS slice_id, slice_dur, process
  FROM android_binder_transaction_slices_for_startup(<STARTUP_ID>, 5e6)
  WHERE is_main_thread = 1
  ORDER BY slice_dur DESC
  LIMIT 10
),
server_replies AS (
  SELECT b.slice_id AS txn_id, b.slice_dur / 1e6 AS txn_dur_ms, b.process AS dest_process,
         f.slice_in AS server_slice_id
  FROM binder_txns b JOIN flow f ON f.slice_out = b.slice_id
)
SELECT sr.txn_id AS binder_slice_id, sr.txn_dur_ms, sr.dest_process,
       sr.server_slice_id, s.name AS aidl_interface, s.dur / 1e6 AS aidl_dur_ms
FROM server_replies sr
JOIN slice s ON s.parent_id = sr.server_slice_id AND s.dur > 100000
ORDER BY sr.txn_dur_ms DESC, s.dur DESC;
```

**注意**: 如果递归 CTE + table-valued function 不被支持，手动逐个 slice_id 查询作为 fallback。

### 查询 12：服务端执行分解（按需手动执行）

对查询 11b 中获得的 `server_slice_id`，递归展开服务端 slice 树:

```sql
WITH RECURSIVE descendants(id, ts, dur, name, depth, parent_id) AS (
  SELECT id, ts, dur, name, depth, parent_id FROM slice WHERE id = <SERVER_SLICE_ID>
  UNION ALL
  SELECT s.id, s.ts, s.dur, s.name, s.depth, s.parent_id
  FROM slice s JOIN descendants d ON s.parent_id = d.id
)
SELECT name, dur / 1e6 AS dur_ms, depth
FROM descendants WHERE dur > 500000
ORDER BY dur DESC LIMIT 40;
```

### 查询 13：服务端线程状态（按需手动执行）

分析服务端 binder 线程在处理请求期间的状态分布（单条 SQL，无需分步）:

```sql
SELECT ts.state, ts.io_wait,
  SUM(MIN(ts.ts + ts.dur, srv.ts + srv.dur) - MAX(ts.ts, srv.ts)) / 1e6 AS total_ms
FROM slice srv
JOIN thread_track tt ON tt.id = srv.track_id
JOIN thread t ON t.utid = tt.utid
JOIN thread_state ts ON ts.utid = t.utid
  AND ts.ts < srv.ts + srv.dur AND ts.ts + ts.dur > srv.ts
WHERE srv.id = <SERVER_SLICE_ID>
GROUP BY ts.state, ts.io_wait
ORDER BY total_ms DESC;
```

### 查询 14a：主线程调度优先级分布（自动执行）

分析主线程在启动期间的内核调度优先级（`sched_slice.priority`）分布:

```sql
INCLUDE PERFETTO MODULE android.startup.startups;

SELECT
  sc.priority,
  CASE
    WHEN sc.priority < 100 THEN 'RT (SCHED_FIFO/RR)'
    WHEN sc.priority = 100 THEN 'CFS nice -20'
    WHEN sc.priority = 110 THEN 'CFS nice -10'
    WHEN sc.priority = 120 THEN 'CFS nice 0 (default)'
    ELSE 'CFS nice ' || (sc.priority - 120)
  END AS priority_desc,
  COUNT(*) AS slice_count,
  SUM(MIN(sc.ts + sc.dur, s.ts + s.dur) - MAX(sc.ts, s.ts)) / 1e6 AS total_ms,
  ROUND(SUM(MIN(sc.ts + sc.dur, s.ts + s.dur) - MAX(sc.ts, s.ts)) * 100.0 / s.dur, 1) AS pct
FROM android_startups AS s
JOIN process AS p ON p.name = s.package
JOIN thread AS t ON t.upid = p.upid AND t.is_main_thread = 1
JOIN sched_slice AS sc ON sc.utid = t.utid
WHERE s.startup_id = <STARTUP_ID>
  AND sc.ts < s.ts + s.dur
  AND sc.ts + sc.dur > s.ts
GROUP BY sc.priority
ORDER BY total_ms DESC;
```

**优先级含义**: Android 启动时 AMS 通常将前台应用主线程提升为 RT 调度（`SCHED_FIFO`，kernel priority < 100，通常为 98）。如果主线程全程在 CFS 调度（priority >= 100），说明 RT boost 缺失。

### 查询 14b：同 trace 中其他应用启动的主线程优先级（自动执行，对比基线）

```sql
INCLUDE PERFETTO MODULE android.startup.startups;

SELECT
  s.startup_id, s.package, s.startup_type, sc.priority,
  SUM(MIN(sc.ts + sc.dur, s.ts + s.dur) - MAX(sc.ts, s.ts)) / 1e6 AS total_ms
FROM android_startups AS s
JOIN process AS p ON p.name = s.package
JOIN thread AS t ON t.upid = p.upid AND t.is_main_thread = 1
JOIN sched_slice AS sc ON sc.utid = t.utid
WHERE s.startup_id != <STARTUP_ID>
  AND sc.ts < s.ts + s.dur AND sc.ts + sc.dur > s.ts
GROUP BY s.startup_id, s.package, s.startup_type, sc.priority
ORDER BY s.startup_id, total_ms DESC;
```

### 查询 14c：R+ 抢占者优先级分布（自动执行）

主线程被抢占（end_state='R+'）后，分析接替者的优先级，识别低优先级线程异常抢占:

```sql
INCLUDE PERFETTO MODULE android.startup.startups;

WITH main_preempted AS (
  SELECT sc.ts + sc.dur AS switch_ts, sc.cpu, sc.priority AS main_prio
  FROM android_startups AS s
  JOIN process AS p ON p.name = s.package
  JOIN thread AS t ON t.upid = p.upid AND t.is_main_thread = 1
  JOIN sched_slice AS sc ON sc.utid = t.utid
  WHERE s.startup_id = <STARTUP_ID>
    AND sc.end_state = 'R+'
    AND sc.ts < s.ts + s.dur AND sc.ts + sc.dur > s.ts
)
SELECT
  mp.main_prio,
  CASE WHEN sc2.priority <= mp.main_prio THEN 'expected' ELSE 'ANOMALOUS' END AS category,
  sc2.priority AS next_priority,
  p2.name AS next_process, t2.name AS next_thread,
  COUNT(*) AS count, SUM(sc2.dur) / 1e6 AS next_total_ms
FROM main_preempted AS mp
JOIN sched_slice AS sc2 ON sc2.cpu = mp.cpu AND sc2.ts = mp.switch_ts
JOIN thread AS t2 ON t2.utid = sc2.utid
LEFT JOIN process AS p2 ON p2.upid = t2.upid
GROUP BY mp.main_prio, category, sc2.priority, p2.name, t2.name
ORDER BY count DESC LIMIT 40;
```

### 查询 15：主线程优先级时间线（按需手动执行）

当查询 14a 发现主线程未获得 RT 优先级时，查看优先级随时间的变化:

```sql
INCLUDE PERFETTO MODULE android.startup.startups;

SELECT
  (sc.ts - s.ts) / 1e6 AS offset_ms,
  sc.priority,
  sc.dur / 1e6 AS dur_ms,
  sc.cpu,
  sc.end_state
FROM android_startups AS s
JOIN thread AS t ON t.upid = s.upid AND t.is_main_thread = 1
JOIN sched_slice AS sc ON sc.utid = t.utid
WHERE s.startup_id = <STARTUP_ID>
  AND sc.ts < s.ts + s.dur AND sc.ts + sc.dur > s.ts
  AND sc.priority != (
    SELECT sc2.priority
    FROM sched_slice sc2
    JOIN thread t2 ON t2.utid = sc2.utid AND t2.upid = s.upid AND t2.is_main_thread = 1
    WHERE sc2.ts >= s.ts AND sc2.ts < s.ts + s.dur
    GROUP BY sc2.priority ORDER BY SUM(sc2.dur) DESC LIMIT 1
  )
ORDER BY sc.ts;
```

### 查询 16：主线程唤醒链优先级反转分析（由辅助脚本自动执行）

通过 `sched_waking` 内核事件追踪"谁唤醒了主线程"。当主线程处于 Sleep（S）或不可中断等待（D）时，唤醒它的线程就是主线程的依赖。如果唤醒者是 CFS 而主线程是 RT，则构成优先级反转。

**前置条件**: 需要先确认 trace 中有 sched_waking 数据（辅助脚本会自动检查）。

查询 16 使用 `CREATE PERFETTO TABLE` 分步物化执行，避免以下性能陷阱:
- `ftrace_event` + `args` 的 `EXISTS` 逐行相关子查询（原方案在 491K 行 sched_waking 上超时）
- `NOT EXISTS` 反连接 O(W^2) 复杂度
- CTE 不物化导致重复求值

**步骤 0: 物化 startup 参数**

```sql
INCLUDE PERFETTO MODULE android.startup.startups;
CREATE PERFETTO TABLE _q16_startup AS
SELECT s.ts AS start_ts, s.ts + s.dur AS end_ts,
       t.utid AS main_utid, t.tid AS main_tid
FROM android_startups s
JOIN process p ON p.name = s.package
JOIN thread t ON t.upid = p.upid AND t.is_main_thread = 1
WHERE s.startup_id = <STARTUP_ID>;
```

**步骤 1: 物化主线程 S/D 阻塞段**

```sql
CREATE PERFETTO TABLE _q16_blocked AS
SELECT ts.ts AS block_start, ts.ts + ts.dur AS wake_ts,
       ts.dur / 1e6 AS blocked_ms, ts.state, ts.io_wait, ts.blocked_function
FROM thread_state ts, _q16_startup su
WHERE ts.utid = su.main_utid
  AND ts.ts >= su.start_ts AND ts.ts + ts.dur <= su.end_ts
  AND ts.state IN ('S', 'D') AND ts.dur > 100000;
```

**步骤 2: 物化唤醒事件（关键优化: JOIN 替代 EXISTS）**

```sql
CREATE PERFETTO TABLE _q16_waking AS
SELECT fe.ts AS wake_event_ts, fe.utid AS waker_utid
FROM ftrace_event fe
JOIN args a ON a.arg_set_id = fe.arg_set_id AND a.key = 'pid'
JOIN _q16_startup su ON a.int_value = su.main_tid
WHERE fe.name = 'sched_waking'
  AND fe.ts >= su.start_ts AND fe.ts <= su.end_ts;
```

**步骤 3: 匹配阻塞段与唤醒者（ROW_NUMBER 替代 NOT EXISTS）**

```sql
CREATE PERFETTO TABLE _q16_matched AS
SELECT * FROM (
  SELECT mb.block_start, mb.wake_ts, mb.blocked_ms,
         mb.state, mb.io_wait, mb.blocked_function,
         we.waker_utid, we.wake_event_ts,
         ROW_NUMBER() OVER (PARTITION BY mb.block_start ORDER BY we.wake_event_ts DESC) AS rn
  FROM _q16_blocked mb
  LEFT JOIN _q16_waking we
    ON we.wake_event_ts <= mb.wake_ts AND we.wake_event_ts > mb.wake_ts - 1000000
) WHERE rn = 1 OR waker_utid IS NULL;
```

**步骤 4: 获取唤醒者优先级**

```sql
CREATE PERFETTO TABLE _q16_result AS
SELECT m.*,
  (SELECT sc.priority FROM sched_slice sc WHERE sc.utid = m.waker_utid
     AND sc.ts <= m.wake_event_ts AND sc.ts + sc.dur > m.wake_event_ts LIMIT 1) AS waker_priority
FROM _q16_matched m;
```

**查询 16a: 唤醒者优先级分类汇总**

```sql
SELECT
  CASE
    WHEN waker_priority IS NULL THEN 'unknown'
    WHEN waker_priority < 100 THEN 'RT (<100)'
    ELSE 'CFS (>=' || waker_priority || ')'
  END AS waker_class,
  COUNT(*) AS wakeup_count,
  SUM(blocked_ms) AS total_blocked_ms,
  ROUND(SUM(blocked_ms) * 100.0 / (SELECT SUM(blocked_ms) FROM _q16_result), 1) AS pct
FROM _q16_result GROUP BY waker_class ORDER BY total_blocked_ms DESC;
```

**查询 16b: CFS 唤醒者详细列表（优先级反转源）**

```sql
SELECT wt.name AS waker_thread, wp.name AS waker_process, m.waker_priority,
  COUNT(*) AS times, SUM(m.blocked_ms) AS total_blocked_ms, MAX(m.blocked_ms) AS max_blocked_ms
FROM _q16_result m
LEFT JOIN thread wt ON wt.utid = m.waker_utid
LEFT JOIN process wp ON wp.upid = wt.upid
WHERE m.waker_priority >= 100
GROUP BY wt.name, wp.name, m.waker_priority
ORDER BY total_blocked_ms DESC LIMIT 30;
```

**查询 16c: 唤醒者详细列表（含阻塞函数和状态）**

```sql
SELECT m.state, m.io_wait, m.blocked_ms, m.blocked_function,
  wt.name AS waker_thread, wp.name AS waker_process, m.waker_priority,
  CASE WHEN m.waker_priority < 100 THEN 'RT' WHEN m.waker_priority IS NULL THEN 'unknown' ELSE 'CFS' END AS waker_class
FROM _q16_result m
LEFT JOIN thread wt ON wt.utid = m.waker_utid
LEFT JOIN process wp ON wp.upid = wt.upid
ORDER BY m.blocked_ms DESC LIMIT 40;
```

**查询 16d: 关键 CFS 唤醒者的线程状态（诊断放大效应）**

对 16b 中主要的 CFS 唤醒者线程，查看其在启动期间的线程状态分布，特别关注 Runnable 时间（等 CPU）:

```sql
SELECT ts.state, ts.io_wait,
  SUM(MIN(ts.ts + ts.dur, su.end_ts) - MAX(ts.ts, su.start_ts)) / 1e6 AS total_ms
FROM _q16_startup su
JOIN thread_state ts ON ts.utid = <WAKER_UTID>
WHERE ts.ts < su.end_ts AND ts.ts + ts.dur > su.start_ts
GROUP BY ts.state, ts.io_wait ORDER BY total_ms DESC;
```

**清理临时表**（所有 16 系列查询完成后执行）:

```sql
DROP TABLE IF EXISTS _q16_startup;
DROP TABLE IF EXISTS _q16_blocked;
DROP TABLE IF EXISTS _q16_waking;
DROP TABLE IF EXISTS _q16_matched;
DROP TABLE IF EXISTS _q16_result;
```

**手动执行方式**: 查询 16 必须按步骤 0→1→2→3→4 的顺序执行（每步单独一次 trace_processor_shell 调用**不行**，因为 `CREATE PERFETTO TABLE` 是会话内的）。正确做法是将步骤 0-4 + 16a/16b/16c 合并到**同一个 SQL 文件**中，一次性传给 trace_processor_shell。辅助脚本已自动处理。

## 第三步半A：调度优先级深度分析（条件触发）

满足以下**任一**条件时，执行查询 15 并在报告中输出详细的调度分析:

1. 查询 14a 中主线程**从未出现** priority < 100（即无 RT 优先级）
2. 查询 14b 中同 trace 其他应用启动有 RT (priority < 100) 而目标应用没有
3. 查询 14c 中存在大量 **ANOMALOUS** 抢占（低优先级线程抢占主线程）

**分析流程**:

1. **查看查询 14a** → 确定主线程的主要优先级（正常应为 98/RT）
2. **对比查询 14b** → 判断是个别应用问题还是系统全局问题
3. **查看查询 14c** → 识别异常抢占者（自身后台线程、系统低优先级进程等）
4. **运行查询 15** → 追踪优先级变化的精确时间点，关联到生命周期阶段

**背景知识 — Android 启动调度优先级**:

正常启动流程中，AMS 会对前台启动应用的主线程执行:
- `setProcessGroup(pid, THREAD_GROUP_TOP_APP)` — 将进程移入 TOP_APP cgroup
- `setThreadScheduler(tid, SCHED_FIFO, priority=2)` — 设置 RT 调度（kernel priority 98）

RT 优先级意味着主线程**永远不会被** CFS 调度的线程抢占。如果主线程缺少 RT boost:
- 在 CFS 调度下（priority >= 100），主线程与系统所有普通线程公平竞争 CPU
- R+（被抢占）和 R（等待 CPU）时间会显著增加
- 自身后台线程（nice -8/priority 112）也可能抢占主线程（nice -10/priority 110）

**手动执行查询 15 的方式**（与查询 12-13 相同的 heredoc 方式）:

```bash
/path/to/trace_processor_shell -q /dev/stdin "<trace文件>" 2>/dev/null <<'SQL'
INCLUDE PERFETTO MODULE android.startup.startups;
SELECT (sc.ts - s.ts) / 1e6 AS offset_ms, sc.priority, sc.dur / 1e6 AS dur_ms, sc.cpu, sc.end_state
FROM android_startups AS s
JOIN thread AS t ON t.upid = s.upid AND t.is_main_thread = 1
JOIN sched_slice AS sc ON sc.utid = t.utid
WHERE s.startup_id = <STARTUP_ID>
  AND sc.ts < s.ts + s.dur AND sc.ts + sc.dur > s.ts
ORDER BY sc.ts;
SQL
```

## 第三步半B：Binder 深度分析（条件触发）

满足以下**任一**条件时，执行查询 12-13 进行 Binder 深度分析:

1. 查询 8 归因分解中 `binder` 占比 >15%
2. 查询 7 中存在主线程 Binder 事务 >20ms
3. 查询 3 中 Binder 相关 slice 出现在前 5 名

**分析流程**:

1. **查看查询 11 结果** → 识别调用发起点（祖先调用链）+ AIDL 接口名
2. **对耗时最长的 2-3 个事务运行查询 12** → 展开服务端 slice 树，分解服务端操作
3. **对同一事务运行查询 13** → 服务端线程状态（Running / IO Wait / Runnable / Sleep），判断是 CPU 密集、I/O 阻塞还是调度延迟

**手动执行查询 12-13 的正确方式**:

**重要限制**: trace_processor_shell 的 `-q /dev/stdin` 模式**不支持**一个 heredoc 中放多条 SQL 语句（用分号分隔会报错）。每条 SQL 必须单独一次调用。

**必须使用完整绝对路径**调用 trace_processor_shell，不要用 shell 变量赋值后再引用（管道中变量作用域问题会导致 exit code 127）。

**推荐做法**: 对同一个 server_slice_id，查询 12 和查询 13 分两次 heredoc 调用；对多个 server_slice_id，**并行**发起多组 Bash 调用以节省时间。

```bash
# 查询 12 示例（替换绝对路径和 SERVER_SLICE_ID）
/path/to/trace_processor_shell -q /dev/stdin "<trace文件>" 2>/dev/null <<'SQL'
WITH RECURSIVE descendants(id, ts, dur, name, depth, parent_id) AS (
  SELECT id, ts, dur, name, depth, parent_id FROM slice WHERE id = <SERVER_SLICE_ID>
  UNION ALL
  SELECT s.id, s.ts, s.dur, s.name, s.depth, s.parent_id
  FROM slice s JOIN descendants d ON s.parent_id = d.id
)
SELECT name, dur / 1e6 AS dur_ms, depth
FROM descendants WHERE dur > 500000
ORDER BY dur DESC LIMIT 40;
SQL

# 查询 13 示例（同一 SERVER_SLICE_ID，单独调用）
/path/to/trace_processor_shell -q /dev/stdin "<trace文件>" 2>/dev/null <<'SQL'
SELECT ts.state, ts.io_wait,
  SUM(MIN(ts.ts + ts.dur, srv.ts + srv.dur) - MAX(ts.ts, srv.ts)) / 1e6 AS total_ms
FROM slice srv
JOIN thread_track tt ON tt.id = srv.track_id
JOIN thread t ON t.utid = tt.utid
JOIN thread_state ts ON ts.utid = t.utid
  AND ts.ts < srv.ts + srv.dur AND ts.ts + ts.dur > srv.ts
WHERE srv.id = <SERVER_SLICE_ID>
GROUP BY ts.state, ts.io_wait
ORDER BY total_ms DESC;
SQL
```

## 第三步半C：主线程依赖链优先级反转分析（条件触发）

**始终执行**: 只要主线程在启动期间有 >100ms 的非 Running 时间（S + D 状态），就应执行查询 16 分析唤醒链中的优先级反转。

**前置**: 先检查 trace 中是否有 `sched_waking` 数据。如果没有，跳过并在报告中注明"trace 未采集 sched_waking 事件，无法分析唤醒链"。

**分析流程**:

1. **执行查询 16a** → 获取唤醒者优先级分类汇总，判断 CFS 唤醒占比
2. **如果 CFS 唤醒占比 >30%**，执行查询 16b → 识别具体的 CFS 唤醒者线程
3. **执行查询 16c** → 查看最长阻塞事件的详细信息（状态、阻塞函数、唤醒者）
4. **对 16b 中阻塞贡献 >10ms 的 CFS 唤醒者**，执行查询 16d → 分析唤醒者线程自身的线程状态，特别关注 Runnable 时间（量化放大效应）

**背景知识 — 优先级反转**:

当 RT 线程（主线程）等待 CFS 线程完成操作时，CFS 线程获取 CPU 的速度远低于 RT 线程——它需要与所有其他 CFS 线程公平竞争 CPU。这意味着:

- **直接反转**: RT 主线程 Sleep 等锁/等 binder/等异步操作 → 执行者是 CFS 线程 → CFS 线程拿 CPU 慢 → 主线程阻塞时间被放大
- **内核级反转**: RT 主线程触发 direct reclaim (D 状态) → 等待 kswapd0 回收内存 → kswapd0 是 CFS 120 → kswapd0 自身也被抢占
- **Binder 优先级继承可以缓解**: Binder 调用时服务端继承客户端优先级。但锁竞争、SharedPreferences 等待、内核等待等路径**没有**优先级继承机制

**关键的优先级反转类型**:

| 类型 | 典型场景 | 有无 PI 机制 |
|------|---------|-------------|
| Binder 调用 | 主线程→system_server binder | 有（Binder PI） |
| Java monitor 锁 | 主线程等待后台线程释放 synchronized | 无 |
| SharedPreferences | 主线程 awaitLoadedLocked 等 SP 线程 | 无 |
| 内核内存回收 | 主线程 direct reclaim 等 kswapd | 无 |
| futex / pthread_mutex | 主线程等 native 锁 | 有（futex PI，需 PTHREAD_PRIO_INHERIT） |
| IO 完成 | 主线程等 IO completion → 由 kworker/softirq 唤醒 | 无 |

## 第三步半D：递归依赖链追踪（条件触发）

当主线程被某个线程阻塞时（锁等待、Sleep 唤醒依赖等），自动追踪"那个阻塞者线程在干什么、被谁阻塞"，递归展开直到找到根因（CPU 工作、I/O、或达到最大深度）。

**触发条件** — 满足以下**任一**条件时执行:
- 查询 3（主线程耗时 Slice）或查询 5（锁竞争）中存在主线程 `monitor contention` / `Lock contention` 事件 >50ms
- 查询 16c 中单个 CFS 唤醒者阻塞主线程 >30ms

**分析流程** — 对每个触发事件，执行以下递归步骤（最多 10 层）:

### Step 1: 确定阻塞者线程和时间窗口

- 从锁竞争 slice 的 `owner tid` 提取阻塞者线程 tid
- 或从查询 16c 的唤醒者 utid 提取
- 时间窗口 = 主线程被阻塞的起止时间

### Step 2: 查询阻塞者线程在该时间窗口内的状态分布

```sql
SELECT ts.state, ts.io_wait, ts.blocked_function,
  SUM(MIN(ts.ts + ts.dur, <END_TS>) - MAX(ts.ts, <START_TS>)) / 1e6 AS total_ms
FROM thread_state ts
WHERE ts.utid = <BLOCKER_UTID>
  AND ts.ts + ts.dur > <START_TS> AND ts.ts < <END_TS>
GROUP BY ts.state, ts.io_wait, ts.blocked_function
ORDER BY total_ms DESC;
```

### Step 3: 查询阻塞者线程在该时间窗口内的 slice 执行内容

```sql
SELECT s.id, s.name, s.dur / 1e6 AS dur_ms, s.depth
FROM slice s
JOIN thread_track tt ON tt.id = s.track_id
WHERE tt.utid = <BLOCKER_UTID>
  AND s.ts + s.dur > <START_TS> AND s.ts < <END_TS>
  AND s.dur > 500000
ORDER BY s.dur DESC LIMIT 20;
```

### Step 4: 如果阻塞者线程有显著的非 Running 时间，查询谁阻塞/唤醒了它

当阻塞者线程的 S/D 状态 >30% 或 R/R+ >20% 时，继续追踪。

**对 Sleep/D 状态** — 通过 sched_waking 追踪唤醒者（使用 CREATE PERFETTO TABLE 物化，类似查询 16 的模式）:

```sql
-- 物化阻塞段
CREATE PERFETTO TABLE _chain_blocked AS
SELECT ts.ts AS block_start, ts.ts + ts.dur AS wake_ts, ts.dur / 1e6 AS blocked_ms,
       ts.state, ts.io_wait, ts.blocked_function
FROM thread_state ts
WHERE ts.utid = <BLOCKER_UTID>
  AND ts.ts >= <START_TS> AND ts.ts + ts.dur <= <END_TS>
  AND ts.state IN ('S', 'D') AND ts.dur > 100000;

-- 物化唤醒事件
CREATE PERFETTO TABLE _chain_waking AS
SELECT fe.ts AS wake_event_ts, fe.utid AS waker_utid
FROM ftrace_event fe
JOIN args a ON a.arg_set_id = fe.arg_set_id AND a.key = 'pid'
WHERE fe.name = 'sched_waking'
  AND a.int_value = <BLOCKER_TID>
  AND fe.ts >= <START_TS> AND fe.ts <= <END_TS>;

-- 匹配阻塞段与唤醒者
CREATE PERFETTO TABLE _chain_matched AS
SELECT * FROM (
  SELECT mb.block_start, mb.wake_ts, mb.blocked_ms,
         mb.state, mb.io_wait, mb.blocked_function,
         we.waker_utid, we.wake_event_ts,
         ROW_NUMBER() OVER (PARTITION BY mb.block_start ORDER BY we.wake_event_ts DESC) AS rn
  FROM _chain_blocked mb
  LEFT JOIN _chain_waking we
    ON we.wake_event_ts <= mb.wake_ts AND we.wake_event_ts > mb.wake_ts - 1000000
) WHERE rn = 1 OR waker_utid IS NULL;

-- 获取唤醒者信息和优先级
SELECT m.blocked_ms, m.state, m.blocked_function,
  t.name AS waker_thread, p.name AS waker_process,
  (SELECT sc.priority FROM sched_slice sc WHERE sc.utid = m.waker_utid
     AND sc.ts <= m.wake_event_ts AND sc.ts + sc.dur > m.wake_event_ts LIMIT 1) AS waker_priority
FROM _chain_matched m
LEFT JOIN thread t ON t.utid = m.waker_utid
LEFT JOIN process p ON p.upid = t.upid
WHERE m.rn = 1 OR m.waker_utid IS NULL
ORDER BY m.blocked_ms DESC LIMIT 20;

-- 清理
DROP TABLE IF EXISTS _chain_blocked;
DROP TABLE IF EXISTS _chain_waking;
DROP TABLE IF EXISTS _chain_matched;
```

**对 R+/R 状态** — 查询谁抢占了它:

```sql
SELECT p2.name AS preemptor_process, t2.name AS preemptor_thread,
  sc2.priority AS preemptor_prio, COUNT(*) AS count,
  SUM(sc2.dur) / 1e6 AS preemptor_total_ms
FROM sched_slice sc
JOIN sched_slice sc2 ON sc2.cpu = sc.cpu AND sc2.ts = sc.ts + sc.dur
JOIN thread t2 ON t2.utid = sc2.utid
LEFT JOIN process p2 ON p2.upid = t2.upid
WHERE sc.utid = <BLOCKER_UTID> AND sc.end_state = 'R+'
  AND sc.ts >= <START_TS> AND sc.ts + sc.dur <= <END_TS>
GROUP BY p2.name, t2.name, sc2.priority
ORDER BY preemptor_total_ms DESC LIMIT 15;
```

### Step 5: 递归

如果发现新的阻塞者（唤醒者线程阻塞时间 >20ms），以该线程为新目标，重复 Step 2-4。

**递归终止条件**:
- 达到最大深度（10 层）
- 阻塞者主要是 Running 状态（>70%，已找到 CPU 根因）
- 阻塞者主要是 D-IO（已找到 I/O 根因）
- 新的阻塞时间 <20ms（不值得继续追踪）

**执行方式**: 每个 Step 都是独立的 `trace_processor_shell` 调用（heredoc 模式）。对同一层的多个查询可以并行执行。使用 CREATE PERFETTO TABLE 时需要合并到同一个 SQL 文件（类似查询 16 的处理方式）。

## 第四步：分析并生成报告

收集全部查询结果后，请用**中文**输出以下格式的结构化报告:

---

### 启动性能分析报告

#### 1. 概览

| 指标 | 值 |
|------|-----|
| 包名 | `<package>` |
| 启动类型 | 冷启动 / 温启动 / 热启动 |
| 总耗时 | XXX ms |
| 首帧显示时间（TTID） | XXX ms |
| 完全显示时间（TTFD） | XXX ms |
| 评定 | 快速 / 正常 / 偏慢 / 严重卡顿 |

评定标准:
- **冷启动**: <500ms = 快速, 500-1000ms = 正常, 1000-2000ms = 偏慢, >2000ms = 严重卡顿
- **温启动**: <300ms = 快速, 300-700ms = 正常, 700-1500ms = 偏慢, >1500ms = 严重卡顿
- **热启动**: <150ms = 快速, 150-400ms = 正常, >400ms = 偏慢

#### 2. 阶段耗时分解

展示各生命周期阶段的耗时（bindApplication、activityStart、activityResume、inflate 等），标注异常偏高的阶段。

#### 3. 线程状态分析

展示主线程时间在 Running（运行中）、Runnable（可运行/等待CPU）、Sleeping（睡眠）、I/O Wait（I/O等待）各状态的分布。标记以下问题:
- **Runnable >15%**: CPU 竞争（过多线程抢占 CPU）
- **可中断睡眠 >2900ms**: 过度睡眠（可能在等待锁或 I/O 回调）
- **阻塞 I/O >450ms**: I/O 瓶颈（磁盘读取、DEX 加载）

#### 4. 耗时 Slice 排行

列出主线程上耗时最长的 10-15 个 slice 及其耗时。适当归组相关的 slice。

#### 5. 瓶颈识别

基于归因分解（查询 8），按百分比列出启动延迟的主要原因。各原因含义:
- `bind_application`: 应用初始化（Application.onCreate、ContentProvider）
- `inflate`: 布局加载
- `verify_class`: 类校验（缺少 baseline profile）
- `binder`: 跨进程通信
- `monitor_contention` / `art_lock_contention`: 锁竞争
- `io`: 磁盘 I/O
- `running`: CPU 计算时间
- `launch_delay`: 主线程启动前的延迟

#### 6. Binder、锁竞争与 GC 详情

##### 6.1 Binder 事务清单

基于查询 7，列出启动期间主线程 >5ms 的 Binder 事务基本信息（slice_id、耗时、目标进程）。

##### 6.2 调用链与 AIDL 接口

基于查询 11，展示每个慢 Binder 事务的:
- **应用侧调用来源**: 祖先调用链，标注调用发起点（如 performCreate:XxxActivity）
- **AIDL 接口名**: 服务端处理的具体接口（如 ISearchManager::getGlobalSearchActivity）

##### 6.3 服务端分析

基于查询 12-13（如有执行），展示:
- **服务端操作分解**: 服务端在处理请求期间的 slice 树，标注耗时操作
- **线程状态分布**: 服务端 binder 线程的 Running / IO Wait / Runnable / Sleep 占比，判断是 CPU 密集、I/O 阻塞还是调度延迟

##### 6.4 锁竞争与 GC

如果发现明显问题:
- 列出耗时最长的锁竞争事件
- 列出 GC 事件及总开销

#### 7. 调度优先级分析

##### 7.1 主线程优先级分布

基于查询 14a，展示主线程在启动期间的调度优先级分布表:

| 优先级 | 含义 | 运行时间 (ms) | 占比 |
|--------|------|---------------|------|
| 98 | RT (SCHED_FIFO) | XXX | XX% |
| 110 | CFS nice -10 | XXX | XX% |

**判定**: 如果主线程以 RT (priority < 100) 运行占主导 → 正常。如果全程 CFS → **RT boost 缺失**。

##### 7.2 跨应用对比

基于查询 14b，对比同 trace 中其他应用启动时的主线程优先级。重点标注:
- 其他应用是否获得了 RT 优先级
- 目标应用与其他应用的优先级差异

##### 7.3 异常抢占分析

基于查询 14c，当存在 ANOMALOUS 抢占时列出:
- **低优先级抢占主线程**的线程清单（进程名、线程名、优先级、次数）
- 特别标注**应用自身后台线程**抢占主线程的情况（如 priority=112 的后台线程抢占 priority=110 的主线程）

##### 7.4 优先级时间线（如有执行查询 15）

展示优先级随启动阶段的变化，标注关键转折点及关联的生命周期事件。

##### 7.5 影响量化

估算 RT 优先级缺失的影响:
- R+ 状态中因缺少 RT 导致的额外等待时间
- 如果有 RT 优先级，R+ 和 R 等待预计可减少多少
- 占总启动时间的百分比

**注意**: 如果主线程正常获得了 RT 优先级，7.1-7.5 简要说明"调度优先级正常（RT priority 98）"即可，无需展开。但 7.6 仍需分析。

##### 7.6 主线程依赖链优先级反转

基于查询 16（sched_waking 唤醒链分析），展示主线程在 Sleep/D 阻塞期间，唤醒者线程的优先级分布。

**7.6.1 唤醒者优先级分类汇总**

| 唤醒者优先级 | 唤醒次数 | 主线程阻塞时间 (ms) | 占比 |
|-------------|---------|--------------------|----|
| RT (<100) | XXX | XXX | XX% |
| CFS (>=100) | XXX | XXX | XX% |

**判定**: CFS 唤醒占比 >30% 表示存在优先级反转。即使主线程是 RT，其依赖链上的 CFS 线程也会拖慢主线程。

**7.6.2 优先级反转源详细分析**

对每个主要的 CFS 唤醒者，展示:
- 唤醒者线程名、进程名、优先级
- 阻塞主线程的总时间和最大单次时间
- 阻塞类型（blocked_function: try_to_free_pages = 内核内存回收, mmap 相关 = 内存映射等）
- 唤醒者自身的线程状态（特别是 Runnable 时间 — 量化 CFS 调度延迟的放大效应）

按以下分类展示:
1. **内核级反转**: kswapd0、kworker、ksoftirqd 等内核线程（应用无法直接控制）
2. **应用级反转**: 自身进程内的工作线程（SharedPreferencesImpl、HWUI、SDK 线程等）
3. **系统服务反转**: system_server 非 binder 线程等

**7.6.3 放大效应量化**

对主要 CFS 唤醒者，展示"实际 CPU 工作量 vs Runnable 等 CPU 时间"来量化反转的放大效应:

```
唤醒者线程 (CFS 120):
  实际 CPU 工作:  Xms
  等 CPU (Runnable): Xms  ← 因优先级低无法及时获得 CPU
  被抢占 (R+):       Xms
  ───────────────────
  主线程因此阻塞:    Xms  ← 其中大部分时间唤醒者在等 CPU 而非做实际工作
```

**7.6.4 优先级反转全景图**

用文本树展示完整的反转链路:

```
主线程 (RT 98) 阻塞 XXXms:
    RT 唤醒路径 (XX%, XXms) ← 正常
    ├─ binder 线程 (RT 继承) ── XXms
    └─ 其他 RT 线程 ── XXms

    CFS 唤醒路径 (XX%, XXms) ← 优先级反转
    ├─ 内核级: kswapd0/kworker (CFS 120) ── XXms
    ├─ 应用级: SP/HWUI/SDK线程 (CFS 120) ── XXms
    └─ 系统级: system_server 非binder (CFS) ── XXms
```

**注意**: 如果 trace 未采集 `sched_waking` 事件，注明无法分析并跳过本节。如果 CFS 唤醒占比 <10%，简要说明"依赖链优先级正常，无显著反转"即可。

#### 8. 问题总结与根因分析

本节对全部发现进行综合归因，给出完整的根因链路。这是报告中最重要的部分，需要将分散的数据点串联成因果链。

##### 8.1 核心结论

用 1-2 句话概括启动表现和根本原因。格式:

> **[包名] [启动类型]耗时 XXXms，属于[评定]级别（阈值 XXXms）。根因是……**

##### 8.2 根因链路图

用缩进文本树展示因果关系链，从系统级原因到应用级原因，层层展开。格式示例:

```
顶层原因 A（如：系统内存压力）
  ├─→ 中间效应 1（如：内核内存回收 XXms）
  ├─→ 中间效应 2（如：触发 GC）
  │     └─→ 末端影响（如：Binder 调用被 GC 锁阻塞 XXms）
  └─→ 中间效应 3（如：CPU 资源紧张 → Runnable XXms）

顶层原因 B（如：应用初始化过重）
  ├─→ 分支 1（如：SDK 同步初始化 → makeApplication XXms）
  ├─→ 分支 2（如：多线程 loadLibrary → 锁竞争链）
  │     ├─→ 主线程影响
  │     └─→ CPU 竞争影响
  └─→ 分支 3（如：DEX 未编译 → 类校验 XXms）
```

要求:
- 每个节点必须标注**具体耗时数字**
- 展示因果箭头（`─→`），说明上游原因如何导致下游影响
- 涵盖所有查询发现的主要问题，不遗漏
- 区分**应用自身可控**的原因和**系统环境**原因
- 对锁竞争和长阻塞事件，展开锁持有者的内部执行分解（Running/Sleep/D-IO 占比）
- 如果持有者又被其他线程阻塞，继续递归展开（最多 10 层），直到找到 CPU 工作、I/O 操作或内核等待等终端原因
- 递归链路中标注每层的线程名、优先级、状态占比

##### 8.3 核心问题清单

用表格列出 3-6 个核心问题，每个问题包含直接影响和根因:

| # | 问题 | 直接影响 | 根因 |
|---|------|----------|------|
| 1 | 问题名称 | 具体耗时和占比 | 技术层面的根本原因解释 |

要求:
- 按影响从大到小排序
- "直接影响"列引用具体数字（如 "bindApplication 974ms，占 54.5%"）
- "根因"列解释**为什么**会出现这个问题（如 "安全 SDK、WeexJS 等在 onCreate 中同步初始化"）

##### 8.4 一句话总结

用一段话（2-3 句）完整概括启动慢的全貌，涵盖:
- 最耗时的阶段是什么
- 应用在做什么导致了慢
- 是否有系统环境因素叠加
- 各因素之间的关联关系

## 分析指南

- 所有分析必须基于实际数据，引用具体数字。
- 识别瓶颈时，说明**为什么**这是问题，以及应用在该时段**可能在做什么**。
- 如果 trace 中存在多次启动，分别分析并对比。
- 如果数据缺失（如 TTFD 为 0），注明"未上报"而非视为瞬间完成。
- 优化建议按预期收益（节省时间最多的优先）排序。
- 如果启动表现良好，明确说明，不要捏造问题。
- 报告全程使用中文。
