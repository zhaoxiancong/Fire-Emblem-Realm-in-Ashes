#!/usr/bin/env bash
# 构建框架所有宿主机工具
set -u
cd /home/shanhe/projects/fireemblem8-expansion || exit 1

echo "=== 需要构建的工具目录 ==="
for d in tools/*/; do
  name=$(basename "$d")
  [ "$name" = "gba-playtest" ] && continue
  if [ -f "$d/Makefile" ]; then
    echo "  [有 Makefile] $name"
  else
    echo "  [无 Makefile] $name"
  fi
done

echo ""
echo "=== 逐个构建 ==="
for d in tools/*/; do
  name=$(basename "$d")
  [ "$name" = "gba-playtest" ] && continue
  [ -f "$d/Makefile" ] || continue
  echo ""
  echo "--- make -C tools/$name ---"
  make -C "tools/$name" 2>&1 | tail -6
done

echo ""
echo "=== 产物清单 ==="
find tools -maxdepth 2 -type f -executable -not -name "*.sh" -not -name "*.py" | sort
