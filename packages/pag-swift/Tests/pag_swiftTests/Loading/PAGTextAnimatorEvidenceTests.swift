import Foundation
import Testing
@testable import pag_swift

/// 八份真实tag70文本动画器的子标签、字段轨道及源值；其它语义门禁独立判断。
struct PAGTextAnimatorEvidenceTests {
    /// 按上游TextAnimatorTag的子标签边界逐一走完，保留完整来源用于实现前分类。
    @Test func realAnimatorChildTagInventory() throws {
        let names = ["RangeSelectorTriangleEaseHighAndLow.pag", "TextAnimatorMode.pag",
            "TextAnimatorSmooth.pag", "TextAnimatorX7.pag", "TextAnimators.pag",
            "TextPositionAnimator.pag", "TrackingAnimator.pag", "TrackingAnimatorVertical.pag"]
        for name in names {
            var inspection = ShapeAnimationInspection()
            try inspection.inspect(PAGFixtures.data(named: name))
            #expect(!inspection.textAnimatorReaders.isEmpty, "file=\(name)")
            var records: [[String: Any]] = []
            for input in inspection.textAnimatorReaders {
                var decodedReader = input
                var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 64 * 1024 * 1024))
                let animator = try decoder.readTextAnimator(reader: &decodedReader)
                #expect(decodedReader.remainingByteCount == 0, "file=\(name)")
                var reader = input
                var children: [[String: Int]] = []
                while true {
                    let header = try PAGTagHeader.read(from: &reader)
                    if header.code == 0 { break }
                    let payload = try reader.readSubreader(byteCount: header.payloadRange.count)
                    children.append(["tag": Int(header.code), "bytes": payload.remainingByteCount])
                }
                try StaticAttributes.requireEnd(of: reader)
                let selectors: [[String: Any]] = animator.selectors.map {
                    switch $0 {
                    case .range(let value):
                        ["type": "range", "shape": value.shape, "random": value.randomizeOrder,
                         "mode": value.mode.initialValue, "start": value.start.initialValue,
                         "end": value.end.initialValue, "startFrames": value.start.keyframes.count,
                         "endFrames": value.end.keyframes.count,
                         "seedFrames": value.randomSeed.keyframes.count]
                    case .wiggly(let value):
                        ["type": "wiggly", "mode": value.mode.initialValue,
                         "min": value.minAmount.initialValue, "max": value.maxAmount.initialValue]
                    }
                }
                records.append(["children": children, "selectors": selectors,
                    "tracking": animator.trackingAmount?.keyframes.count ?? -1,
                    "position": animator.position?.keyframes.count ?? -1,
                    "scale": animator.scale?.keyframes.count ?? -1,
                    "rotation": animator.rotation?.keyframes.count ?? -1,
                    "opacity": animator.opacity?.keyframes.count ?? -1])
            }
            if ProcessInfo.processInfo.environment["PAG_TEXT_ANIMATOR_AUDIT"] == "1" {
                let data = try JSONSerialization.data(withJSONObject: records, options: .sortedKeys)
                print("PAG_TEXT_ANIMATOR \(name) \(String(decoding: data, as: UTF8.self))")
            }
        }
    }
}
