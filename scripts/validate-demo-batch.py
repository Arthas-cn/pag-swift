#!/usr/bin/env python3
"""复用当前固定构建，串行验证真实 Demo 批播模型；只挂载一次临时 drawable。"""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
products = Path('/private/tmp/pag-swift-macos-derived/Build/Products/Debug')
source = root / 'app/pag-swift-demo/pag-swift-demo'
files = ['DemoResourceCatalog.swift', 'DemoSession.swift', 'DemoReport.swift', 'DemoBatchView.swift']
command = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6',
           '-enable-upcoming-feature', 'ApproachableConcurrency', '-target', 'arm64-apple-macos26.0',
           '-module-cache-path', '/private/tmp/pag-host-probe-modules', '-I', str(products)]
command += [str(source / name) for name in files]
command += [str(root / 'scripts/DemoBatchProbe.swift'), str(products / 'pag_swift.o'),
            '-o', '/private/tmp/pag-demo-batch-probe']
subprocess.run(command, check=True)
subprocess.run(['/private/tmp/pag-demo-batch-probe', str(root / 'resources'),
                '/private/tmp/pag-demo-batch-report.json'], check=True)
