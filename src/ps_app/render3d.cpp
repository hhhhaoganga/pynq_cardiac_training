#include "render3d.hpp"

#include <pthread.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>

#include "hw.hpp"

// Integer rasteriser: on the Cortex-A9 every scalar float compare (vmrs) and
// float->int move stalls the VFP pipeline, so all per-pixel work is fixed point.

namespace app {

void MeshRenderer::set_mesh(const std::vector<float> &v, const std::vector<uint32_t> &faces,
                            const std::vector<uint32_t> &colors, bool refit) {
    faces_ = faces;
    rgb_ = colors;
    pos_ = v;
    translucent_ = std::any_of(colors.begin(), colors.end(), [](uint32_t c) { return c >> 24; });
    const size_t n = v.size() / 3;
    if (refit && n) {
        double c[3] = {0, 0, 0};
        for (size_t i = 0; i < n; i++)
            for (int k = 0; k < 3; k++) c[k] += v[3 * i + k];
        for (int k = 0; k < 3; k++) centre_[k] = float(c[k] / n);
        double r2 = 0;
        for (size_t i = 0; i < n; i++) {
            double d = 0;
            for (int k = 0; k < 3; k++) d += (v[3 * i + k] - centre_[k]) * (v[3 * i + k] - centre_[k]);
            r2 = std::max(r2, d);
        }
        radius_ = r2 > 0 ? float(std::sqrt(r2)) : 1.f;
    }
    // Depth range from this mesh's own extent around the view centre. Later
    // cases keep the mean shape's centre and scale but can be larger than it:
    // a depth scale from the mean radius pushed their near side (the apex,
    // when it faces the viewer) below z = 0, and those pixels wrapped and
    // failed the depth test, as if cut by a plane.
    double e2 = 0;
    for (size_t i = 0; i < n; i++) {
        double d = 0;
        for (int k = 0; k < 3; k++) d += (v[3 * i + k] - centre_[k]) * (v[3 * i + k] - centre_[k]);
        e2 = std::max(e2, d);
    }
    depth_r_ = e2 > 0 ? float(std::sqrt(e2)) * 1.01f : radius_;
    nrm_.assign(v.size(), 0.f);
    double vol = 0, vol_abs = 0;
    for (size_t f = 0; f + 2 < faces_.size(); f += 3) {
        const uint32_t a = faces_[f], b = faces_[f + 1], c = faces_[f + 2];
        const float *p0 = &v[3 * a], *p1 = &v[3 * b], *p2 = &v[3 * c];
        const float e1[3] = {p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2]};
        const float e2[3] = {p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2]};
        const float fn[3] = {e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2],
                             e1[0] * e2[1] - e1[1] * e2[0]};
        for (uint32_t i : {a, b, c})
            for (int k = 0; k < 3; k++) nrm_[3 * i + k] += fn[k];
        // Signed volume relative to the centre tells us the winding.
        const double t = ((p0[0] - centre_[0]) * fn[0] + (p0[1] - centre_[1]) * fn[1] + (p0[2] - centre_[2]) * fn[2]);
        vol += t;
        vol_abs += std::fabs(t);
    }
    for (size_t i = 0; i < n; i++) {
        float *q = &nrm_[3 * i];
        const float l = std::sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2]) + 1e-12f;
        q[0] /= l, q[1] /= l, q[2] /= l;
    }
    // Closed, consistently wound mesh: cull back faces (half the triangles).
    // Screen y points down, so front faces of an outward-wound mesh have a
    // negative screen-space area.
    const double consistency = vol_abs > 0 ? vol / vol_abs : 0;
    cull_ = std::fabs(consistency) < 0.25 ? 0 : (consistency > 0 ? -1 : 1);
    consistency_ = float(consistency);
}

// ---- helper core -------------------------------------------------------------
MeshRenderer::MeshRenderer() {
    helper_ = std::thread([this] {
        pthread_setname_np(pthread_self(), "raster2");
        std::unique_lock<std::mutex> l(m_);
        for (;;) {
            cv_.wait(l, [&] { return quit_ || job_; });
            if (quit_) return;
            auto fn = std::move(job_);
            job_ = nullptr;
            l.unlock();
            fn();
            l.lock();
            busy_ = false;
            cv_.notify_all();
        }
    });
}

MeshRenderer::~MeshRenderer() {
    {
        std::lock_guard<std::mutex> l(m_);
        quit_ = true;
    }
    cv_.notify_all();
    helper_.join();
}

void MeshRenderer::fork(std::function<void()> fn) {
    std::lock_guard<std::mutex> l(m_);
    job_ = std::move(fn);
    busy_ = true;
    cv_.notify_all();
}

void MeshRenderer::join() {
    std::unique_lock<std::mutex> l(m_);
    cv_.wait(l, [&] { return !busy_; });
}

// ---- drawing -----------------------------------------------------------------
void MeshRenderer::draw(gfx::Canvas &c, int ox, int oy, int w, int h, float yaw, float pitch, uint32_t bg) {
    const float cy = std::cos(yaw), sy = std::sin(yaw), cp = std::cos(pitch), sp = std::sin(pitch);
    const float R[3][3] = {{cy, 0, sy}, {sp * sy, cp, -sp * cy}, {-cp * sy, sp, cp * cy}};
    draw(c, ox, oy, w, h, R, bg);
}

void MeshRenderer::transform(size_t i0, size_t i1, const float R[3][3], int w, int h, float scale) {
    const float L[3] = {-0.35f, 0.55f, 0.76f};
    const float H[3] = {-0.18f, 0.29f, 0.94f};
    const float zmul = 32767.f / depth_r_;  // |q[2]| <= depth_r_: vz stays inside 0..65535
    for (size_t i = i0; i < i1; i++) {
        const float p[3] = {pos_[3 * i] - centre_[0], pos_[3 * i + 1] - centre_[1], pos_[3 * i + 2] - centre_[2]};
        const float *nm = &nrm_[3 * i];
        float q[3], m[3];
        for (int r = 0; r < 3; r++) {
            q[r] = R[r][0] * p[0] + R[r][1] * p[1] + R[r][2] * p[2];
            m[r] = R[r][0] * nm[0] + R[r][1] * nm[1] + R[r][2] * nm[2];
        }
        // 28.4 fixed-point screen coordinates relative to the viewport.
        vx_[i] = int32_t((w * 0.5f + q[0] * scale) * 16.f);
        vy_[i] = int32_t((h * 0.5f - q[1] * scale) * 16.f);
        vz_[i] = int32_t(32768.f - q[2] * zmul);  // nearer = smaller, 0..65535
        const float d = std::fabs(m[0] * L[0] + m[1] * L[1] + m[2] * L[2]);
        float s = std::fabs(m[0] * H[0] + m[1] * H[1] + m[2] * H[2]);
        s *= s, s *= s, s *= s;          // ^8
        s = s * s * s;                   // ^24
        const float k = 0.28f + 0.72f * d, spec = 90.f * s;
        const uint32_t base = i < rgb_.size() ? rgb_[i] : gfx::rgb(220, 190, 180);
        for (int ch = 0; ch < 3; ch++) {
            int v = int(((base >> (16 - 8 * ch)) & 0xFF) * k + spec);
            vc_[3 * i + ch] = v > 255 ? 255 : v;
        }
    }
}
// Rows [band_y0, band_y1] of the viewport: background, z-buffer and every
// face clipped to the band. The two bands touch disjoint pixels.
void MeshRenderer::raster(gfx::Canvas &c, int ox, int oy, int w, int band_y0, int band_y1, int x_lo, int x_hi,
                          uint32_t bg) {
    if (band_y0 > band_y1) return;
    c.rect(ox, oy + band_y0, w, band_y1 - band_y0 + 1, bg);
    std::fill(zbuf_.begin() + size_t(band_y0) * w, zbuf_.begin() + size_t(band_y1 + 1) * w, uint16_t(0xFFFF));
    const int by_band0 = band_y0 * 16, by_band1 = band_y1 * 16 + 15;
    // Two passes: opaque faces write depth; translucent faces (opacity in the
    // top colour byte, 0 = opaque) are depth tested against them and blended
    // without writing depth. With back faces culled only the front layer of a
    // translucent shell is blended, so the result does not depend on order.
    for (int pass = 0; pass < (translucent_ ? 2 : 1); pass++)
    for (size_t f = 0; f + 2 < faces_.size(); f += 3) {
        uint32_t a = faces_[f], b = faces_[f + 1], d = faces_[f + 2];
        const uint32_t alpha = a < rgb_.size() ? rgb_[a] >> 24 : 0;
        if ((alpha != 0) != (pass == 1)) continue;
        int32_t Y0 = vy_[a], Y1 = vy_[b], Y2 = vy_[d];
        // Cheap reject before any other work: the face misses this band.
        if (std::max({Y0, Y1, Y2}) < by_band0 || std::min({Y0, Y1, Y2}) > by_band1) continue;
        int32_t X0 = vx_[a], X1 = vx_[b], X2 = vx_[d];
        int64_t area = int64_t(X1 - X0) * (Y2 - Y0) - int64_t(X2 - X0) * (Y1 - Y0);
        if (area == 0 || (cull_ && (area > 0) != (cull_ > 0))) continue;
        if (area < 0) {  // make it counter-clockwise in screen space
            std::swap(b, d);
            std::swap(X1, X2);
            std::swap(Y1, Y2);
            area = -area;
        }
        const int bx0 = std::max(x_lo, (std::min({X0, X1, X2}) >> 4));
        const int bx1 = std::min(x_hi, (std::max({X0, X1, X2}) + 15) >> 4);
        const int by0 = std::max(band_y0, (std::min({Y0, Y1, Y2}) >> 4));
        const int by1 = std::min(band_y1, (std::max({Y0, Y1, Y2}) + 15) >> 4);
        if (bx0 > bx1 || by0 > by1) continue;
        // Edge functions at the first pixel centre, and their per-pixel steps.
        // Coordinates are < 2^14 in 28.4, so edge values fit in int32.
        const int32_t px0 = bx0 * 16 + 8, py0 = by0 * 16 + 8;
        auto edge = [&](int32_t xa, int32_t ya, int32_t xb, int32_t yb) {
            return (xb - xa) * (py0 - ya) - (yb - ya) * (px0 - xa);
        };
        int32_t e0r = edge(X1, Y1, X2, Y2), e1r = edge(X2, Y2, X0, Y0), e2r = edge(X0, Y0, X1, Y1);
        const int32_t e0x = -(Y2 - Y1) * 16, e1x = -(Y0 - Y2) * 16, e2x = -(Y1 - Y0) * 16;
        const int32_t e0y = (X2 - X1) * 16, e1y = (X0 - X2) * 16, e2y = (X1 - X0) * 16;
        // Depth plane from the barycentrics, 16.8 fixed point to stay inside int32.
        const float inv = 1.f / float(area);
        const float v0 = float(vz_[a]), v1 = float(vz_[b]), v2 = float(vz_[d]);
        const int32_t zdx = int32_t((v0 * e0x + v1 * e1x + v2 * e2x) * inv * 256.f);
        const int32_t zdy = int32_t((v0 * e0y + v1 * e1y + v2 * e2y) * inv * 256.f);
        int32_t z0 = int32_t((v0 * float(e0r) + v1 * float(e1r) + v2 * float(e2r)) * inv * 256.f);
        // Faces are ~5 px wide on screen: one colour per face (mean of its lit
        // vertices) looks the same as Gouraud and keeps the loop in registers.
        const uint32_t col = uint32_t((vc_[3 * a] + vc_[3 * b] + vc_[3 * d]) / 3) << 16 |
                             uint32_t((vc_[3 * a + 1] + vc_[3 * b + 1] + vc_[3 * d + 1]) / 3) << 8 |
                             uint32_t((vc_[3 * a + 2] + vc_[3 * b + 2] + vc_[3 * d + 2]) / 3);
        for (int py = by0; py <= by1; py++) {
            int32_t e0 = e0r, e1 = e1r, e2 = e2r, z = z0;
            uint32_t *row = c.row(oy + py) + ox;
            uint16_t *zrow = &zbuf_[size_t(py) * w];
            for (int px = bx0; px <= bx1; px++) {
                if ((e0 | e1 | e2) >= 0) {
                    const uint32_t zi = uint32_t(z) >> 8;  // plane stays inside 0..65535 within the face
                    if (zi < zrow[px]) {
                        if (!alpha) {
                            zrow[px] = uint16_t(zi);
                            row[px] = col;
                        } else {
                            const uint32_t dst = row[px], ia = 256 - alpha;
                            const uint32_t rb = ((col & 0xFF00FF) * alpha + (dst & 0xFF00FF) * ia) >> 8 & 0xFF00FF;
                            const uint32_t g = ((col & 0xFF00) * alpha + (dst & 0xFF00) * ia) >> 8 & 0xFF00;
                            row[px] = rb | g;
                        }
                    }
                }
                e0 += e0x, e1 += e1x, e2 += e2x, z += zdx;
            }
            e0r += e0y, e1r += e1y, e2r += e2y, z0 += zdy;
        }
    }
}

void MeshRenderer::draw(gfx::Canvas &c, int ox, int oy, int w, int h, const float R[3][3], uint32_t bg,
                        float zoom) {
    const uint64_t t_start = hw::now_us();
    if (!ready()) {
        c.rect(ox, oy, w, h, bg);
        return;
    }
    const size_t n = pos_.size() / 3;
    const float scale = 0.46f * zoom * std::min(w, h) / radius_;
    vx_.resize(n);
    vy_.resize(n);
    vz_.resize(n);
    vc_.resize(3 * n);
    zbuf_.resize(size_t(w) * h);
    float Rc[3][3];  // the helper must not read the caller's stack after we return
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++) Rc[i][j] = R[i][j];
    const size_t mid = n / 2;
    fork([&] { transform(mid, n, Rc, w, h, scale); });
    transform(0, mid, Rc, w, h, scale);
    join();
    const uint64_t t_vert = hw::now_us();
    const int x_lo = std::max(0, -ox), y_lo = std::max(0, -oy);
    const int x_hi = std::min(w, c.w - ox) - 1, y_hi = std::min(h, c.h - oy) - 1;
    const int split = (y_lo + y_hi) / 2;
    fork([&] { raster(c, ox, oy, w, split + 1, y_hi, x_lo, x_hi, bg); });
    raster(c, ox, oy, w, y_lo, split, x_lo, x_hi, bg);
    join();
    last_vert_ms = (t_vert - t_start) / 1000.0;
    last_raster_ms = (hw::now_us() - t_vert) / 1000.0;
    if (profile_) {
        const uint64_t t_end = hw::now_us();
        std::printf("draw: verts %.2f ms, raster %.2f ms (2 cores)\n", (t_vert - t_start) / 1000.0,
                    (t_end - t_vert) / 1000.0);
    }
}

}  // namespace app
