#include "shape_model.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>

// Performance notes (Cortex-A9 @ 650 MHz, PYNQ-Z2): streaming DDR reads top
// out at ~450 MB/s, and every scalar float compare / float->int move stalls the
// VFP pipeline. Hence the int16 basis, the bit-pattern sign tests and the
// integer-coordinate trilinear sampling below.

namespace app {

namespace {
uint64_t now_us_() {
    return std::chrono::duration_cast<std::chrono::microseconds>(
               std::chrono::steady_clock::now().time_since_epoch()).count();
}
inline int32_t bits(float v) {
    int32_t b;
    std::memcpy(&b, &v, 4);
    return b;
}
// v <= 0 (including -0) without a float compare.
inline uint8_t is_inside(float v) {
    const int32_t b = bits(v);
    return uint8_t(b <= 0 || b == int32_t(0x80000000u));
}
}  // namespace

bool ShapeModel::load(const std::string &path, std::string *error) {
    std::ifstream f(path, std::ios::binary);
    auto fail = [&](const char *why) {
        if (error) *error = path + ": " + why;
        return false;
    };
    if (!f) return fail("cannot open");
    char magic[4];
    uint32_t rk[2];
    if (!f.read(magic, 4) || std::memcmp(magic, "ESDF", 4) || !f.read(reinterpret_cast<char *>(rk), 8))
        return fail("bad header");
    res_ = int(rk[0]);
    k_ = int(rk[1]);
    if (res_ < 8 || res_ > 128 || k_ < 1 || k_ > 16) return fail("implausible sizes");
    float nstats[32];
    if (!f.read(reinterpret_cast<char *>(origin_), 12) || !f.read(reinterpret_cast<char *>(spacing_), 12) ||
        !f.read(reinterpret_cast<char *>(&out_scale_), 4) ||
        !f.read(reinterpret_cast<char *>(nstats), std::streamsize(8) * k_))
        return fail("truncated header");
    const size_t n = size_t(res_) * res_ * res_;
    base_.resize(n);
    basis_.resize(n * k_);
    if (!f.read(reinterpret_cast<char *>(base_.data()), std::streamsize(n * 4)) ||
        !f.read(reinterpret_cast<char *>(basis_.data()), std::streamsize(n * k_ * 4)))
        return fail("truncated volumes");
    q_.resize(n * k_);
    for (int k = 0; k < k_; k++) {
        const float *b = basis_.data() + size_t(k) * n;
        float peak = 0;
        for (size_t i = 0; i < n; i++) peak = std::max(peak, std::fabs(b[i]));
        qscale_[k] = peak > 0 ? peak / 32767.f : 1.f;
        const float inv = 1.f / qscale_[k];
        int16_t *q = q_.data() + size_t(k) * n;
        for (size_t i = 0; i < n; i++) q[i] = int16_t(std::lrint(b[i] * inv));
    }
    return true;
}

void ShapeModel::coefficients(const int8_t codes[16], float out[16]) const {
    for (int i = 0; i < 16; i++) out[i] = i < k_ ? codes[i] * out_scale_ : 0.f;
}

uint32_t ShapeModel::reconstruct(const int8_t codes[16], std::vector<float> &sdf, std::vector<uint8_t> &inside) const {
    const size_t n = base_.size();
    sdf.resize(n);
    inside.resize(n);
    float qc[16];
    float err = 0;
    for (int k = 0; k < k_; k++) {
        qc[k] = float(codes[k]) * qscale_[k];
        err += std::fabs(float(codes[k])) * qscale_[k] * 0.5f;  // |basis - q*qscale| <= qscale/2
    }
    err += 1e-3f;  // float summation-order margin (mm)
    const int32_t err_bits = bits(err);
    constexpr size_t CHUNK = 2048;  // output chunk stays in cache while the bases stream by
    uint32_t count = 0, fixups = 0;
    for (size_t s = 0; s < n; s += CHUNK) {
        const size_t len = std::min(CHUNK, n - s);
        float *out = sdf.data() + s;
        std::memcpy(out, base_.data() + s, len * sizeof(float));
        for (int k = 0; k < k_; k++) {
            if (!codes[k]) continue;
            const float c = qc[k];
            const int16_t *q = q_.data() + size_t(k) * n + s;
            for (size_t i = 0; i < len; i++) out[i] += c * float(q[i]);  // NEON: vmovl + vcvt + vmla
        }
        uint8_t *in = inside.data() + s;
        for (size_t i = 0; i < len; i++) {
            if ((bits(out[i]) & 0x7FFFFFFF) <= err_bits) {  // |v| <= err: decide with the float basis
                float v = base_[s + i];
                for (int k = 0; k < k_; k++)
                    if (codes[k]) v += float(codes[k]) * basis_[size_t(k) * n + s + i];
                out[i] = v;
                fixups++;
            }
            in[i] = is_inside(out[i]);
            count += in[i];
        }
    }
    last_fixups = fixups;
    return count;
}

// Surface nets: one vertex per sign-changing cell (mean of its edge crossings),
// one quad per sign-changing grid edge joining the four cells around it.
void ShapeModel::extract(const std::vector<float> &sdf, const std::vector<uint8_t> &inside, Mesh &mesh) const {
    const uint64_t t0 = now_us_();
    const int R = res_, C = R - 1;
    mesh.verts.clear();
    mesh.faces.clear();
    mesh.colors.clear();
    // Vertex index of each cell for the current and previous x slab (32 KB).
    static std::vector<int32_t> slab[2];
    for (auto &s : slab) s.assign(size_t(C) * C, -1);
    static const float CORNER[8][3] = {{0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {1, 1, 0},
                                       {0, 0, 1}, {1, 0, 1}, {0, 1, 1}, {1, 1, 1}};
    static const int neutral[3] = {226, 206, 196}, cin[3] = {70, 132, 232}, cout[3] = {232, 78, 66};
    const size_t sx = size_t(R) * R, sy = R;
    size_t mixed = 0;
    for (int x = 0; x < C; x++) {
        int32_t *cur = slab[x & 1].data(), *prev = slab[(x & 1) ^ 1].data();
        std::fill_n(cur, size_t(C) * C, -1);
        for (int y = 0; y < C; y++) {
            const size_t o = x * sx + y * sy;
            const uint8_t *r00 = &inside[o], *r10 = r00 + sx, *r01 = r00 + sy, *r11 = r10 + sy;
            for (int z = 0; z < C; z++) {
                const unsigned mask = r00[z] | r10[z] << 1 | r01[z] << 2 | r11[z] << 3 | r00[z + 1] << 4 |
                                      r10[z + 1] << 5 | r01[z + 1] << 6 | r11[z + 1] << 7;
                if (mask == 0 || mask == 255) continue;
                mixed++;
                const size_t g = o + z;
                const size_t off[8] = {g, g + sx, g + sy, g + sx + sy, g + 1, g + sx + 1, g + sy + 1, g + sx + sy + 1};
                float v[8];
                for (int c = 0; c < 8; c++) v[c] = sdf[off[c]];
                float p[3] = {0, 0, 0};
                int crossings = 0;
                for (int c = 0; c < 8; c++)
                    for (int bit = 1; bit < 8; bit <<= 1) {
                        if (c & bit) continue;
                        const int d = c | bit;
                        if (((mask >> c) & 1) == ((mask >> d) & 1)) continue;
                        const float t = v[c] / (v[c] - v[d]);
                        for (int q = 0; q < 3; q++) p[q] += CORNER[c][q] + t * (CORNER[d][q] - CORNER[c][q]);
                        crossings++;
                    }
                const float inv = 1.f / float(crossings);
                const float fx = p[0] * inv, fy = p[1] * inv, fz = p[2] * inv;  // in [0, 1]
                cur[y * C + z] = int32_t(mesh.verts.size() / 3);
                mesh.verts.push_back(origin_[0] + (float(x) + fx) * spacing_[0]);
                mesh.verts.push_back(origin_[1] + (float(y) + fy) * spacing_[1]);
                mesh.verts.push_back(origin_[2] + (float(z) + fz) * spacing_[2]);
                // Mean-shape SDF at the vertex (trilinear in this cell); colour
                // ramp t in [-256, 256] <=> [-6, +6] mm.
                float bv[8];
                for (int c = 0; c < 8; c++) bv[c] = base_[off[c]];
                const float x0 = bv[0] + (bv[1] - bv[0]) * fx, x1 = bv[2] + (bv[3] - bv[2]) * fx;
                const float x2 = bv[4] + (bv[5] - bv[4]) * fx, x3 = bv[6] + (bv[7] - bv[6]) * fx;
                const float y0 = x0 + (x1 - x0) * fy, y1 = x2 + (x3 - x2) * fy;
                int t = int((y0 + (y1 - y0) * fz) * (256.f / 6.f));
                t = t < -256 ? -256 : t > 256 ? 256 : t;
                const int *tgt = t < 0 ? cin : cout;
                const int at = t < 0 ? -t : t;
                uint32_t rgb = 0;
                for (int q = 0; q < 3; q++) rgb = (rgb << 8) | uint32_t(neutral[q] + (tgt[q] - neutral[q]) * at / 256);
                mesh.colors.push_back(rgb);

                // Quads for the three edges leaving this cell's minimum corner.
                const bool in0 = mask & 1;
                const int32_t c0 = cur[y * C + z];
                // x edge: neighbours (y-1), (y-1,z-1), (z-1) in this slab.
                if (y && z && in0 != bool((mask >> 1) & 1)) {
                    const int32_t c1 = cur[(y - 1) * C + z], c2 = cur[(y - 1) * C + z - 1], c3 = cur[y * C + z - 1];
                    if (c1 >= 0 && c2 >= 0 && c3 >= 0) {
                        if (in0) mesh.faces.insert(mesh.faces.end(), {uint32_t(c0), uint32_t(c1), uint32_t(c2), uint32_t(c0), uint32_t(c2), uint32_t(c3)});
                        else mesh.faces.insert(mesh.faces.end(), {uint32_t(c0), uint32_t(c3), uint32_t(c2), uint32_t(c0), uint32_t(c2), uint32_t(c1)});
                    }
                }
                // y edge: neighbours (z-1), (z-1,x-1), (x-1).
                if (z && x && in0 != bool((mask >> 2) & 1)) {
                    const int32_t c1 = cur[y * C + z - 1], c2 = prev[y * C + z - 1], c3 = prev[y * C + z];
                    if (c1 >= 0 && c2 >= 0 && c3 >= 0) {
                        if (in0) mesh.faces.insert(mesh.faces.end(), {uint32_t(c0), uint32_t(c1), uint32_t(c2), uint32_t(c0), uint32_t(c2), uint32_t(c3)});
                        else mesh.faces.insert(mesh.faces.end(), {uint32_t(c0), uint32_t(c3), uint32_t(c2), uint32_t(c0), uint32_t(c2), uint32_t(c1)});
                    }
                }
                // z edge: neighbours (x-1), (x-1,y-1), (y-1).
                if (x && y && in0 != bool((mask >> 4) & 1)) {
                    const int32_t c1 = prev[y * C + z], c2 = prev[(y - 1) * C + z], c3 = cur[(y - 1) * C + z];
                    if (c1 >= 0 && c2 >= 0 && c3 >= 0) {
                        if (in0) mesh.faces.insert(mesh.faces.end(), {uint32_t(c0), uint32_t(c1), uint32_t(c2), uint32_t(c0), uint32_t(c2), uint32_t(c3)});
                        else mesh.faces.insert(mesh.faces.end(), {uint32_t(c0), uint32_t(c3), uint32_t(c2), uint32_t(c0), uint32_t(c2), uint32_t(c1)});
                    }
                }
            }
        }
    }
    if (profile)
        std::printf("extract: %.2f ms (%zu mixed cells)\n", (now_us_() - t0) / 1000.0, mixed);
}

bool ShapeModel::load_motion(const std::string &path, std::string *error) {
    std::ifstream f(path, std::ios::binary);
    auto fail = [&](const char *why) {
        if (error) *error = path + ": " + why;
        mq_.clear();
        return false;
    };
    if (!f) return fail("cannot open");
    if (base_.empty()) return fail("shape model not loaded");
    char magic[4];
    uint32_t rk[2];
    if (!f.read(magic, 4) || std::memcmp(magic, "EMOT", 4) || !f.read(reinterpret_cast<char *>(rk), 8))
        return fail("bad header");
    if (int(rk[0]) != res_ || int(rk[1]) != k_) return fail("size differs from shape_model.bin");
    const size_t n = base_.size();
    mq_.resize(n * (k_ + 1));
    if (!f.read(reinterpret_cast<char *>(mscale_), std::streamsize(4) * (k_ + 1)) ||
        !f.read(reinterpret_cast<char *>(mq_.data()), std::streamsize(mq_.size() * 2)))
        return fail("truncated");
    return true;
}

void ShapeModel::motion(const int8_t codes[16], std::vector<float> &ds) const {
    const size_t n = base_.size();
    ds.resize(n);
    if (mq_.empty()) {
        std::fill(ds.begin(), ds.end(), 0.f);
        return;
    }
    float qc[16];
    for (int k = 0; k < k_; k++) qc[k] = float(codes[k]) * mscale_[k + 1];
    constexpr size_t CHUNK = 2048;
    for (size_t s = 0; s < n; s += CHUNK) {
        const size_t len = std::min(CHUNK, n - s);
        float *out = ds.data() + s;
        const int16_t *b = mq_.data() + s;
        for (size_t i = 0; i < len; i++) out[i] = mscale_[0] * float(b[i]);
        for (int k = 0; k < k_; k++) {
            if (!codes[k]) continue;
            const float c = qc[k];
            const int16_t *q = mq_.data() + size_t(k + 1) * n + s;
            for (size_t i = 0; i < len; i++) out[i] += c * float(q[i]);
        }
    }
}

uint32_t ShapeModel::blend(const std::vector<float> &sdf, const std::vector<float> &ds, float w,
                           std::vector<float> &out, std::vector<uint8_t> &inside) const {
    const size_t n = sdf.size();
    out.resize(n);
    inside.resize(n);
    uint32_t count = 0;
    for (size_t i = 0; i < n; i++) {
        out[i] = sdf[i] + w * ds[i];
        inside[i] = is_inside(out[i]);
        count += inside[i];
    }
    return count;
}

void ShapeModel::mean_mesh(Mesh &mesh) const {
    std::vector<uint8_t> inside(base_.size());
    for (size_t i = 0; i < base_.size(); i++) inside[i] = is_inside(base_[i]);
    extract(base_, inside, mesh);
}

}  // namespace app
