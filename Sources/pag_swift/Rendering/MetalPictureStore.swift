import Foundation
import Metal

/// Shape/Text层内容或Vector定义纹理的完整身份；实例位置不参与键，实际分辨率参与。
struct MetalPictureKey: Hashable {
    /// 原始文件内容身份，避免源层下标碰撞。
    let document: DocumentIdentity
    /// Shape/Text源层；Vector定义不用虚构某个子层身份，此时为nil。
    let source: SourceLayerReference?
    /// Vector的源合成定义索引；Shape/Text时为nil，与source互斥。
    let vectorIndex: Int?
    /// 逐实例visibility编辑存在时的Vector展开路径；无编辑时为nil。
    let vectorInstance: PAGLayerID?
    /// nil为Shape；Text使用准备资源代数，编辑后同源不能复用旧字形。
    let textResource: TextResourceID?
    /// 播放器编辑代数，修改内容后旧纹理不能进入新请求。
    let revision: UInt64
    /// 实际建图尺度的精确位型，不能用标称档复用较低分辨率纹理。
    let scaleBits: UInt64
    /// 内容局部坐标在纹理像素空间中的左边缘。
    let originX: Int
    /// 内容局部坐标在纹理像素空间中的上边缘。
    let originY: Int
    /// 已含抗锯齿和线性取样透明边缘的像素宽度。
    let width: Int
    /// 已含抗锯齿和线性取样透明边缘的像素高度。
    let height: Int

    /// 固定一种内容源身份及实际纹理网格；Vector不允许借用子Shape/Text键。
    init(document: DocumentIdentity, source: SourceLayerReference?, textResource: TextResourceID?,
         vectorIndex: Int? = nil, vectorInstance: PAGLayerID? = nil,
         revision: UInt64, scaleBits: UInt64,
         originX: Int, originY: Int, width: Int, height: Int) {
        self.document = document
        self.source = source
        self.vectorIndex = vectorIndex
        self.vectorInstance = vectorInstance
        self.textResource = textResource
        self.revision = revision
        self.scaleBits = scaleBits
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
    }
}

/// 私有Metal内容纹理及分配成本；只由RenderOwner隔离域使用。
struct MetalPictureTexture {
    /// 与源内容及实际像素尺寸一致的缓存键。
    let key: MetalPictureKey
    /// 已生成或正在同一命令缓冲内生成的private BGRA纹理。
    let texture: any MTLTexture
    /// 实际GPU占用与元数据的保守费用。
    let byteCount: Int
}

/// 新快照直到GPU完成前的活动借用；不能在编码成功时提前进入LRU。
struct MetalPictureLease {
    /// 单次分配身份，防止迟到完成发布另一代的同键纹理。
    let id: UUID
    /// 本次活动纹理，批次保活直至GPU完成或提交前放弃。
    let picture: MetalPictureTexture
}

/// RenderOwner独占的Shape/Text内容LRU，活动和已完成纹理分别计费。
final class MetalPictureStore {
    /// 与根drawable相同的设备，不创建第二套渲染后端。
    private let device: any MTLDevice
    /// GPU仍在使用的未完成快照上限。
    private let activeLimit: Int
    /// GPU已完成快照的LRU保留上限。
    private let retainedLimit: Int
    /// 已完成纹理及其最近使用序号。
    private var entries: [MetalPictureKey: (picture: MetalPictureTexture, used: UInt64)] = [:]
    /// 尚未GPU完成的唯一分配；同帧复用在准备器pending表中完成。
    private var active: [UUID: MetalPictureTexture] = [:]
    /// 所有活动分配的保守占用。
    private(set) var activeBytes = 0
    /// 所有LRU条目的保守占用。
    private(set) var retainedBytes = 0
    /// 单调最近使用计数；溢出时重新编号即可，不影响相对次序。
    private var clock: UInt64 = 0
    /// GPU已完成并可供下一帧命中的纹理数，仅供内部验收读取。
    var count: Int { entries.count }

    /// 建立独立于输入缓存和组附件的额度；零保留额度允许只生成当前帧。
    init(device: any MTLDevice, activeLimit: Int = 64 * 1024 * 1024,
         retainedLimit: Int = 64 * 1024 * 1024) throws {
        guard activeLimit > 0, retainedLimit >= 0 else {
            throw PAGError.invalidArgument("metalPicturePoolBytes")
        }
        self.device = device
        self.activeLimit = activeLimit
        self.retainedLimit = retainedLimit
    }

    /// 查找GPU已完成的纹理，并按真实占用向本帧预算收费；预算失败由Picture调用方回退。
    func lookup(_ key: MetalPictureKey, budget: inout MetalFrameBudget) throws -> MetalPictureTexture? {
        guard let entry = entries[key], entry.picture.texture.width >= key.width,
              entry.picture.texture.height >= key.height else { return nil }
        try budget.use(.picture(key), bytes: entry.picture.byteCount)
        clock = nextClock()
        entries[key]?.used = clock
        return entry.picture
    }

    /// 分配仅供内容局部pass使用的纹理；失败前不发布活动借用，实际分配继续追补预算。
    func allocate(_ key: MetalPictureKey, budget: inout MetalFrameBudget) throws -> MetalPictureLease {
        guard key.width > 0, key.height > 0, key.width <= 16_384, key.height <= 16_384,
              UInt128(key.width) * UInt128(key.height) <= 16_777_216 else {
            throw PAGError.resourceLimitExceeded("metalPictureDimensions")
        }
        let estimate = key.width * key.height * 4 + 512
        guard estimate <= activeLimit, activeBytes <= activeLimit - estimate else {
            throw PAGError.resourceLimitExceeded("maximumActiveMetalPictureBytes")
        }
        try budget.use(.picture(key), bytes: estimate)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                   width: key.width, height: key.height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw PAGError.renderingFailure("metalPictureTextureAllocation")
        }
        texture.label = "pag.local.picture"
        let occupied = max(key.width * key.height * 4, texture.allocatedSize)
        guard occupied <= activeLimit - 512, activeBytes <= activeLimit - 512 - occupied else {
            throw PAGError.resourceLimitExceeded("maximumActiveMetalPictureBytes")
        }
        let cost = occupied + 512
        if cost > estimate { try budget.reserve(cost - estimate) }
        try Task.checkCancellation()
        let picture = MetalPictureTexture(key: key, texture: texture, byteCount: cost)
        let lease = MetalPictureLease(id: UUID(), picture: picture)
        active[lease.id] = picture
        activeBytes += cost
        return lease
    }

    /// GPU完成且请求仍当前时发布；超出保留上限只释放活动纹理，不破坏已在用的绘制。
    func publish(_ lease: MetalPictureLease) {
        guard let picture = active.removeValue(forKey: lease.id), picture.key == lease.picture.key else { return }
        activeBytes -= picture.byteCount
        guard picture.byteCount <= retainedLimit else { return }
        if let previous = entries.removeValue(forKey: picture.key) { retainedBytes -= previous.picture.byteCount }
        while retainedBytes > retainedLimit - picture.byteCount,
              let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
            retainedBytes -= entries.removeValue(forKey: oldest)!.picture.byteCount
        }
        clock = nextClock()
        entries[picture.key] = (picture, clock)
        retainedBytes += picture.byteCount
    }

    /// 提交前取消、GPU失败或迟到请求仅释放该借用；重复释放不触碰新借用。
    func discard(_ lease: MetalPictureLease) {
        guard let picture = active.removeValue(forKey: lease.id) else { return }
        activeBytes -= picture.byteCount
    }

    /// 目标或编辑代数改变时清除已完成条目；在途纹理仍由原批次保活。
    func clear() {
        entries.removeAll()
        retainedBytes = 0
    }

    /// 计数溢出前压缩仍保留条目的使用顺序，避免LRU时间戳回绕。
    private func nextClock() -> UInt64 {
        if clock == .max {
            let ordered = entries.sorted { $0.value.used < $1.value.used }
            for (index, item) in ordered.enumerated() { entries[item.key]?.used = UInt64(index + 1) }
            return UInt64(ordered.count + 1)
        }
        return clock + 1
    }
}
