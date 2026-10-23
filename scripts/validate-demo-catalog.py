#!/usr/bin/env python3
"""复用当前构建的库，验证 Demo 目录和预览拥有关系；不启动 Demo 或创建窗口。"""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
products = Path('/private/tmp/pag-swift-macos-derived/Build/Products/Debug')
source = root / 'app/pag-swift-demo/pag-swift-demo'
# 这些文件只组织宿主生命周期；探针直接调用它们，避免复制另一份目录或可见性调度逻辑。
files = ['DemoResourceCatalog.swift', 'DemoCatalogModel.swift', 'DemoSession.swift', 'DemoReport.swift']
command = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6',
           '-enable-upcoming-feature', 'ApproachableConcurrency', '-target', 'arm64-apple-macos26.0',
           '-module-cache-path', '/private/tmp/pag-host-probe-modules', '-I', str(products)]
command += [str(source / name) for name in files]
command += [str(root / 'scripts/DemoCatalogProbe.swift'), str(products / 'pag_swift.o'),
            '-o', '/private/tmp/pag-demo-catalog-probe']
subprocess.run(command, check=True)
subprocess.run(['/private/tmp/pag-demo-catalog-probe', str(root / 'resources'),
                '/private/tmp/pag-demo-catalog-report.json'], check=True)
