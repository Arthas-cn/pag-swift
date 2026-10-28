import Foundation
import Metal

/// RenderOwner独占的局部透明组附件池；只复用已经结束的GPU工作所归还的纹理。
final class MetalGroupPool {
    /// 与最终drawable、输入缓存相同的设备。
    private let device: any MTLDevice
    /// 空闲纹理留存上限；零表示不留存。
    private let freeLimit: Int
    /// 所有尚未归还借用的聚合上限，防止多帧准备绕过逐帧预算。
    private let activeLimit: Int
    /// 每次借用都有独立身份；纹理复用也不能复用旧身份。
    private var active: [UUID: MetalGroupAttachment] = [:]
    /// 空闲纹理O(1)双向LRU节点。
    private var free: [UUID: MetalFreeGroup] = [:]
    /// 精确尺寸索引，不遍历整池查找。
    private var sizes: [MetalGroupSize: Set<UUID>] = [:]
    /// 最近归还节点，空池为nil。
    private var newest: UUID?
    /// 最久未使用节点，超过空闲预算先淘汰它。
    private var oldest: UUID?
    /// 尚未结束借用的保守字节数。
    private(set) var activeBytes = 0
    /// 当前空闲池的保守字节数。
    private(set) var freeBytes = 0

    /// 验证预算；设备仅留在调用owner域，不声明Sendable。
    init(device: any MTLDevice, freeLimit: Int = 64 * 1024 * 1024, activeLimit: Int = 64 * 1024 * 1024) throws {
        guard freeLimit >= 0, activeLimit > 0 else { throw PAGError.invalidArgument("metalGroupPoolBytes") }
        self.device = device
        self.freeLimit = freeLimit
        self.activeLimit = activeLimit
    }

    /// 按精确尺寸借用附件；先预留像素下界，创建后校验实际分配，失败不发布活动借用。
    func acquire(width: Int, height: Int, budget: inout MetalFrameBudget) throws -> MetalGroupAttachment {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              UInt128(width) * UInt128(height) <= 16_777_216 else {
            throw PAGError.resourceLimitExceeded("metalGroupDimensions")
        }
        let size = MetalGroupSize(width: width, height: height)
        let cachedID = sizes[size]?.first
        let estimate = cachedID.flatMap { free[$0]?.loan.byteCount } ?? (width * height * 4 + 512)
        guard estimate <= activeLimit, activeBytes <= activeLimit - estimate else {
            throw PAGError.resourceLimitExceeded("maximumActiveMetalGroupBytes")
        }
        try budget.reserve(estimate)
        let texture: any MTLTexture
        if let cachedID, let cached = removeFree(cachedID) { texture = cached.texture }
        else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead]
            guard let created = device.makeTexture(descriptor: descriptor) else {
                throw PAGError.renderingFailure("metalGroupTextureAllocation")
            }
            created.label = "pag.local.opacity"
            texture = created
        }
        // GPU可能按页/块分配，不能让大量微小附件绕过聚合字节限制。
        let occupied = max(width * height * 4, texture.allocatedSize)
        guard occupied <= activeLimit - 512, activeBytes <= activeLimit - 512 - occupied else {
            throw PAGError.resourceLimitExceeded("maximumActiveMetalGroupBytes")
        }
        let cost = occupied + 512
        if cost > estimate { try budget.reserve(cost - estimate) }
        try Task.checkCancellation()
        let loan = MetalGroupAttachment(texture: texture, size: size, byteCount: cost)
        active[loan.id] = loan
        activeBytes += cost
        return loan
    }

    /// 只有仍活动的同一借用才可编码；已经归还的旧帧不允许引用后来的内容。
    func contains(_ loan: MetalGroupAttachment) -> Bool { active[loan.id] === loan }

    /// GPU完成或提交前放弃后调用；重复/旧借用返回false，不改变新借用或预算。
    @discardableResult func release(_ loan: MetalGroupAttachment) -> Bool {
        guard contains(loan) else { return false }
        active.removeValue(forKey: loan.id)
        activeBytes -= loan.byteCount
        guard loan.byteCount <= freeLimit else { return true }
        while freeBytes > freeLimit - loan.byteCount, let oldest { _ = removeFree(oldest) }
        free[loan.id] = MetalFreeGroup(loan: loan, previous: nil, next: newest)
        sizes[loan.size, default: []].insert(loan.id)
        if let newest { free[newest]?.previous = loan.id }
        else { oldest = loan.id }
        newest = loan.id
        freeBytes += loan.byteCount
        return true
    }

    /// 从尺寸索引和LRU同时移除，不涉及仍在GPU使用的活动纹理。
    private func removeFree(_ id: UUID) -> MetalGroupAttachment? {
        guard let node = free.removeValue(forKey: id) else { return nil }
        if let previous = node.previous { free[previous]?.next = node.next }
        else { newest = node.next }
        if let next = node.next { free[next]?.previous = node.previous }
        else { oldest = node.previous }
        sizes[node.loan.size]?.remove(id)
        if sizes[node.loan.size]?.isEmpty == true { sizes.removeValue(forKey: node.loan.size) }
        freeBytes -= node.loan.byteCount
        return node.loan
    }
}

/// 局部附件的精确像素尺寸，格式/采样数由池固定。
struct MetalGroupSize: Hashable {
    /// 正像素宽度，不超过16384。
    let width: Int
    /// 正像素高度，不超过16384。
    let height: Int
}

/// 一次可变组内容借用，不可跨RenderOwner域传递。
final class MetalGroupAttachment {
    /// 借用身份，与MTLTexture对象地址分离，阻止迟到归还释放新工作。
    let id = UUID()
    /// 只由当前借用写入的private颜色附件。
    let texture: any MTLTexture
    /// 复用索引所需的精确尺寸。
    let size: MetalGroupSize
    /// 像素/实际GPU分配的较大值，加上必要元数据的计费。
    let byteCount: Int

    /// 为已经创建或取出的纹理生成全新借用身份。
    init(texture: any MTLTexture, size: MetalGroupSize, byteCount: Int) {
        self.texture = texture
        self.size = size
        self.byteCount = byteCount
    }
}

/// 空闲附件LRU节点，通过UUID链接避免引用环。
private struct MetalFreeGroup {
    /// 已经结束的旧借用；再次取出只复用纹理，不复用身份。
    let loan: MetalGroupAttachment
    /// 更近归还节点，头部为nil。
    var previous: UUID?
    /// 更早归还节点，尾部为nil。
    var next: UUID?
}
