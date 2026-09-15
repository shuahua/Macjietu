#!/usr/bin/env python3
"""本地流式提取预算证据，只输出白名单数值，不输出路径或日志正文。"""
import argparse
import json
import re
import sys


def extract(lines):
    keys = {"frames", "width", "frameHeight", "outputHeight", "diskBytes",
            "memoryLimit", "frameBytes", "outputBytes", "previewBytes",
            "matchingBytes", "renderingBytes", "peakBytes", "measured", "limit"}
    categories = {"accepted", "frame_count", "temporary_disk_bytes", "output_height",
                  "output_pixels", "working_memory_bytes"}
    for number, line in enumerate(lines, 1):
        if "long budget " not in line:
            continue
        row = {"line": number}
        if " json=" in line:
            try:
                data = json.loads(line.split(" json=", 1)[1])
            except (ValueError, TypeError):
                continue
            if not isinstance(data, dict):
                continue
            row.update({k: v for k, v in data.items() if k in keys and type(v) in (int, float)})
            if data.get("category") in categories:
                row["category"] = data["category"]
        else:
            match = re.search(r"frames=(\d+) output=(\d+)x(\d+) diskBytes=(\d+)", line)
            if not match:
                continue
            row.update(zip(("frames", "width", "outputHeight", "diskBytes"), map(int, match.groups())))
            row["category"] = "legacy_unspecified"
        yield row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", help="输入日志；使用 - 从标准输入读取")
    args = parser.parse_args()
    try:
        if args.log == "-":
            rows = extract(sys.stdin)
            for row in rows:
                print(json.dumps(row, ensure_ascii=False, allow_nan=False))
        else:
            with open(args.log, encoding="utf-8", errors="replace") as stream:
                for row in extract(stream):
                    print(json.dumps(row, ensure_ascii=False, allow_nan=False))
    except (OSError, ValueError):
        parser.exit(1, "无法读取输入或预算数值无效，请检查文件与格式。\n")


if __name__ == "__main__":
    main()
