#!/usr/bin/env python3
"""拆分固定构建库的复杂矢量 CPU 准备成本；不启动 Demo 或伪造呈现结果。"""
from pathlib import Path
import argparse
import subprocess

# 与当前正式 Demo 构建复用同一库对象；探针不引入上游或参考项目依赖。
root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--configuration', choices=['Debug', 'Release'], default='Debug')
options = parser.parse_args()
products = Path('/private/tmp/pag-swift-macos-derived/Build/Products') / options.configuration
report = '/private/tmp/pag-vector-preparation-report.json' if options.configuration == 'Debug' else '/private/tmp/pag-vector-release-report.json'
command = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6',
           '-enable-upcoming-feature', 'ApproachableConcurrency', '-target', 'arm64-apple-macos26.0',
           '-module-cache-path', '/private/tmp/pag-host-probe-modules', '-I', str(products),
           str(root / 'scripts/VectorPreparationProbe.swift'), str(products / 'pag_swift.o'),
           '-o', '/private/tmp/pag-vector-preparation-probe']
subprocess.run(command, check=True)
subprocess.run(['/private/tmp/pag-vector-preparation-probe', str(root / 'resources'),
                report, str(products / 'pag-swift-demo.app/Contents/Resources/pag-build.json')], check=True)
