#!/usr/bin/env bash
# install.sh — 将本仓库安装为 Claude Code 插件
#
# 操作:
#   1. 将仓库目录软链接到 ~/.claude/plugins/local/analyze-startup
#   2. 将 commands/*.md 软链接到 ~/.claude/commands/（Claude Code 自定义命令目录）

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$HOME/.claude/plugins/local/analyze-startup"
COMMANDS_DIR="$HOME/.claude/commands"

echo "==> 安装 android-performance-skills 插件"
echo "    仓库路径: $REPO_DIR"
echo ""

# 1. 创建目录（如果不存在）
mkdir -p "$(dirname "$PLUGIN_DIR")"
mkdir -p "$COMMANDS_DIR"

# 2. 插件目录软链接
echo "--- 插件目录 ---"
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

# 3. 将 commands/ 下的 .md 文件链接到 ~/.claude/commands/
echo ""
echo "--- 自定义命令 ---"
for cmd_file in "$REPO_DIR"/commands/*.md; do
  [[ -f "$cmd_file" ]] || continue
  cmd_name="$(basename "$cmd_file")"
  target="$COMMANDS_DIR/$cmd_name"
  if [[ -L "$target" ]]; then
    CURRENT_TARGET="$(readlink -f "$target")"
    if [[ "$CURRENT_TARGET" == "$(readlink -f "$cmd_file")" ]]; then
      echo "    $cmd_name — 已存在，跳过。"
    else
      rm "$target"
      ln -s "$cmd_file" "$target"
      echo "    $cmd_name — 已更新。"
    fi
  else
    [[ -f "$target" ]] && mv "$target" "${target}.bak"
    ln -s "$cmd_file" "$target"
    echo "    $cmd_name — 已链接。"
  fi
done

echo ""
echo "==> 安装完成！"
echo "    重启 Claude Code 后，使用 /analyze-startup <trace文件> [包名] 即可。"
echo ""
echo "    当前包含的 Skills:"
for cmd_file in "$REPO_DIR"/commands/*.md; do
  [[ -f "$cmd_file" ]] || continue
  cmd_name="$(basename "$cmd_file" .md)"
  echo "      - /$cmd_name"
done
