import Foundation
import Testing
@testable import pag_swift

/// 独立Python低位流探针提取的固定整数金值；探针没有调用Swift路径/属性读取内核。
struct PAGMaskRawValueTests {
    /// AudioMarker真实闭合四曲线的13个点与原始整数一致，不能只验证路径计数或包围盒。
    @Test func audioMarkerPathMatchesRawCoordinates() throws {
        let source = try MaskFixtures.read(PAGFixtures.data(named: "AudioMarker.pag").subdata(in: 1_971_337..<1_971_395)).mask
        let path = source.path.initialValue
        // 原始records为1,7,7,7,7,0，坐标共用位宽16；金值在0.05缩放之前。
        let integers: [(Int32, Int32)] = [(8005, 5112), (3687, 5112), (187, 8612), (187, 12930),
            (187, 17248), (3687, 20748), (8005, 20748), (12323, 20748), (15823, 17248),
            (15823, 12930), (15823, 8612), (12323, 5112), (8005, 5112)]
        #expect(path.verbs == [.move, .cubic, .cubic, .cubic, .cubic, .close])
        #expect(path.points == points(integers))
        #expect(source.path.isAnimated == false)
    }

    /// travel的压缩H/V记录、两个动画端点及独立Bezier数值同时验证，防止同内核对照自证。
    @Test func travelAnimationMatchesRawEndpointsAndEase() throws {
        let source = try MaskFixtures.read(PAGFixtures.data(named: "travel.pag").subdata(in: 2_172..<2_210)).mask
        let key = try #require(source.path.keyframes.first)
        #expect(source.path.keyframes.count == 1 && key.startFrame == 40 && key.endFrame == 55)
        #expect(key.startValue.verbs == [.move, .line, .line, .line, .line, .close])
        #expect(key.endValue.verbs == key.startValue.verbs)
        #expect(key.startValue.points == points([(5, 5), (5, 905), (-93, 905), (-93, 5), (5, 5)]))
        #expect(key.endValue.points == points([(5, 5), (5, 905), (3841, 905), (3841, 5), (5, 5)]))
        guard case .bezier(let curve, let second) = key.easing else {
            Issue.record("真实travel蒙版必须保留Bezier")
            return
        }
        #expect(second == nil)
        // 独立探针得到ease位宽9、原始控制点136/0/200/200；用三次多项式独立求逆的金值。
        for (time, value): (Float, Float) in [(0.25, 0.04745553), (0.5, 0.20200883), (0.75, 0.49246352)] {
            #expect(abs(curve.timing(at: time) - value) < 0.005)
        }
    }

    /// 没有扩展名的真实15不能漏扫；两个路径均保留0→30的线性段而不是Bezier或Hold。
    @Test func extensionlessFileKeepsBothAnimatedMasks() throws {
        let data = try PAGFixtures.data(named: "15")
        for (range, count): (Range<Int>, Int) in [(153_193..<153_299, 6), (153_998..<154_127, 8)] {
            let mask = try MaskFixtures.read(data.subdata(in: range)).mask
            let key = try #require(mask.path.keyframes.first)
            #expect(mask.path.keyframes.count == 1 && key.startFrame == 0 && key.endFrame == 30)
            #expect(key.startValue.verbs.count == count && key.endValue.verbs.count == count)
            #expect(key.startValue.verbs.filter { $0 == .cubic }.count == 4)
            guard case .linear = key.easing else {
                Issue.record("无扩展名15的两条蒙版均编码kind1")
                continue
            }
        }
    }

    /// 仅应用DataTypes.cpp的Float坐标精度到固定整数金值，不读取任何压缩字节。
    private func points(_ values: [(Int32, Int32)]) -> [ScenePoint] {
        values.map { ScenePoint(x: Double(Float($0.0) * 0.05), y: Double(Float($0.1) * 0.05)) }
    }
}
