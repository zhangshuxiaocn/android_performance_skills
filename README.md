# Android Performance Skills

Android 性能分析的 [Claude Code](https://docs.anthropic.com/en/docs/claude-code) 插件集合。通过自然语言驱动 Perfetto trace 分析，覆盖启动、内存、渲染等性能场景。

## 当前包含的 Skills

| Skill | 命令 | 说明 |
|-------|------|------|
| 启动分析 | `/analyze-startup <trace文件> [包名]` | 分析 Android 应用启动性能，输出结构化中文报告 |

> 更多 skill 持续添加中（内存分析、渲染性能、ANR 分析等）。

## 安装

### 一键安装（推荐）

```bash
git clone https://github.com/zhangshuxiaocn/android_performance_skills.git
cd android_performance_skills
bash install.sh
```

`install.sh` 会将仓库软链接到 `~/.claude/plugins/local/android-performance-skills`，并清理旧的 `analyze-startup` 链接。

### 手动安装

```bash
git clone https://github.com/zhangshuxiaocn/android_performance_skills.git ~/android_performance_skills

# 创建软链接
mkdir -p ~/.claude/plugins/local
ln -s ~/android_performance_skills ~/.claude/plugins/local/android-performance-skills
```

安装完成后，**重启 Claude Code** 使插件生效。

## Skills 详解

### /analyze-startup — 启动性能分析

基于 [Perfetto](https://perfetto.dev/) trace 文件，自动执行 17 个 SQL 查询，输出 9 节结构化中文分析报告。

#### 使用方法

```
/analyze-startup <trace文件路径> [包名]
```

- `<trace文件路径>` — `.perfetto-trace` 或 `.pb` 文件（必填）
- `[包名]` — 要分析的 Android 包名（可选，不提供则从 trace 自动检测）

#### 示例

```
/analyze-startup ~/traces/cold-start.perfetto-trace
/analyze-startup ~/traces/app-launch.pb com.example.myapp
```

#### 功能亮点

- **一键分析**: 一条命令获得完整报告
- **17 个专项查询**: 覆盖启动全维度 — 生命周期、线程状态、Binder、锁竞争、GC、类加载、调度优先级、唤醒链优先级反转等
- **智能深度分析**: 根据查询结果自动触发 Binder 服务端分解、调度优先级时间线和唤醒链优先级反转分析
- **结构化报告**: 9 节报告，从概览到根因链路，附带可操作的优化建议

#### 报告结构

1. **概览** — 包名、启动类型、耗时、TTID/TTFD、评定
2. **阶段耗时分解** — 各生命周期阶段耗时
3. **线程状态分析** — Running/Runnable/Sleep/IO 分布
4. **耗时 Slice 排行** — 主线程 Top 10-15 耗时操作
5. **瓶颈识别** — 基于归因分解的启动延迟主因
6. **Binder、锁竞争与 GC 详情** — 事务清单、调用链、AIDL 接口、服务端分析
7. **调度优先级分析** — RT boost、异常抢占、依赖链优先级反转
8. **优化建议** — 按预期收益排序的具体建议
9. **问题总结与根因分析** — 核心结论、根因链路图、问题清单

#### 辅助脚本

`scripts/query-startup.sh` 可以脱离 Claude Code 独立运行:

```bash
bash scripts/query-startup.sh /path/to/trace_processor_shell /path/to/trace.perfetto-trace [包名]
```

## 如何贡献新 Skill

1. 在 `commands/` 下创建新的 `.md` 文件（文件名即命令名）
2. 在 `scripts/` 下添加对应的辅助脚本（如有需要）
3. 更新本 README 的 Skills 列表
4. 提交 PR

Skill 文件格式参考 `commands/analyze-startup.md`，需包含 frontmatter（description、allowed-tools 等）和完整的分析指令。

## 前置条件

- **Claude Code**: 需安装 [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI
- **trace_processor_shell**: Perfetto 的命令行查询工具
  - AOSP 中位于 `prebuilts/tools/linux-x86_64/perfetto/trace_processor_shell`
  - 也可从 [Perfetto 官网](https://perfetto.dev/) 下载独立版本并放入 PATH
- **Perfetto trace 文件**: 需包含对应分析场景所需的数据类别

## 许可证

[MIT](LICENSE)
