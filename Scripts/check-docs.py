#!/usr/bin/env python3
"""检查产品首页及其维护文档的本地链接和配图，不访问网络或修改文件。"""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit
import re
import sys
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
DOCUMENTS = ["README.md", "README.zh-CN.md", "docs/TRUST_AND_TESTING.md",
             "docs/images/README.md", "docs/DEVELOPMENT.md", "docs/RELEASING.md",
             "docs/audio-capture-permission.md", "docs/AUDIO_LIFECYCLE.md"]


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.targets = []
        self.anchors = set()
        self.errors = []

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        for key in ("href", "src"):
            if values.get(key):
                self.targets.append(values[key])
        if values.get("id"):
            self.anchors.add(values["id"])
        if tag == "img" and not values.get("alt", "").strip():
            self.errors.append("图片缺少替代文本")


def anchors(path):
    text = path.read_text()
    result = set()
    occurrences = {}
    for heading in re.findall(r"^#{1,6}\s+(.+?)\s*$", text, re.M):
        # 与当前文档使用的 GitHub 标题规则一致：去掉标记、保留字母数字与连字符。
        heading = re.sub(r"[`*_]", "", heading).lower()
        slug = "".join(c for c in heading if c.isalnum() or c in " -_").replace(" ", "-")
        count = occurrences.get(slug, 0)
        occurrences[slug] = count + 1
        result.add(slug if count == 0 else f"{slug}-{count}")
    parser = Links()
    parser.feed(text)
    return result | parser.anchors


errors = []
for document in DOCUMENTS:
    path = ROOT / document
    text = path.read_text()
    parser = Links()
    parser.feed(text)
    errors.extend(f"{document}: {error}" for error in parser.errors)
    markdown_targets = re.findall(r"!?\[[^\]]*\]\(([^\s)]+)\)", text)
    for target in set(parser.targets + markdown_targets):
        url = urlsplit(target)
        if url.scheme or url.netloc:
            continue
        local = (path.parent / unquote(url.path)).resolve() if url.path else path
        if not local.is_relative_to(ROOT):
            errors.append(f"{document}: 链接超出仓库 {target}")
        elif not local.exists():
            errors.append(f"{document}: 文件不存在 {target}")
        elif subprocess.run(["git", "check-ignore", "-q", str(local)], cwd=ROOT).returncode == 0:
            errors.append(f"{document}: 文件被 Git 忽略，线上不会包含 {target}")
        elif url.fragment and local.suffix == ".md" and unquote(url.fragment) not in anchors(local):
            errors.append(f"{document}: 标题锚点不存在 {target}")

for path in (ROOT / "docs/images").glob("*.svg"):
    try:
        svg = ET.parse(path).getroot()
        if svg.tag != "{http://www.w3.org/2000/svg}svg":
            errors.append(f"{path.name}: 不是 SVG 根节点")
        if svg.find("{http://www.w3.org/2000/svg}title") is None:
            errors.append(f"{path.name}: 缺少可访问标题")
    except ET.ParseError as error:
        errors.append(f"{path.name}: SVG 格式错误 {error}")

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"文档检查通过：{len(DOCUMENTS)} 份文档的本地链接、发布白名单、标题锚点、图片替代文本与 SVG。")
