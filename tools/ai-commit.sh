#!/usr/bin/env bash
# ai-commit — 多模型协作的提交身份助手
#
# 每个 AI 模型提交时必须使用自己厂商的身份（Author 与 Committer 一致），
# 并自动追加 Co-authored-by: 尾注。
#
# 用法:
#   tools/ai-commit.sh <glm|deepseek|gpt> [git commit 的参数...]
# 例:
#   tools/ai-commit.sh glm -m "port: lower deployment target to 15.6"
#
# 身份对照表（与工作区 docs/HANDOFF.md 保持同步）:
#   glm       → GLM      <noreply@z.ai>        (智谱)
#   deepseek  → DeepSeek <noreply@deepseek.com>
#   gpt       → ChatGPT  <noreply@openai.com>  (OpenAI)
#
# 人类提交请直接用 git commit（走你自己的全局身份）；若改动有 AI 参与，
# 建议在提交信息末尾加 Co-authored-by: <模型> <对应邮箱>。
set -euo pipefail

case "${1:-}" in
  glm)      NAME="GLM";      EMAIL="noreply@z.ai" ;;
  deepseek) NAME="DeepSeek"; EMAIL="noreply@deepseek.com" ;;
  gpt|chatgpt) NAME="ChatGPT"; EMAIL="noreply@openai.com" ;;
  *)
    echo "用法: tools/ai-commit.sh <glm|deepseek|gpt> [git commit 参数...]" >&2
    echo "身份表见文件头注释或 docs/HANDOFF.md（工作区文档）" >&2
    exit 1
    ;;
esac
shift

export GIT_AUTHOR_NAME="$NAME"      GIT_AUTHOR_EMAIL="$EMAIL"
export GIT_COMMITTER_NAME="$NAME"   GIT_COMMITTER_EMAIL="$EMAIL"
export AI_COMMIT=1

exec git commit --trailer "Co-authored-by: $NAME <$EMAIL>" "$@"
