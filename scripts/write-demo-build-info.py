#!/usr/bin/env python3
"""给每次 Demo 构建写入独立构建身份和工具链条件，不读取 git 凭据或修改源文件。"""
from datetime import datetime, timezone
from pathlib import Path
import hashlib
import json
import os
import sys
import uuid

root = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2])
# 只读取脚本声明的四个输入文件；保留 Xcode 脚本沙箱，不为诊断放宽整个源码树访问。
# UUID 区分每个实际构建，配置摘要仅说明编译/依赖配置相同，不能冒充完整源码摘要。
files = [root / 'Package.swift', Path(__file__).resolve(),
         root / 'app/pag-swift-demo/pag-swift-demo.xcodeproj/project.pbxproj',
         root / 'app/pag-swift-demo/pag-swift-demo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved']
digest = hashlib.sha256()
for source in sorted(files):
    digest.update(str(source.relative_to(root)).encode('utf-8') + b'\0')
    digest.update(source.read_bytes())
    digest.update(b'\0')
value = {'buildID': str(uuid.uuid4()), 'configurationSHA256': digest.hexdigest(), 'builtAt': datetime.now(timezone.utc).isoformat(),
         'configuration': os.environ.get('CONFIGURATION', 'unknown'),
         'sdk': os.environ.get('SDK_NAME', 'unknown'),
         'xcodeBuildVersion': os.environ.get('XCODE_PRODUCT_BUILD_VERSION', 'unknown')}
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
