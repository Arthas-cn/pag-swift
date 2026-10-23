import CoreGraphics
import Foundation
import Testing
@testable import pag_swift

/// 槽位 alpha 遮罩的来源、布局、独立编辑和路径边界，不以计划存在替代 GPU 像素验证。
struct ImageMaskTests {
    /// 真实资源 10 的心形原图用于 avatar；来源槽即使被替换和隐藏，仍不会污染遮罩读取。
    @Test func originalHeartMaskDoesNotChangeItsSourceSlot() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "10"))
        #expect(Set(file.contentSlots.map(\.tag)) == ["xin7.png", "avatar"])
        let heart = try #require(file.contentSlots.first { $0.tag == "xin7.png" })
        let avatar = try #require(file.contentSlots.first { $0.tag == "avatar" })
        let source = try #require(file.storage.resources.images[file.storage.catalog.imageIDs[heart.sourceIndex]])
        let image = try await PAGImage.load(data: PAGFixtures.data(named: "media/bear.gif"))
        var composition = file.composition
        try await composition.apply(.image(image), forTag: heart.tag)
        try await composition.apply(.hidden, forTag: heart.tag)
        let beforeImages = composition.edits.images
        let beforeVisibility = composition.edits.visibility
        try await composition.apply(.image(image, options: .init(scaleMode: .aspectFill,
            mask: .originalImage(tag: heart.tag))), forTag: avatar.tag)
        let record = try #require(composition.dynamicSlotRecords().first { $0.slot.tag == avatar.tag })
        for index in record.instances {
            let id = composition.storage.instances[index].id
            let mask = try #require(composition.edits.imageMasks[id])
            #expect(mask.image.storage.identity == source.image.storage.identity)
            #expect(composition.edits.imageScaleModes[id] == .aspectFill)
        }
        for (id, input) in beforeImages {
            #expect(composition.edits.images[id]?.storage.identity == input.storage.identity)
        }
        #expect(composition.edits.visibility == beforeVisibility)
        #expect(file.composition.edits.imageMasks.isEmpty)

        let scene = try await PreparedScene.prepare(composition)
        let first = try await plan(scene, imageTime: 0)
        let later = try await plan(scene, imageTime: 200_000)
        let masks = first.plan.commands.compactMap { command -> FrameImageMask? in
            if case .image(let image) = command { return image.slotMask }
            return nil
        }
        #expect(!masks.isEmpty)
        #expect(masks.allSatisfy { $0.resourceID == source.image.storage.identity })
        #expect(later.images[source.image.storage.identity] != nil)
    }

    /// 显式静态模式可与遮罩组合；恢复或下一次普通替换清除遮罩和缩放覆盖。
    @Test func stillMaskAndRestorationArePerSlot() async throws {
        let file = try await EditableFixtures.file()
        let image = try await PAGImage.load(data: PAGFixtures.data(named: "media/bear.gif"))
        var composition = file.composition
        try await composition.apply(.image(image, options: .init(playbackMode: .still,
            scaleMode: .aspectFill, mask: .circle)), forTag: "image:1")
        #expect(composition.edits.imageMasks.count == 4)
        #expect(composition.edits.images.values.allSatisfy { $0.kind == .still })
        let shared = try #require(composition.edits.imageMasks.values.first?.image.storage.identity)
        #expect(composition.edits.imageMasks.values.allSatisfy { $0.image.storage.identity == shared })
        try await composition.apply(.original, forTag: "image:1")
        #expect(composition.edits.imageMasks.isEmpty && composition.edits.imageScaleModes.isEmpty)
        try await composition.apply(.image(image, options: .init(mask: .ellipse)), forTag: "image:1")
        try await composition.apply(.image(image), forTag: "image:1")
        #expect(composition.edits.imageMasks.isEmpty && composition.edits.imageScaleModes.isEmpty)
        #expect(composition.edits.images.values.allSatisfy { $0.kind == .animated })
    }

    /// 圆形内切而椭圆填框；不同宽高比的槽不把圆形拉伸，超大路径有固定像素预算。
    @Test func builtInShapesPreserveTheirGeometryAndBudget() async throws {
        let composition = try await EditableFixtures.file().composition
        let size = try PAGSize(width: 200, height: 100)
        let circle = try await PreparedImageMask.prepare(.circle, for: size, in: composition)
        let ellipse = try await PreparedImageMask.prepare(.ellipse, for: size, in: composition)
        #expect(alpha(circle.image, x: 100, y: 50) == 255)
        #expect(alpha(circle.image, x: 10, y: 50) == 0)
        #expect(alpha(ellipse.image, x: 10, y: 50) == 255)
        let rounded = try await PreparedImageMask.prepare(.roundedRectangle(cornerRadius: 0.25), for: size, in: composition)
        #expect(alpha(rounded.image, x: 0, y: 0) == 0)
        #expect(alpha(rounded.image, x: 100, y: 50) == 255)
        let huge = try await PreparedImageMask.prepare(.circle, for: PAGSize(width: 8000, height: 4000), in: composition)
        #expect(huge.image.size == (try PAGSize(width: 2048, height: 1024)))
        #expect(huge.image.storage.pixels.count <= 16 * 1024 * 1024)
    }

    /// 自定义路径复制后不受原 CGMutablePath 修改影响；顶行方向和奇偶孔洞保持明确。
    @Test func customPathIsImmutableAndPreservesTopLeftCoordinates() async throws {
        let composition = try await EditableFixtures.file().composition
        let size = try PAGSize(width: 100, height: 100)
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: 100, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 100))
        path.closeSubpath()
        let snapshot = try PAGMaskPath(path, coordinateSize: size)
        path.addRect(CGRect(x: 0, y: 0, width: 100, height: 100))
        let mask = try await PreparedImageMask.prepare(.path(snapshot), for: size, in: composition)
        #expect(alpha(mask.image, x: 10, y: 10) == 255)
        #expect(alpha(mask.image, x: 90, y: 90) == 0)
        let donut = CGMutablePath()
        donut.addRect(CGRect(x: 0, y: 0, width: 100, height: 100))
        donut.addEllipse(in: CGRect(x: 25, y: 25, width: 50, height: 50))
        let hole = try await PreparedImageMask.prepare(.path(PAGMaskPath(donut, coordinateSize: size,
            usesEvenOddFillRule: true)), for: size, in: composition)
        #expect(alpha(hole.image, x: 50, y: 50) == 0)
        #expect(alpha(hole.image, x: 10, y: 10) == 255)
    }

    /// 非法源 tag、动图遮罩和圆角半径必须失败；已应用的头像及其它编辑保持不变。
    @Test func invalidMaskDoesNotPublishPartialEdits() async throws {
        let file = try await EditableFixtures.file()
        let animated = try await PAGImage.load(data: PAGFixtures.data(named: "media/bear.gif"))
        var composition = file.composition
        try await composition.apply(.image(animated), forTag: "image:1")
        for mask in [PAGImageMask.originalImage(tag: "missing"), .alphaImage(animated),
                     .roundedRectangle(cornerRadius: -1), .roundedRectangle(cornerRadius: .nan)] {
            await #expect(throws: PAGError.self) {
                try await composition.apply(.image(animated, options: .init(mask: mask)), forTag: "image:1")
            }
            #expect(composition.edits.imageMasks.isEmpty)
            #expect(composition.edits.images.values.allSatisfy { $0.storage.identity == animated.storage.identity })
        }
        #expect(throws: PAGError.invalidArgument("maskPath")) {
            try PAGMaskPath(CGMutablePath(), coordinateSize: PAGSize(width: 1, height: 1))
        }
        let tooMany = CGMutablePath()
        tooMany.move(to: .zero)
        // Core Graphics 会合并连续 move；使用真实线段才能验证元素预算。
        for index in 0..<4097 { tooMany.addLine(to: CGPoint(x: index, y: index % 2)) }
        #expect(throws: PAGError.resourceLimitExceeded("maskPathElements")) {
            try PAGMaskPath(tooMany, coordinateSize: PAGSize(width: 100, height: 100))
        }
    }

    /// 在透明 RGBA 输入中读取 alpha，仅供一次性准备的形状覆盖参考。
    private func alpha(_ image: PAGImage, x: Int, y: Int) -> UInt8 {
        image.storage.pixels[y * image.storage.bytesPerRow + x * 4 + 3]
    }

    /// 固定根位置，仅推进头像自己的素材时钟；真实资源 10 的心形保持静态身份。
    private func plan(_ scene: PreparedScene, imageTime: Int64) async throws -> PreparedFrame {
        try await FramePlanner.prepare(scene, at: PAGTime(microseconds: 1_000_000),
            targetSize: scene.composition.size, scale: 1, mode: .aspectFit,
            imageAnimationTime: PAGTime(microseconds: imageTime))
    }
}
