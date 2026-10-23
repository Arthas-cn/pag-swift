#!/usr/bin/env python3
"""链接固定 Demo 构建里的同一库，测量解析阶段与 CPU 场景准备；不启动 Demo。"""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
products = Path('/private/tmp/pag-swift-macos-derived/Build/Products/Debug')
command = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6',
           '-enable-upcoming-feature', 'ApproachableConcurrency', '-target', 'arm64-apple-macos26.0',
           '-module-cache-path', '/private/tmp/pag-host-probe-modules', '-I', str(products),
           str(root / 'scripts/CachePerformanceProbe.swift'), str(products / 'pag_swift.o'),
           '-o', '/private/tmp/pag-cache-performance-probe']
subprocess.run(command, check=True)
subprocess.run(['/private/tmp/pag-cache-performance-probe', str(root / 'resources'),
                '/private/tmp/pag-cache-performance-report.json',
                str(products / 'pag-swift-demo.app/Contents/Resources/pag-build.json')], check=True)
