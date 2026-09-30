import Foundation
import Metal
import QuartzCore

/// 唯一的裸显示层桥；租约串行化主 actor 层树操作和后台 owner 访问，不接受外部 Metal 层。
/// unchecked 只在本桥用租约证明跨域访问不重叠，不宣称 CAMetalLayer 本身是 Sendable。
final class DisplayTargetBox: @unchecked Sendable {
    /// 唯一私有显示层；初始化后不得通过返回值、属性或回调向主 actor 以外泄漏别名。
    private let layer: CAMetalLayer
    /// Sendable 值状态与异步排空屏障，持锁操作不触碰 layer。
    let mailbox: DisplayTargetMailbox

    /// 在主 actor 创建尚未挂载的透明层，后台配置完成之前不能激活绘制。
    @MainActor init(observe: (@Sendable (DisplayTargetEvent) -> Void)? = nil) {
        layer = CAMetalLayer()
        layer.isOpaque = false
        layer.anchorPoint = .zero
        layer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
        mailbox = DisplayTargetMailbox(observe: observe)
    }

    /// 等旧访问归还后挂到普通父层；事务失效返回 false，不更改旧宿主。
    @MainActor func mount(to parent: CALayer, mutation: UUID) -> Bool {
        guard let lease = mailbox.acquireMainMutation(for: mutation) else { return false }
        defer { mailbox.release(lease) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeFromSuperlayer()
        parent.addSublayer(layer)
        CATransaction.commit()
        return true
    }

    /// 仅修改主 actor 的层几何；drawableSize 留给后台 owner 在新租约内应用。
    @MainActor func resize(to geometry: DisplayGeometry, mutation: UUID) -> Bool {
        guard let lease = mailbox.acquireMainMutation(for: mutation) else { return false }
        defer { mailbox.release(lease) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = CGRect(x: 0, y: 0, width: geometry.size.width, height: geometry.size.height)
        layer.contentsScale = geometry.scale
        CATransaction.commit()
        return true
    }

    /// 显式卸载但允许之后重新挂载；调用者随后提交 isMounted=false 的同一事务。
    @MainActor func unmount(mutation: UUID) -> Bool {
        guard let lease = mailbox.acquireMainMutation(for: mutation) else { return false }
        defer { mailbox.release(lease) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeFromSuperlayer()
        CATransaction.commit()
        return true
    }

    /// 永久关闭的异步兜底；不能在 deinit 中同步等 GPU，也不能在租约未归还时拆层。
    @MainActor func shutdown() async {
        mailbox.close()
        await mailbox.waitUntilReleased()
        // close 不可逆，排空之后没有新访问能进入，因此移除不需要再取得普通事务租约。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeFromSuperlayer()
        CATransaction.commit()
    }

    /// 只在 owner 隔离域、有效配置租约内设置渲染属性；不返回裸 device 或 layer。
    func configure(device: any MTLDevice, lease: DisplayTargetLease, on owner: isolated RenderOwner) throws {
        guard lease.kind == .configuration, mailbox.isCurrent(lease) else { throw CancellationError() }
        // owner使用Dispatch工作线程，没有run loop代为提交隐式事务；配置必须同步完成显式事务。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.device = device
        layer.framebufferOnly = true
        layer.pixelFormat = .bgra8Unorm
        layer.maximumDrawableCount = 2
        layer.allowsNextDrawableTimeout = true
        layer.presentsWithTransaction = false
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    }

    /// 在专用 owner 借用 drawable 编码，返回是否取得有效目标；body 不得保存跨域别名。
    /// 调用者持有绘制租约直至对应 GPU 完成，nil/失败路径也必须归还租约。
    func withDrawable(lease: DisplayTargetLease, on owner: isolated RenderOwner,
                      _ body: (any CAMetalDrawable) throws -> Void) rethrows -> Bool {
        guard !Task.isCancelled, case .drawing(let geometry) = lease.kind, mailbox.isCurrent(lease) else { return false }
        return try autoreleasepool {
            let size = CGSize(width: geometry.pixelWidth, height: geometry.pixelHeight)
            if layer.drawableSize != size {
                // 只包住属性更新，在可能等待drawable之前结束事务，不跨GPU等待持有CA事务。
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.drawableSize = size
                CATransaction.commit()
            }
            // nextDrawable 可阻塞，只能在 owner 的 Dispatch executor 上调用；值锁已经释放。
            guard let drawable = layer.nextDrawable(), !Task.isCancelled, mailbox.isCurrent(lease) else { return false }
            try body(drawable)
            return true
        }
    }
}
