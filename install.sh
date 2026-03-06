#!/usr/bin/env bash
# install.sh — 将本仓库安装为 Claude Code 本地插件
#
# 操作:
#   1. 将仓库目录软链接到 ~/.claude/plugins/local/android-performance-skills
#   2. 清理旧的 ~/.claude/plugins/local/analyze-startup 链接（如果指向旧仓库）

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$HOME/.claude/plugins/local/android-performance-skills"
OLD_PLUGIN_DIR="$HOME/.claude/plugins/local/analyze-startup"

echo "==> 安装 android-performance-skills 插件"
echo "    仓库路径: $REPO_DIR"
echo ""

# 1. 创建插件目录的父级（如果不存在）
mkdir -p "$(dirname "$PLUGIN_DIR")"

# 2. 处理已有的插件目录/链接
if [[ -L "$PLUGIN_DIR" ]]; then
  CURRENT_TARGET="$(readlink -f "$PLUGIN_DIR")"
  if [[ "$CURRENT_TARGET" == "$REPO_DIR" ]]; then
    echo "    软链接已存在且指向正确，跳过。"
  else
    echo "    更新软链接: $CURRENT_TARGET -> $REPO_DIR"
    rm "$PLUGIN_DIR"
    ln -s "$REPO_DIR" "$PLUGIN_DIR"
  fi
elif [[ -d "$PLUGIN_DIR" ]]; then
  echo "    发现已有插件目录: $PLUGIN_DIR"
  echo "    备份为: ${PLUGIN_DIR}.bak"
  mv "$PLUGIN_DIR" "${PLUGIN_DIR}.bak"
  ln -s "$REPO_DIR" "$PLUGIN_DIR"
  echo "    已创建软链接。"
else
  ln -s "$REPO_DIR" "$PLUGIN_DIR"
  echo "    已创建软链接: $PLUGIN_DIR -> $REPO_DIR"
fi

# 3. 清理旧的 analyze-startup 插件链接
if [[ -L "$OLD_PLUGIN_DIR" ]]; then
  echo ""
  echo "    清理旧链接: $OLD_PLUGIN_DIR"
  rm "$OLD_PLUGIN_DIR"
  echo "    已删除。"
fi

echo ""
echo "==> 安装完成！"
echo "    重启 Claude Code 后，使用 /analyze-startup <trace文件> [包名] 即可。"
echo ""
echo "    当前包含的 Skills:"
echo "      - /analyze-startup  分析 Android 应用启动性能"
