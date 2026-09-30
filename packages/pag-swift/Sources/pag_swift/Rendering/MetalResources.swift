import CoreVideo
import Foundation
import Metal

/// RenderOwner独占的输入资源及LRU；此类型故意不遵循Sendable，裸Metal对象不越过owner。
final class MetalResources {
    /// 创建输入buffer、纹理和管线的唯一设备，所有调用在owner执行域。
    private let device: any MTLDevice
    /// GPU输入与其必要保活源的保守留存预算，零表示不缓存。
    private let byteLimit: Int
    /// 已上传的不可变资源，双向链用值键避免引用环。
    private var entries: [MetalResourceKey: MetalCacheEntry] = [:]
    /// 最近使用的资源，nil表示空缓存。
    private var newest: MetalResourceKey?
    /// 最久未使用的资源，nil表示空缓存。
    private var oldest: MetalResourceKey?
    /// 保守留存字节，淘汰不影响GPU command buffer已经保活的资源。
    private(set) var byteCount = 0
    /// 源路径到不可变CPU网格的缓存，与GPU输入缓存分别有界。
    private var geometryCache: RenderGeometryCache
    /// 共享单位矩形同时提供位置和UV，实际尺寸放进绘制矩阵。
    private let quad: RenderMesh
    /// 首次真正绘制时创建，之后所有帧复用；nil表示尚未编译MSL。
    private var preparedPipelines: MetalPipelines?
    /// 按同一MTLDevice懒建的系统平面导入器；不缓存已完成显示画面。
    private var videoTextureCache: CVMetalTextureCache?
    /// 同owner的局部组附件池，活动纹理仅在GPU结束后归还。
    let groups: MetalGroupPool
    /// 当前留存资源数，仅供内部资源诊断。
    var count: Int { entries.count }

    /// 接收同一owner域内的设备别名；不创建资源或启动任务，非法预算失败。
    init(device: any MTLDevice, byteLimit: Int = 64 * 1024 * 1024) throws {
        guard byteLimit >= 0 else { throw PAGError.invalidArgument("metalCacheBytes") }
        self.device = device
        self.byteLimit = byteLimit
        groups = try MetalGroupPool(device: device)
        geometryCache = try RenderGeometryCache()
        quad = RenderMesh(origin: .zero, vertices: [ScenePoint(x: 0, y: 0), ScenePoint(x: 1, y: 0),
                                                 ScenePoint(x: 1, y: 1), ScenePoint(x: 0, y: 0),
                                                 ScenePoint(x: 1, y: 1), ScenePoint(x: 0, y: 1)])
    }

    /// 编译一次基础管线；取消后不把尚未成功返回的结果安装到缓存。
    func pipelines() throws -> MetalPipelines {
        try Task.checkCancellation()
        if let preparedPipelines { return preparedPipelines }
        let value = try MetalPipelines(device: device)
        try Task.checkCancellation()
        preparedPipelines = value
        return value
    }

    /// 获取共享单位矩形；资源成本在当前帧只计一次。
    func rectangle(budget: inout MetalFrameBudget) throws -> MetalMesh {
        guard let value = try mesh(quad, budget: &budget) else { throw PAGError.renderingFailure("metalUnitQuad") }
        return value
    }

    /// 按最终显示精度复用或生成CPU网格，再上传一次；空轮廓没有GPU资源。
    func geometry(_ source: RenderGeometrySource, transform: SceneAffine,
                  budget: inout MetalFrameBudget) throws -> MetalMesh? {
        var geometryBudget = try GeometryBudget()
        let value = try geometryCache.mesh(for: source, transform: transform, budget: &geometryBudget)
        return try mesh(value, budget: &budget)
    }

    /// 上传已经验证的三角形；先检查Float与字节预算，禁止改写之前已交给GPU的buffer。
    func mesh(_ source: RenderMesh, budget: inout MetalFrameBudget) throws -> MetalMesh? {
        try Task.checkCancellation()
        guard !source.vertices.isEmpty else { return nil }
        guard source.vertices.count % 3 == 0 else { throw PAGError.renderingFailure("metalTriangleCount") }
        let size = UInt128(source.vertices.count) * UInt128(MemoryLayout<MetalVertex>.stride)
        let estimate = size + UInt128(source.estimatedBytes) + 1024 + UInt128(source.vertices.count / 3) * 68
        guard size <= UInt128(device.maxBufferLength), let total = Int(exactly: estimate) else {
            throw PAGError.resourceLimitExceeded("metalBufferBytes")
        }
        let key = MetalResourceKey.mesh(ObjectIdentifier(source))
        if case .mesh(let retained)? = budget.retained(for: key) { return retained }
        if case .mesh(let cached)? = value(for: key) {
            try budget.use(key, bytes: cached.byteCost)
            budget.retain(.mesh(cached), for: key)
            return cached
        }
        // 先按最多2N-1个节点及N个索引计费；不能先分配索引，再发现当前帧没有预算。
        try budget.use(key, bytes: total)
        var coverageBudget = try GeometryBudget()
        let coverage = try RenderCoverageIndex.prepare(source, budget: &coverageBudget)
        var vertices: [MetalVertex] = []
        var bounds: RenderBounds?
        vertices.reserveCapacity(source.vertices.count)
        for point in source.vertices {
            try Task.checkCancellation()
            let value = try MetalDrawUniforms.finite(point.x, point.y, 0, 0)
            let position = SIMD2(value.x, value.y)
            vertices.append(MetalVertex(position: position, textureCoordinate: position))
            // 按实际上传的Float位置包围，包含转换舍入后的边界；只在缓存未命中时遍历。
            let pointBounds = try RenderBounds(left: Double(value.x), top: Double(value.y), right: Double(value.x), bottom: Double(value.y))
            bounds = bounds.map { $0.union(pointBounds) } ?? pointBounds
        }
        let buffer = try makeBuffer(vertices, label: "pag.input.vertices")
        let nodes = try makeBuffer(coverage.nodes, label: "pag.input.coverage.nodes")
        let triangles = try makeBuffer(coverage.triangles, label: "pag.input.coverage.triangles")
        let occupied = UInt128(buffer.allocatedSize) + UInt128(nodes.allocatedSize) + UInt128(triangles.allocatedSize)
            + UInt128(source.estimatedBytes) + 1024
        guard let actual = Int(exactly: occupied) else { throw PAGError.resourceLimitExceeded("metalBufferBytes") }
        let cost = max(total, actual)
        if cost > total { try budget.reserve(cost - total) }
        try Task.checkCancellation()
        guard let bounds else { throw PAGError.renderingFailure("metalMeshBounds") }
        let result = MetalMesh(source: source, buffer: buffer, bounds: bounds, nodes: nodes, triangles: triangles,
                               nodeCount: coverage.nodes.count, byteCost: cost)
        budget.retain(.mesh(result), for: key)
        insert(.mesh(result), for: key, bytes: cost)
        return result
    }

    /// 单帧完整裁剪边只上传一个只读buffer；无额外裁剪也绑定合法占位资源。
    func clipBuffer(_ edges: [SIMD4<Float>], budget: inout MetalFrameBudget) throws -> any MTLBuffer {
        let values = edges.isEmpty ? [SIMD4<Float>.zero] : edges
        let bytes = UInt128(values.count) * UInt128(MemoryLayout<SIMD4<Float>>.stride)
        guard let estimate = Int(exactly: bytes + 512) else {
            throw PAGError.resourceLimitExceeded("metalBufferBytes")
        }
        try budget.reserve(estimate)
        let result = try makeBuffer(values, label: "pag.frame.clip.edges")
        guard let actual = Int(exactly: UInt128(result.allocatedSize) + 512) else {
            throw PAGError.resourceLimitExceeded("metalBufferBytes")
        }
        if actual > estimate { try budget.reserve(actual - estimate) }
        return result
    }

    /// 在同一owner创建不可变输入，保留Metal默认可访问存储模式；创建失败不发布半份资源。
    private func makeBuffer<Value>(_ values: [Value], label: String) throws -> any MTLBuffer {
        try Task.checkCancellation()
        let size = values.count.multipliedReportingOverflow(by: MemoryLayout<Value>.stride)
        guard !size.overflow, size.partialValue > 0, size.partialValue <= device.maxBufferLength else {
            throw PAGError.resourceLimitExceeded("metalBufferBytes")
        }
        let value = values.withUnsafeBytes { bytes in
            bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: []) }
        }
        guard let value else { throw PAGError.renderingFailure("metalInputBufferAllocation") }
        value.label = label
        try Task.checkCancellation()
        return value
    }

    /// RGBA8预乘顶行输入只上传一次；不生成mipmap、不读取GPU像素、不修改已有纹理。
    func image(_ image: PAGImage, budget: inout MetalFrameBudget) throws -> any MTLTexture {
        try Task.checkCancellation()
        let source = image.storage
        guard let width = Int(exactly: source.size.width), let height = Int(exactly: source.size.height),
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              UInt128(width) * UInt128(height) <= 16_777_216,
              source.bytesPerRow == width * 4, source.pixels.count == source.bytesPerRow * height else {
            throw PAGError.resourceLimitExceeded("metalInputPixels")
        }
        let key = MetalResourceKey.image(source.identity)
        let cost = source.pixels.count + 512
        try budget.use(key, bytes: cost)
        if case .image(let retained)? = budget.retained(for: key) { return retained }
        if case .image(let cached)? = value(for: key) {
            budget.retain(.image(cached), for: key)
            return cached
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width,
                                                                 height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        // CPU/GPU共同访问的输入沿Metal设备默认存储模式；不能把本机Apple GPU的shared纹理假设写死到所有Mac。
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw PAGError.renderingFailure("metalInputTextureAllocation")
        }
        texture.label = "pag.input.rgba"
        try source.pixels.withUnsafeBytes { bytes in
            guard let pointer = bytes.baseAddress else { throw PAGError.renderingFailure("metalInputPixelsMissing") }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: pointer, bytesPerRow: source.bytesPerRow)
        }
        try Task.checkCancellation()
        budget.retain(.image(texture), for: key)
        insert(.image(texture), for: key, bytes: cost)
        return texture
    }

    /// 直接导入NV12两平面；同帧/跨帧命中均释放多余交接引用，输入保持只读直到GPU完成。
    func video(_ frame: VideoFrameTransfer, budget: inout MetalFrameBudget) throws -> MetalVideoInput {
        try Task.checkCancellation()
        let key = MetalResourceKey.video(frame.identity)
        if case .video(let retained)? = budget.retained(for: key) {
            frame.discard()
            return retained
        }
        if case .video(let cached)? = value(for: key) {
            try budget.use(key, bytes: cached.byteCost)
            budget.retain(.video(cached), for: key)
            frame.discard()
            return cached
        }
        let estimate = frame.byteCount + 1024
        try budget.use(key, bytes: estimate)
        if videoTextureCache == nil {
            var cache: CVMetalTextureCache?
            let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
            guard status == kCVReturnSuccess, let cache else { throw PAGError.renderingFailure("metalVideoCache:\(status)") }
            videoTextureCache = cache
        }
        guard let cache = videoTextureCache else { throw PAGError.renderingFailure("metalVideoCacheMissing") }
        // CoreVideo要求周期清理。先回收已无使用者的旧映射，活跃包装仍由缓存/当前帧强保活。
        CVMetalTextureCacheFlush(cache, 0)
        let result = try MetalVideoInput(frame, cache: cache)
        if result.byteCost > estimate { try budget.reserve(result.byteCost - estimate) }
        budget.retain(.video(result), for: key)
        insert(.video(result), for: key, bytes: result.byteCost)
        return result
    }

    /// 清掉可重建输入；command buffer和当前编码帧仍保活自己的引用，不会产生悬空指针。
    func removeAll() {
        entries.removeAll()
        newest = nil
        oldest = nil
        byteCount = 0
        geometryCache.removeAll()
        if let videoTextureCache { CVMetalTextureCacheFlush(videoTextureCache, 0) }
    }

    /// 命中后O(1)移到最近使用端，保持其余节点顺序。
    private func value(for key: MetalResourceKey) -> MetalResource? {
        guard let entry = entries[key] else { return nil }
        if key != newest {
            if let previous = entry.previous { entries[previous]?.next = entry.next }
            if let next = entry.next { entries[next]?.previous = entry.previous }
            else { oldest = entry.previous }
            entries[key]?.previous = nil
            entries[key]?.next = newest
            if let newest { entries[newest]?.previous = key }
            newest = key
        }
        return entry.resource
    }

    /// 完整上传后才进入缓存；超大资源由当前帧使用但不留存，零预算不缓存。
    private func insert(_ resource: MetalResource, for key: MetalResourceKey, bytes: Int) {
        guard bytes <= byteLimit else { return }
        while byteCount > byteLimit - bytes, let oldest { remove(oldest) }
        entries[key] = MetalCacheEntry(resource: resource, bytes: bytes, previous: nil, next: newest)
        if let newest { entries[newest]?.previous = key }
        else { oldest = key }
        newest = key
        byteCount += bytes
    }

    /// 淘汰一个节点并修复双向链，只释放缓存所有权。
    private func remove(_ key: MetalResourceKey) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        if let previous = entry.previous { entries[previous]?.next = entry.next }
        else { newest = entry.next }
        if let next = entry.next { entries[next]?.previous = entry.previous }
        else { oldest = entry.previous }
        byteCount -= entry.bytes
    }
}

/// GPU网格保活原始CPU对象，防止按地址缓存时对象释放后身份被复用。
final class MetalMesh {
    /// 不可变三角形及原点，CPU来源保持有效直到GPU缓存淘汰。
    let source: RenderMesh
    /// 已完成初始化且之后不再修改的输入顶点buffer。
    let buffer: any MTLBuffer
    /// 相对source.origin的保守顶点范围，逐帧只变换四角。
    let bounds: RenderBounds
    /// 与源网格同生命周期的只读BVH节点，不因平移或颜色变化重建。
    let nodes: any MTLBuffer
    /// 每个叶子引用的源三角形序号。
    let triangles: any MTLBuffer
    /// 节点数组有效长度，供无栈遍历的终止条件。
    let nodeCount: Int
    /// 源保活和三个GPU输入buffer的保守成本，缓存命中也按此检查帧预算。
    let byteCost: Int

    /// 仅在同一owner隔离域中组合完整顶点、查询索引和已核算成本。
    init(source: RenderMesh, buffer: any MTLBuffer, bounds: RenderBounds, nodes: any MTLBuffer,
         triangles: any MTLBuffer, nodeCount: Int, byteCost: Int) {
        self.source = source
        self.buffer = buffer
        self.bounds = bounds
        self.nodes = nodes
        self.triangles = triangles
        self.nodeCount = nodeCount
        self.byteCost = byteCost
    }
}

/// GPU输入身份；网格键依赖保活对象，图片键依赖完整编码内容摘要。
enum MetalResourceKey: Hashable {
    /// 对应MetalMesh.source的对象地址，来源由条目强持有。
    case mesh(ObjectIdentifier)
    /// 同一编码内容和元数据产生相同不可变输入。
    case image(DocumentIdentity)
    /// 完整视频序列与实际PTS，避免复用不同时间或alpha布局的输入。
    case video(VideoFrameID)
}

/// 一帧的去重保活与暂存计费，独立于跨帧LRU留存预算。
struct MetalFrameBudget {
    /// 当前帧唯一资源集合，避免同一glyph反复出现时重复计费。
    private var resources: Set<MetalResourceKey> = []
    /// 同帧输入强引用；即使跨帧LRU禁用或淘汰，同一来源也不能再次上传并绕过去重预算。
    private var inputs: [MetalResourceKey: MetalResource] = [:]
    /// 聚合输入资源和绘制暂存的保守成本。
    private var budget: FramePlanBudget

    /// 默认64MiB；非法限制明确拒绝。
    init(maximumBytes: Int = 64 * 1024 * 1024) throws {
        guard maximumBytes > 0 else { throw PAGError.invalidArgument("maximumMetalFrameBytes") }
        budget = FramePlanBudget(limit: maximumBytes, resourceName: "maximumMetalFrameBytes")
    }

    /// 首次使用一个输入前计费，成功后才记录已计费身份。
    mutating func use(_ key: MetalResourceKey, bytes: Int) throws {
        try Task.checkCancellation()
        guard !resources.contains(key) else { return }
        try budget.reserve(stride: bytes)
        try budget.reserve(stride: 128)
        resources.insert(key)
    }

    /// 返回本帧已经保活的输入，独立于跨帧LRU状态。
    fileprivate func retained(for key: MetalResourceKey) -> MetalResource? { inputs[key] }

    /// 已经预留预算且上传完成后保活唯一输入，后续同帧绘制共享它。
    fileprivate mutating func retain(_ resource: MetalResource, for key: MetalResourceKey) { inputs[key] = resource }

    /// 为绘制/裁剪数组增长预留成本；不把源像素复制到逐帧计划。
    mutating func reserve(_ bytes: Int) throws {
        try Task.checkCancellation()
        try budget.reserve(stride: bytes)
    }
}

/// 裸GPU输入只在owner内使用，不标记Sendable，保活策略随输入类型不同。
private enum MetalResource {
    /// 顶点buffer以及缓存身份所需的CPU网格。
    case mesh(MetalMesh)
    /// 不可变RGBA输入纹理，内容身份不需要保活原像素数组。
    case image(any MTLTexture)
    /// 保活原始系统帧及两个CoreVideo包装，不能只留下MTLTexture。
    case video(MetalVideoInput)
}

/// GPU LRU节点，条目只负责缓存所有权，不负责正在执行帧的结束。
private struct MetalCacheEntry {
    /// 已经完成上传的不可变GPU输入。
    let resource: MetalResource
    /// 正保守计费，包含必要CPU来源和元数据。
    let bytes: Int
    /// 更近使用节点，头部为nil。
    var previous: MetalResourceKey?
    /// 更早使用节点，尾部为nil。
    var next: MetalResourceKey?
}
