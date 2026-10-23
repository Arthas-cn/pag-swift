#!/usr/bin/env python3
"""同一固定构建对比正常与慢 SD 解码下的实时帧准备，不启动 Demo App。"""
from pathlib import Path
import subprocess

# 仓库和构建路径明确固定；这里只编译本地探针，不修改第三方检出或包依赖。
root = Path(__file__).resolve().parents[1]
derived = Path('/private/tmp/pag-swift-macos-derived')
products = derived / 'Build/Products/Debug'
maps = derived / 'Build/Intermediates.noindex/GeneratedModuleMaps'
checkouts = derived / 'SourcePackages/checkouts'
command = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6',
           '-enable-upcoming-feature', 'ApproachableConcurrency', '-target', 'arm64-apple-macos26.0',
           '-module-cache-path', '/private/tmp/pag-host-probe-modules', '-I', str(products)]
for module in ['SDWebImage', 'libwebp', 'SDWebImageWebPCoder']:
    command += ['-Xcc', f'-fmodule-map-file={maps / (module + ".modulemap")}']
for include in ['SDWebImage/SDWebImage/include', 'libwebp-Xcode/include',
                'SDWebImageWebPCoder/SDWebImageWebPCoder/Classes']:
    command += ['-Xcc', '-I' + str(checkouts / include)]
command += [str(root / 'app/pag-swift-demo/pag-swift-demo/DemoSDWebImageSource.swift'),
            str(root / 'scripts/AnimatedPlaybackProbe.swift')]
command += [str(products / (module + '.o')) for module in ['pag_swift', 'SDWebImage', 'SDWebImageWebPCoder', 'libwebp']]
command += ['-Xlinker', '-ObjC', '-o', '/private/tmp/pag-animated-playback-probe']
subprocess.run(command, check=True)
subprocess.run(['/private/tmp/pag-animated-playback-probe', str(root / 'resources'),
                '/private/tmp/pag-animated-playback-report.json'], check=True)
