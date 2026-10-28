/// 直接drawable片元与独立数值验证共用的MSL覆盖数学；不创建输出附件。
enum MetalCoverageMath {
    /// 对像素方形、单个三角形和完整凸裁剪求实际交集面积，不创建纹理或逐三角形混合。
    static let source = """
    /// 二维有向面积的基本运算，调用方坐标以当前像素左上角为原点。
    inline float pagCross(float2 a, float2 b) { return a.x * b.y - a.y * b.x; }

    /// 一条有向边在单位像素内的Green积分；水平边不贡献面积。
    inline float pagEdgeArea(float2 a, float2 b) {
        float dy = b.y - a.y;
        if (dy == 0) { return 0; }
        float lower = max(0.0f, min(a.y, b.y));
        float upper = min(1.0f, max(a.y, b.y));
        if (upper <= lower) { return 0; }
        float x0 = mix(a.x, b.x, (lower - a.y) / dy);
        float x1 = mix(a.x, b.x, (upper - a.y) / dy);
        float lo = min(x0, x1), hi = max(x0, x1), mean;
        if (hi <= 0) { return 0; }
        if (lo >= 1) { mean = 1; }
        else if (lo >= 0 && hi <= 1) { mean = (lo + hi) * 0.5f; }
        else {
            // clamp(x,0,1)的分段线性积分；同区间分支避免相近大数相减。
            float start = max(lo, 0.0f), end = min(hi, 1.0f);
            mean = (0.5f * (end - start) * (end + start) + max(hi - 1, 0.0f)) / (hi - lo);
        }
        return (dy > 0 ? 1.0f : -1.0f) * (upper - lower) * mean;
    }

    /// 没有相交裁剪边界时，三条边的积分即可得到像素覆盖，绕序不影响结果。
    inline float pagTriangleArea(float2 a, float2 b, float2 c) {
        return clamp(abs(pagEdgeArea(a, b) + pagEdgeArea(b, c) + pagEdgeArea(c, a)), 0.0f, 1.0f);
    }

    /// 返回单位像素的正绕序边界顶点。
    inline float2 pagPixelCorner(uint index) {
        switch (index & 3u) {
            case 0: return float2(0, 0);
            case 1: return float2(1, 0);
            case 2: return float2(1, 1);
            default: return float2(0, 1);
        }
    }

    /// 只保留线段位于有向半平面内的部分；同向重合边按来源优先级只计一次。
    inline bool pagClipSegment(thread float2 &a, thread float2 &b, float2 p, float2 q,
                               uint owner, uint boundaryOwner) {
        float2 edge = q - p;
        if (all(edge == 0)) { return true; }
        float da = pagCross(edge, a - p), db = pagCross(edge, b - p);
        if (da == 0 && db == 0) {
            // 反向重合意味着交集只剩线，没有面积；同向边优先保留较小owner。
            return dot(b - a, edge) > 0 && owner <= boundaryOwner;
        }
        if (da < 0 && db < 0) { return false; }
        if (da < 0 || db < 0) {
            float scale = max(abs(da), abs(db));
            float t = (da / scale) / ((da / scale) - (db / scale));
            float2 point = mix(a, b, t);
            if (da < 0) { a = point; } else { b = point; }
        }
        return any(a != b);
    }

    /// 一个凸交集的边界来自三个输入多边形各自仍处于其他区域内的边段。
    inline float pagIntersectionArea(float2 a, float2 b, float2 c, float2 origin,
                                     const device float4 *clips, uint count) {
        float2 triangle[3] = {a, b, c};
        float area = 0;
        // owner依次表示三角形、凸裁剪、像素，重合边按此固定优先级去重。
        for (uint owner = 0; owner < 3; ++owner) {
            uint length = owner == 0 ? 3 : (owner == 1 ? count : 4);
            for (uint i = 0; i < length; ++i) {
                float2 start, end;
                if (owner == 0) { start = triangle[i]; end = triangle[(i + 1) % 3]; }
                else if (owner == 1) { start = clips[i].xy - origin; end = clips[i].zw - origin; }
                else { start = pagPixelCorner(i); end = pagPixelCorner(i + 1); }
                bool valid = true;
                // 先裁到单位像素，后续线段积分不会在巨大世界坐标上做相消。
                if (owner != 2) {
                    for (uint j = 0; j < 4 && valid; ++j) {
                        valid = pagClipSegment(start, end, pagPixelCorner(j), pagPixelCorner(j + 1), owner, 2);
                    }
                }
                if (owner != 0) {
                    for (uint j = 0; j < 3 && valid; ++j) {
                        valid = pagClipSegment(start, end, triangle[j], triangle[(j + 1) % 3], owner, 0);
                    }
                }
                if (owner != 1) {
                    for (uint j = 0; j < count && valid; ++j) {
                        valid = pagClipSegment(start, end, clips[j].xy - origin, clips[j].zw - origin, owner, 1);
                    }
                }
                if (valid) { area += 0.5f * (start.x + end.x) * (end.y - start.y); }
            }
        }
        return clamp(area, 0.0f, 1.0f);
    }

    /// 计算一次完整联合覆盖；裁剪完全包含像素时走三角形积分快路，完全排除时直接返回零。
    inline float pagClippedTriangleArea(float2 a, float2 b, float2 c, float2 origin,
                                        const device float4 *clips, uint count) {
        a -= origin; b -= origin; c -= origin;
        float orientation = pagCross(b - a, c - a);
        if (orientation == 0) { return 0; }
        if (orientation < 0) { float2 swap = b; b = c; c = swap; }
        bool inside = true, hasEdge = false;
        for (uint i = 0; i < count; ++i) {
            float2 start = clips[i].xy - origin, edge = clips[i].zw - clips[i].xy;
            // Float打包可能把极短边的两个端点合并；它不应将整个交集判成空。
            if (all(edge == 0)) { continue; }
            hasEdge = true;
            float center = pagCross(edge, float2(0.5f) - start);
            float support = 0.5f * (abs(edge.x) + abs(edge.y));
            if (center + support <= 0) { return 0; }
            inside = inside && center >= support;
        }
        // 整个裁剪在Float精度下退化时是零覆盖，不能把它解释成没有裁剪。
        if (count > 0 && !hasEdge) { return 0; }
        if (inside) { return pagTriangleArea(a, b, c); }
        return pagIntersectionArea(a, b, c, origin, clips, count);
    }

    /// 与MetalVertex相同的16字节输入布局，覆盖查询只使用position。
    struct PAGCoverageVertex {
        /// 减去源网格原点的局部坐标。
        float2 position;
        /// 保持与现有MetalVertex相同布局，覆盖数学不使用此字段。
        float2 uv;
    };
    /// 与RenderCoverageNode相同的32字节节点；range.z为子树出口。
    struct PAGCoverageNode {
        /// 局部最小x/y和最大x/y，按实际Float顶点建立。
        float4 bounds;
        /// 叶子首索引、数量、子树结束下标、零填充。
        uint4 range;
    };

    /// 对局部BVH做无栈查询，同一填充的全部候选面积合并后只返回一次覆盖。
    /// horizontal/vertical为世界变换两行(x系数,y系数,平移,0)，inverse按两行存逆线性矩阵。
    inline float pagMeshArea(float2 origin, float4 horizontal, float4 vertical, float4 inverse,
                             const device PAGCoverageVertex *vertices, const device PAGCoverageNode *nodes,
                             const device uint *triangles, uint nodeCount, const device float4 *clips, uint clipCount) {
        float2 translation = float2(horizontal.z, vertical.z);
        float2 relative = origin + 0.5f - translation;
        float2 center = float2(dot(inverse.xy, relative), dot(inverse.zw, relative));
        float2 radius = 0.5f * float2(abs(inverse.x) + abs(inverse.y), abs(inverse.z) + abs(inverse.w));
        // 逆映射舍入只能增加候选，不能丢掉刚好贴着像素边界的三角形。
        radius += float2(0.000001f) + (abs(center) + radius) * 0.000001f;
        float4 query = float4(center - radius, center + radius);
        uint position = 0;
        float area = 0;
        while (position < nodeCount) {
            PAGCoverageNode node = nodes[position];
            if (node.bounds.x > query.z || node.bounds.z < query.x || node.bounds.y > query.w || node.bounds.w < query.y) {
                position = node.range.z;
                continue;
            }
            if (node.range.y == 0) { ++position; continue; }
            for (uint i = 0; i < node.range.y; ++i) {
                uint first = triangles[node.range.x + i] * 3;
                float2 p[3];
                for (uint j = 0; j < 3; ++j) {
                    float2 local = vertices[first + j].position;
                    p[j] = float2(dot(horizontal.xy, local) + horizontal.z, dot(vertical.xy, local) + vertical.z);
                }
                area += pagClippedTriangleArea(p[0], p[1], p[2], origin, clips, clipCount);
            }
            position = node.range.z;
        }
        return clamp(area, 0.0f, 1.0f);
    }
    """
}
