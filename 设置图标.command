#!/bin/bash
# 给 Codex地址.command 贴上自定义图标（需要 pyobjc）
cd "$(dirname "$0")" || exit 1
TARGET="./Codex地址.command"
ICNS="./assets/icon.icns"

[ -f "$TARGET" ] || { echo "找不到 $TARGET"; read -r -p "回车关闭"; exit 1; }
[ -f "$ICNS" ]   || { echo "找不到 $ICNS";   read -r -p "回车关闭"; exit 1; }

PY=""
for p in "$(command -v python3)" /usr/local/bin/python3 /opt/homebrew/bin/python3; do
  [ -x "$p" ] && "$p" -c "import AppKit" 2>/dev/null && { PY="$p"; break; }
done

if [ -z "$PY" ]; then
  echo "没找到带 pyobjc 的 python3。"
  echo "可以先装： pip3 install pyobjc-framework-Cocoa"
  echo
  echo "或者手动贴图标（不用装任何东西）："
  echo "  1. 用「预览」打开 assets/icon.png，全选、拷贝"
  echo "  2. 选中 Codex地址.command 按 Cmd+I 打开简介"
  echo "  3. 点左上角那个小图标，按 Cmd+V"
  echo
  read -r -p "回车关闭"; exit 1
fi

"$PY" - "$ICNS" "$TARGET" <<'PYEOF'
import sys
from AppKit import NSWorkspace, NSImage
img = NSImage.alloc().initWithContentsOfFile_(sys.argv[1])
ok = NSWorkspace.sharedWorkspace().setIcon_forFile_options_(img, sys.argv[2], 0)
print("图标设置：" + ("成功" if ok else "失败"))
PYEOF

killall Finder 2>/dev/null
echo "访达已刷新。图标没马上出来的话，把文件拖出桌面再拖回来。"
echo
read -r -p "回车关闭"
