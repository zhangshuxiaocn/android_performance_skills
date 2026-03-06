#!/usr/bin/env bash
# query-startup.sh — 针对 Android 启动分析执行 Perfetto SQL 查询
# 用法: query-startup.sh <trace_processor_shell路径> <trace文件路径> [包名]

set -euo pipefail

TP="$1"
TRACE="$2"
PACKAGE="${3:-}"

if [[ ! -x "$TP" ]]; then
  echo "错误: trace_processor_shell 不存在或不可执行: $TP" >&2
  exit 1
fi

if [[ ! -f "$TRACE" ]]; then
  echo "错误: Trace 文件不存在: $TRACE" >&2
  exit 1
fi

run_query() {
  local label="$1"
  local sql="$2"
  echo "========================================"
  echo "=== $label"
  echo "========================================"
  echo "$sql" | "$TP" -q /dev/stdin "$TRACE" 2>/dev/null || echo "(查询失败或无结果)"
  echo ""
}

# --- 查询 1: 启动概览 ---
run_query "启动概览" "
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
"

# 确定后续查询使用的 STARTUP_ID
# 优先选择冷启动，否则选择耗时最长的启动
STARTUP_ID=$("$TP" -q /dev/stdin "$TRACE" 2>/dev/null <<'SQL' | tail -n +3 | head -1
INCLUDE PERFETTO MODULE android.startup.startups;
SELECT startup_id
FROM android_startups
ORDER BY
  CASE WHEN startup_type = 'cold' THEN 0 ELSE 1 END,
  dur DESC
LIMIT 1;
SQL
)

# 去除空白字符
STARTUP_ID="$(echo "$STARTUP_ID" | tr -d '[:space:]')"

if [[ -z "$STARTUP_ID" ]]; then
  echo "错误: trace 中未找到任何启动事件。" >&2
  exit 1
fi

echo ">>> 使用 startup_id=$STARTUP_ID 进行详细分析"
echo ""

# --- 查询 2: 生命周期阶段分解 ---
run_query "生命周期阶段分解" "
INCLUDE PERFETTO MODULE android.startup.startups;

SELECT
  slice_name,
  slice_dur / 1e6 AS dur_ms,
  thread_name
FROM android_thread_slices_for_all_startups
WHERE startup_id = $STARTUP_ID
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
"

# --- 查询 3: 主线程耗时 Slice（>1ms）---
run_query "主线程耗时 Slice（>1ms）" "
INCLUDE PERFETTO MODULE android.startup.startups;

SELECT
  slice_name,
  slice_dur / 1e6 AS dur_ms,
  thread_name,
  slice_id
FROM android_thread_slices_for_all_startups
WHERE startup_id = $STARTUP_ID
  AND is_main_thread = TRUE
  AND slice_dur > 1000000
ORDER BY slice_dur DESC
LIMIT 30;
"

# --- 查询 4: 线程状态分布 ---
run_query "线程状态分布（主线程）" "
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
WHERE t.startup_id = $STARTUP_ID
  AND ts.ts < s.ts + s.dur
  AND ts.ts + ts.dur > s.ts
  AND t.is_main_thread = TRUE
GROUP BY t.thread_name, ts.state, ts.io_wait
ORDER BY total_ms DESC;
"

# --- 查询 5: 锁竞争 ---
run_query "锁竞争" "
INCLUDE PERFETTO MODULE android.startup.startups;

SELECT
  slice_name,
  slice_dur / 1e6 AS dur_ms,
  thread_name
FROM android_thread_slices_for_all_startups
WHERE startup_id = $STARTUP_ID
  AND (slice_name GLOB 'monitor contention*'
    OR slice_name GLOB 'Lock contention*'
    OR slice_name GLOB 'Contending for pthread mutex*')
ORDER BY slice_dur DESC
LIMIT 20;
"

# --- 查询 6: GC 活动 ---
run_query "GC 活动" "
INCLUDE PERFETTO MODULE android.startup.startups;

SELECT
  slice_name,
  slice_dur / 1e6 AS dur_ms,
  thread_name
FROM android_thread_slices_for_all_startups
WHERE startup_id = $STARTUP_ID
  AND (slice_name GLOB 'GC*' OR slice_name GLOB 'GC:*')
ORDER BY slice_dur DESC;
"

# --- 查询 7: Binder 事务（>5ms）---
run_query "Binder 事务（>5ms）" "
INCLUDE PERFETTO MODULE android.startup.startups;

SELECT
  id,
  slice_dur / 1e6 AS dur_ms,
  thread_name,
  process,
  is_main_thread
FROM android_binder_transaction_slices_for_startup($STARTUP_ID, 5e6)
ORDER BY slice_dur DESC
LIMIT 20;
"

# --- 查询 8: 归因分解（按原因分类）---
run_query "归因分解（按原因分类）" "
INCLUDE PERFETTO MODULE android.startup.startup_breakdowns;

SELECT
  reason,
  SUM(dur) / 1e6 AS total_ms,
  COUNT(*) AS occurrences,
  ROUND(SUM(dur) * 100.0 / (SELECT dur FROM android_startups WHERE startup_id = $STARTUP_ID), 1) AS pct
FROM android_startup_opinionated_breakdown
WHERE startup_id = $STARTUP_ID
GROUP BY reason
ORDER BY total_ms DESC;
"

# --- 查询 9: DEX / 类加载 ---
run_query "DEX / 类加载" "
INCLUDE PERFETTO MODULE android.startup.startups;

SELECT
  slice_name,
  COUNT(*) AS count,
  SUM(slice_dur) / 1e6 AS total_ms,
  MAX(slice_dur) / 1e6 AS max_ms
FROM android_thread_slices_for_all_startups
WHERE startup_id = $STARTUP_ID
  AND (slice_name GLOB 'OpenDexFilesFromOat*'
    OR slice_name GLOB 'VerifyClass*'
    OR slice_name GLOB 'JIT compiling*')
GROUP BY slice_name
ORDER BY total_ms DESC
LIMIT 20;
"

# --- 查询 11a: Binder 调用链（主线程 >5ms 事务的祖先 slice）---
run_query "Binder 调用链" "
INCLUDE PERFETTO MODULE android.startup.startups;

WITH binder_txns AS (
  SELECT id AS slice_id
  FROM android_binder_transaction_slices_for_startup($STARTUP_ID, 5e6)
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
"

# --- 查询 11b: 服务端 AIDL 接口 ---
run_query "服务端 AIDL 接口" "
INCLUDE PERFETTO MODULE android.startup.startups;

WITH binder_txns AS (
  SELECT id AS slice_id, slice_dur, process
  FROM android_binder_transaction_slices_for_startup($STARTUP_ID, 5e6)
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
"

# --- 查询 14a: 主线程调度优先级分布 ---
# 注意: android_startups 没有 upid 列，需通过 package 名关联 process 表找主线程
run_query "主线程调度优先级分布" "
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
WHERE s.startup_id = $STARTUP_ID
  AND sc.ts < s.ts + s.dur
  AND sc.ts + sc.dur > s.ts
GROUP BY sc.priority
ORDER BY total_ms DESC;
"

# --- 查询 14b: 同 trace 中其他应用启动的主线程优先级（对比基线）---
run_query "其他应用启动主线程优先级（对比）" "
INCLUDE PERFETTO MODULE android.startup.startups;

SELECT
  s.startup_id,
  s.package,
  s.startup_type,
  sc.priority,
  SUM(MIN(sc.ts + sc.dur, s.ts + s.dur) - MAX(sc.ts, s.ts)) / 1e6 AS total_ms
FROM android_startups AS s
JOIN process AS p ON p.name = s.package
JOIN thread AS t ON t.upid = p.upid AND t.is_main_thread = 1
JOIN sched_slice AS sc ON sc.utid = t.utid
WHERE s.startup_id != $STARTUP_ID
  AND sc.ts < s.ts + s.dur
  AND sc.ts + sc.dur > s.ts
GROUP BY s.startup_id, s.package, s.startup_type, sc.priority
ORDER BY s.startup_id, total_ms DESC;
"

# --- 查询 14c: 主线程被抢占(R+)后接替者的优先级分布 ---
run_query "R+ 抢占者优先级分布" "
INCLUDE PERFETTO MODULE android.startup.startups;

WITH main_preempted AS (
  SELECT sc.ts + sc.dur AS switch_ts, sc.cpu, sc.priority AS main_prio
  FROM android_startups AS s
  JOIN process AS p ON p.name = s.package
  JOIN thread AS t ON t.upid = p.upid AND t.is_main_thread = 1
  JOIN sched_slice AS sc ON sc.utid = t.utid
  WHERE s.startup_id = $STARTUP_ID
    AND sc.end_state = 'R+'
    AND sc.ts < s.ts + s.dur
    AND sc.ts + sc.dur > s.ts
)
SELECT
  mp.main_prio,
  CASE WHEN sc2.priority <= mp.main_prio THEN 'expected' ELSE 'ANOMALOUS' END AS category,
  sc2.priority AS next_priority,
  p2.name AS next_process,
  t2.name AS next_thread,
  COUNT(*) AS count,
  SUM(sc2.dur) / 1e6 AS next_total_ms
FROM main_preempted AS mp
JOIN sched_slice AS sc2 ON sc2.cpu = mp.cpu AND sc2.ts = mp.switch_ts
JOIN thread AS t2 ON t2.utid = sc2.utid
LEFT JOIN process AS p2 ON p2.upid = t2.upid
GROUP BY mp.main_prio, category, sc2.priority, p2.name, t2.name
ORDER BY count DESC
LIMIT 40;
"

# --- 查询 10: 内置指标（JSON 格式）---
echo "========================================"
echo "=== 内置指标（android_startup JSON）"
echo "========================================"
"$TP" --run-metrics android_startup --metrics-output=json "$TRACE" 2>/dev/null || echo "(指标查询失败)"
echo ""

echo "========================================"
echo "=== 全部查询完成（共 15 个查询）"
echo "========================================"
