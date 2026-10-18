#!/bin/bash

# 发布 Docker 镜像：同步文档里的镜像名与版本、提交、打 tag 并推送。
#
# 真正的构建发生在 GitHub 上：tag 推送后 .github/workflows/build.yml 会构建
# linux/amd64 + linux/arm64 并推送到 GHCR。本脚本刻意不调用 docker build：
# 生产机通常没有多架构构建环境，而「本机构建再传到服务器」会让线上跑的是
# 一台开发机上的产物，和 git tag 对不上——出问题时无法确认镜像到底来自哪个 commit。

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

VERSION="${1:-}"
BRANCH="$(git branch --show-current)"
DOCS=(README.md docs/docker.md)

usage() {
  echo "用法: $0 <版本号>"
  echo "示例: $0 v0.3.4"
  echo "可选环境变量: IMAGE=ghcr.io/<owner>/emailbox"
}

if [ -z "$VERSION" ]; then
  usage
  exit 1
fi
# 只接受形如 v1.2.3 的 tag：build.yml 监听 v*，版本号里带别的形状会让
# 「git tag 指什么」和「镜像 tag 是什么」逐渐分叉。
if ! [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "❌ 版本号必须形如 v0.3.4（当前: $VERSION）"
  exit 1
fi
if [ "$BRANCH" != "main" ]; then
  echo "❌ 请在 main 分支发布，当前是 $BRANCH"
  exit 1
fi
if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
  echo "❌ tag $VERSION 已存在"
  exit 1
fi

# 默认镜像名从 origin 推导，避免仓库 fork 之后还往原作者的 GHCR 推。
origin_url="$(git remote get-url origin)"
repo_path="$(printf '%s' "$origin_url" | sed -E 's#^.*github\.com[:/]##; s#\.git$##' | tr '[:upper:]' '[:lower:]')"
if [ -z "$repo_path" ]; then
  echo "❌ 无法从 origin ($origin_url) 推导 GitHub 仓库名，可用 IMAGE 覆盖"
  exit 1
fi
IMAGE="${IMAGE:-ghcr.io/${repo_path}}"

# 只允许两个文档文件有未提交改动（脚本自己会提交它们）。
# 其他已跟踪文件的改动必须先处理，否则 release commit 会把无关修改一起带上。
otherChanges="$(git status --porcelain --untracked-files=no | grep -vE " (README\.md|docs/docker\.md)$" || true)"
if [ -n "$otherChanges" ]; then
  echo "❌ 除 ${DOCS[*]} 外还有未提交的改动，请先处理："
  echo "$otherChanges"
  exit 1
fi

echo "📝 更新文档: $IMAGE:$VERSION"
# 只改这两个文件里的镜像名与具体版本号；未跟踪文件（如本地的 CLAUDE.md）不参与提交。
sed -i -E \
  -e "s#ghcr\.io/[A-Za-z0-9_.-]+/emailbox#${IMAGE}#g" \
  -e "s#v[0-9]+\.[0-9]+\.[0-9]+#${VERSION}#g" \
  "${DOCS[@]}"

git add "${DOCS[@]}"
if git diff --cached --quiet; then
  echo "ℹ️  文档已经是 $IMAGE:$VERSION，无需提交"
else
  git commit -m "chore(release): ${VERSION}"
fi

echo "🏷️  创建 tag $VERSION"
git tag -a "$VERSION" -m "Release $VERSION"

echo "🚀 推送 main 与 tag（tag 会触发 GitHub Actions 构建镜像）"
git push origin "$BRANCH"
git push origin "$VERSION"

echo
echo "✅ 已推送 $VERSION。GitHub Actions 将构建并推送："
echo "   $IMAGE:$VERSION"
echo "   查看进度: https://github.com/${repo_path}/actions/workflows/build.yml"
