#if os(macOS)
import AppKit
import Dispatch
import Metal
import Testing
@testable import pag_swift

/// 只用于读取实际窗口drawable的测试桥；租约串行化私有layer的跨域访问。
/// unchecked的依据与生产显示桥一致：主actor变更与后台绘制不重叠，裸layer从不泄漏。
final class MetalStrokePixelTarget: @unchecked Sendable {
    /// 唯一测试显示层；只有测试配置允许blit读取，生产DisplayTargetBox保持framebufferOnly=true。
    private let layer: CAMetalLayer
    /// 真实窗口中的点尺寸；默认小视图供描边专项复用。
    let width: Int
    /// 点高度与本帧显示几何一致。
    let height: Int
    /// 测试渲染倍率；放大真实素材的细描边以区分完整覆盖像素。
    let scale: Int
    /// 主actor挂载和测试owner绘制共用的生产租约机制。
    let mailbox = DisplayTargetMailbox()

    /// 主actor记录正点尺寸/整数倍率并创建图层；配置、GPU输入准备和绘制由后台测试owner执行。
    @MainActor init(width: Int = 100, height: Int = 100, scale: Int = 1) {
        precondition(width > 0 && height > 0 && scale > 0)
        layer = CAMetalLayer()
        self.width = width
        self.height = height
        self.scale = scale
    }

    /// 当前drawable宽度，供测试像素点边界与批次配置共用。
    var pixelWidth: Int { width * scale }

    /// 当前drawable高度，尺寸只在主actor挂载前确定。
    var pixelHeight: Int { height * scale }

    /// 在独占配置租约内启用测试诊断；不创建离屏颜色附件。
    func configure(device: any MTLDevice, mutation: UUID, on owner: isolated MetalStrokePixelOwner) throws {
        let lease = try #require(mailbox.acquireConfiguration(for: mutation))
        defer { mailbox.release(lease) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.isOpaque = false
        layer.drawableSize = CGSize(width: pixelWidth, height: pixelHeight)
        layer.maximumDrawableCount = 2
        layer.allowsNextDrawableTimeout = true
        layer.presentsWithTransaction = false
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    }

    /// 配置排空后挂入真实窗口；后续直到close均不再修改层树或尺寸。
    @MainActor func mount(to parent: CALayer, mutation: UUID) throws {
        let lease = try #require(mailbox.acquireMainMutation(for: mutation))
        defer { mailbox.release(lease) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = CGRect(x: 0, y: 0, width: width, height: height)
        layer.contentsScale = CGFloat(scale)
        parent.addSublayer(layer)
        CATransaction.commit()
    }

    /// 后台获取真实显示drawable；调用方保留租约到GPU完成，不返回裸drawable。
    func withDrawable(lease: DisplayTargetLease, on owner: isolated MetalStrokePixelOwner,
                      _ body: (any CAMetalDrawable) throws -> Void) throws {
        try #require(mailbox.isCurrent(lease))
        try autoreleasepool {
            let drawable = try #require(layer.nextDrawable(), "真实窗口必须提供drawable")
            try body(drawable)
        }
    }

    /// 永久关闭后排空GPU租约再拆层，异常路径也必须调用。
    @MainActor func close() async {
        mailbox.close()
        await mailbox.waitUntilReleased()
        layer.removeFromSuperlayer()
    }
}

/// 仅测试的少量像素探针；实际batch直接写窗口drawable，blit只是验证结果的附加诊断。
actor MetalStrokePixelOwner {
    /// nextDrawable可能阻塞，使用专用队列，不占用主线程或Swift协作线程。
    nonisolated private let executor = DispatchSerialQueue(label: "pag.tests.stroke.pixels")
    /// 将所有裸GPU对象固定在同一测试执行域。
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    /// 断开调用域别名后接收的设备。
    private let device: any MTLDevice
    /// 跨测试帧使用同一组生产输入缓存；nil表示尚未准备首帧。
    private var resources: MetalResources?
    /// GPU完成等待期间仍占用，防止actor重入提交第二份测试帧。
    private var isRendering = false
    /// 最近一帧真实局部Picture pass数，命中时为零。
    private(set) var lastPicturePasses = 0
    /// 最近一帧所有Metal draw数，包含局部pass和drawable。
    private(set) var lastDrawCount = 0
    /// 已完成且仍留存的Picture纹理数量；读取始终在测试owner域。
    var retainedPictureCount: Int { resources?.pictures.count ?? 0 }

    /// 只转交所有权，输入缓存按真实需要创建。
    init(device: sending any MTLDevice) { self.device = device }

    /// 后台配置测试layer，调用者随后才允许主actor挂载。
    func configure(_ target: MetalStrokePixelTarget, mutation: UUID) throws {
        #expect(!Thread.isMainThread)
        try target.configure(device: device, mutation: mutation, on: self)
    }

    /// 直接绘制并等待GPU完成，返回指定整像素的预乘RGBA8；不返回纹理或图片产物。
    func pixels(_ frame: PreparedFrame, target: MetalStrokePixelTarget,
                at points: [SIMD2<Int>], enablePictures: Bool = false,
                disablePictureCache: Bool = false, revision: UInt64 = 0) async throws -> [SIMD4<UInt8>] {
        // 文字路径的细字形可能避开稀疏探针；测试允许一张256×256画面上的64×64采样网格。
        try #require(!isRendering && !points.isEmpty && points.count <= 4_096)
        try #require(points.allSatisfy { $0.x >= 0 && $0.x < target.pixelWidth &&
                                        $0.y >= 0 && $0.y < target.pixelHeight })
        isRendering = true
        defer { isRendering = false }
        dispatchPrecondition(condition: .onQueue(executor))
        let geometry = try DisplayGeometry(size: PAGSize(width: Double(target.width),
                                                         height: Double(target.height)), scale: Double(target.scale))
        let lease = try #require(target.mailbox.acquireDrawing(for: target.mailbox.snapshot.epoch))
        defer { target.mailbox.release(lease) }
        let resources: MetalResources
        if let existing = self.resources { resources = existing }
        else {
            resources = try MetalResources(device: device)
            self.resources = resources
        }
        let batch = try MetalFramePreparation.prepare(frame, width: target.pixelWidth,
                                                      height: target.pixelHeight, resources: resources,
                                                      revision: revision, disablePictureCache: disablePictureCache,
                                                      pictures: enablePictures ? resources.pictures : nil)
        lastPicturePasses = batch.pictureWorks.count
        lastDrawCount = batch.drawCount
        // GPU回调结束后才归还组附件和输入；读取结果不能提前释放仍在执行的批次。
        defer { withExtendedLifetime(batch) { batch.releaseTransients() } }
        try #require(batch.passes.last?.attachment == nil)
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let output = try #require(device.makeBuffer(length: points.count * 256, options: .storageModeShared))
        try target.withDrawable(lease: lease, on: self) { drawable in
            try batch.encode(to: drawable, commandBuffer: command, geometry: geometry)
            let blit = try #require(command.makeBlitCommandEncoder())
            // 每个点只读一个像素，256字节步长满足Metal对齐；生产源码没有此诊断命令。
            for (index, point) in points.enumerated() {
                blit.copy(from: drawable.texture, sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: point.x, y: point.y, z: 0), sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                    to: output, destinationOffset: index * 256, destinationBytesPerRow: 256, destinationBytesPerImage: 256)
            }
            blit.endEncoding()
            command.present(drawable)
        }
        let completed = await withCheckedContinuation { continuation in
            command.addCompletedHandler { result in continuation.resume(returning: result.status == .completed) }
            command.commit()
        }
        try #require(completed, "实际drawable诊断命令必须执行成功")
        batch.publishPictures()
        let bytes = output.contents().bindMemory(to: UInt8.self, capacity: output.length)
        return points.indices.map { index in
            let offset = index * 256
            return SIMD4(bytes[offset + 2], bytes[offset + 1], bytes[offset], bytes[offset + 3])
        }
    }
}
#endif
