#include "lv3d.hpp"

#include <cstring>
#include <queue>

namespace app {

namespace {
constexpr uint8_t LV = 1, MYO = 2, LA = 3;

// Largest 4-connected LV component, written into `keep` (1 inside).
// Scratch buffers are static: this runs on the worker thread only.
bool largest_lv(const uint8_t *mask, int w, int h, std::vector<uint8_t> &keep) {
    keep.assign(size_t(w) * h, 0);
    std::vector<int32_t> lab(size_t(w) * h, -1);
    std::vector<int32_t> stack;
    int best = -1, best_n = 0, next = 0;
    for (int i = 0; i < w * h; i++) {
        if (mask[i] != LV || lab[i] >= 0) continue;
        const int id = next++;
        int n = 0;
        stack.push_back(i);
        lab[i] = id;
        while (!stack.empty()) {
            const int p = stack.back();
            stack.pop_back();
            n++;
            const int x = p % w, y = p / w;
            const int nb[4] = {x > 0 ? p - 1 : -1, x + 1 < w ? p + 1 : -1, y > 0 ? p - w : -1,
                               y + 1 < h ? p + w : -1};
            for (int q : nb)
                if (q >= 0 && mask[q] == LV && lab[q] < 0) {
                    lab[q] = id;
                    stack.push_back(q);
                }
        }
        if (n > best_n) best_n = n, best = id;
    }
    if (best < 0 || best_n < 32) return false;
    for (int i = 0; i < w * h; i++)
        if (lab[i] == best) keep[i] = 1;
    return true;
}
}  // namespace

bool lv_landmarks(const uint8_t *mask, int w, int h, double sx, double sy, Pt &apex, Pt &base) {
    std::vector<uint8_t> lv;
    if (!largest_lv(mask, w, h, lv)) return false;
    // Interface points: LV pixels with LA within two pixels (the mitral plane).
    // Without a visible LA, fall back to the lowest LV rows (apex-up frames).
    std::vector<double> ix, iy;
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            if (!lv[size_t(y) * w + x]) continue;
            bool near_la = false;
            for (int dy = -2; dy <= 2 && !near_la; dy++)
                for (int dx = -2; dx <= 2; dx++) {
                    const int u = x + dx, v = y + dy;
                    if (u < 0 || u >= w || v < 0 || v >= h) continue;
                    if (mask[size_t(v) * w + u] == LA) {
                        near_la = true;
                        break;
                    }
                }
            if (near_la) ix.push_back(x), iy.push_back(y);
        }
    if (ix.size() < 3) {
        ix.clear(), iy.clear();
        int ymax = -1;
        for (int y = h - 1; y >= 0 && ymax < 0; y--)
            for (int x = 0; x < w; x++)
                if (lv[size_t(y) * w + x]) {
                    ymax = y;
                    break;
                }
        if (ymax < 0) return false;
        const int y0 = std::max(0, ymax - 3);
        for (int y = y0; y <= ymax; y++)
            for (int x = 0; x < w; x++)
                if (lv[size_t(y) * w + x]) ix.push_back(x), iy.push_back(y);
        if (ix.size() < 3) return false;
    }
    // Base = midpoint of the two interface points farthest apart. The spread
    // direction is the first principal axis of the interface points, so a
    // tilted mitral plane is handled as well.
    double mx = 0, my = 0;
    for (size_t i = 0; i < ix.size(); i++) mx += ix[i] * sx, my += iy[i] * sy;
    mx /= ix.size(), my /= ix.size();
    double cxx = 0, cxy = 0, cyy = 0;
    for (size_t i = 0; i < ix.size(); i++) {
        const double dx = ix[i] * sx - mx, dy = iy[i] * sy - my;
        cxx += dx * dx, cxy += dx * dy, cyy += dy * dy;
    }
    // Principal direction of the 2x2 covariance.
    const double t = 0.5 * std::atan2(2 * cxy, cxx - cyy);
    const double ux = std::cos(t), uy = std::sin(t);
    double lo = 1e18, hi = -1e18;
    size_t ilo = 0, ihi = 0;
    for (size_t i = 0; i < ix.size(); i++) {
        const double p = (ix[i] * sx - mx) * ux + (iy[i] * sy - my) * uy;
        if (p < lo) lo = p, ilo = i;
        if (p > hi) hi = p, ihi = i;
    }
    base = {(ix[ilo] + ix[ihi]) / 2.0, (iy[ilo] + iy[ihi]) / 2.0};
    // Apex = LV pixel farthest from the base (in mm).
    double far = -1;
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            if (!lv[size_t(y) * w + x]) continue;
            const double dx = (x - base.x) * sx, dy = (y - base.y) * sy;
            const double d = dx * dx + dy * dy;
            if (d > far) far = d, apex = {double(x), double(y)};
        }
    return far > 0;
}

bool lv_measure(const uint8_t *mask, int w, int h, double sx, double sy, LvRing &out) {
    out = LvRing{};
    if (!mask || w < 2 || h < 2 || !(sx > 0) || !(sy > 0)) return false;
    Pt apex, base;
    if (!lv_landmarks(mask, w, h, sx, sy, apex, base)) return false;
    const double dx = (base.x - apex.x) * sx, dy = (base.y - apex.y) * sy;
    const double len = std::hypot(dx, dy);
    if (len <= 4 * std::max(sx, sy)) return false;
    const double step = std::min(sx, sy) / 4;
    const double ax = apex.x * sx, ay = apex.y * sy;
    // Unit vector along the axis and its perpendicular.
    const double ux = dx / len, uy = dy / len, px = -uy, py = ux;
    auto cls = [&](double mmx, double mmy) -> int {
        const int x = int(std::floor(mmx / sx + 0.5)), y = int(std::floor(mmy / sy + 0.5));
        return x >= 0 && x < w && y >= 0 && y < h ? mask[size_t(y) * w + x] : 0;
    };
    auto in_lv = [&](double mmx, double mmy) { return cls(mmx, mmy) == LV; };
    auto in_wall = [&](double mmx, double mmy) {
        const int k = cls(mmx, mmy);
        return k == LV || k == MYO;
    };
    double area = 0;
    for (int d = 0; d < LV_LEVELS; d++) {
        const double t = (d + 0.5) / LV_LEVELS;
        const double cx = ax + t * dx, cy = ay + t * dy;
        double ext[2] = {0, 0};
        for (int side = 0; side < 2; side++) {
            const double sg = side ? 1 : -1;
            double r = 0;
            // The thin apex disk can start just outside; march while inside.
            while (r < len && in_lv(cx + sg * (r + step) * px, cy + sg * (r + step) * py)) r += step;
            ext[side] = r;
        }
        if (!in_lv(cx, cy)) ext[0] = ext[1] = 0;
        out.half[d] = float((ext[0] + ext[1]) / 2);
        out.off[d] = float((ext[1] - ext[0]) / 2);
        area += (ext[0] + ext[1]) * len / LV_LEVELS;
        // Epicardium on the same ray: keep marching through the myocardium.
        // Average of both sides, so a one-sided wall still gives a sane radius.
        double epi[2] = {ext[0], ext[1]};
        for (int side = 0; side < 2; side++) {
            const double sg = side ? 1 : -1;
            double r = ext[side];
            if (ext[side] > 0)
                while (r < len && in_wall(cx + sg * (r + step) * px, cy + sg * (r + step) * py)) r += step;
            epi[side] = r;
        }
        out.epi[d] = float((epi[0] + epi[1]) / 2);
    }
    // Apical cap: the disks run perpendicular to the axis and never cross it,
    // so march from the apex away from the base through LV + MYO instead.
    double cap = 0;
    while (cap < len / 2 && in_wall(ax - (cap + step) * ux, ay - (cap + step) * uy)) cap += step;
    out.apex_wall_mm = float(cap);
    out.length_mm = float(len);
    out.area_mm2 = float(area);
    out.valid = out.half[LV_LEVELS / 2] > 0;  // mid-cavity must have width
    return out.valid;
}

double lv_volume_ml(const LvRing &a, const LvRing &b, double length_mm) {
    if (!a.valid || !b.valid || !(length_mm > 0)) return 0;
    double sum = 0;
    for (int i = 0; i < LV_LEVELS; i++) sum += double(a.half[i]) * b.half[i];
    const double ml = M_PI * sum * length_mm / (LV_LEVELS * 1000.0);
    return std::isfinite(ml) && ml > 0 ? ml : 0;
}

void lv_smooth(std::vector<LvRing> &rings) {
    const size_t n = rings.size();
    if (n < 3) return;
    std::vector<LvRing> src = rings;
    auto at = [&](size_t i) -> const LvRing & { return src[std::min(i, n - 1)]; };
    for (size_t i = 0; i < n; i++) {
        if (!src[i].valid) continue;
        const LvRing &p = at(i ? i - 1 : 0), &c = src[i], &q = at(i + 1);
        // Only average over neighbours that were measured.
        const float wp = p.valid ? 0.25f : 0.f, wq = q.valid ? 0.25f : 0.f;
        const float wc = 1.f - wp - wq;
        LvRing &o = rings[i];
        o.length_mm = wp * p.length_mm + wc * c.length_mm + wq * q.length_mm;
        o.area_mm2 = wp * p.area_mm2 + wc * c.area_mm2 + wq * q.area_mm2;
        o.apex_wall_mm = wp * p.apex_wall_mm + wc * c.apex_wall_mm + wq * q.apex_wall_mm;
        for (int k = 0; k < LV_LEVELS; k++) {
            o.half[k] = wp * p.half[k] + wc * c.half[k] + wq * q.half[k];
            o.off[k] = wp * p.off[k] + wc * c.off[k] + wq * q.off[k];
            o.epi[k] = wp * p.epi[k] + wc * c.epi[k] + wq * q.epi[k];
        }
    }
}

namespace {
// Resample the LV_LEVELS disks to `levels` smooth rings (linear, clamped).
void resample(const float *v, int levels, std::vector<float> &out) {
    out.resize(levels);
    for (int i = 0; i < levels; i++) {
        const float t = (i + 0.5f) / levels * LV_LEVELS - 0.5f;
        const int i0 = std::clamp(int(std::floor(t)), 0, LV_LEVELS - 1);
        const int i1 = std::clamp(i0 + 1, 0, LV_LEVELS - 1);
        const float f = std::clamp(t - i0, 0.f, 1.f);
        out[i] = v[i0] * (1 - f) + v[i1] * f;
    }
}

uint32_t mix_rgb(uint32_t a, uint32_t b, float t) {
    t = std::clamp(t, 0.f, 1.f);
    uint32_t o = 0;
    for (int s = 0; s <= 16; s += 8) {
        const float ca = (a >> s) & 0xFF, cb = (b >> s) & 0xFF;
        o |= uint32_t(ca + (cb - ca) * t) << s;
    }
    return o;
}

// `shrink` (optional, one value per level, 0..1) colours each ring.
void build(const LvRing &a, const LvRing &b, double length_mm, int levels, int segments, float grow,
           uint32_t color, Mesh &out, const std::vector<float> *shrink = nullptr) {
    std::vector<float> ha, oa, hb, ob;
    resample(a.half, levels, ha);
    resample(a.off, levels, oa);
    resample(b.half, levels, hb);
    resample(b.off, levels, ob);
    const uint32_t v0 = uint32_t(out.verts.size() / 3);
    for (int i = 0; i < levels; i++) {
        const float z = float((i + 0.5) / levels * length_mm);
        const float ra = ha[i] + grow, rb = hb[i] + grow;
        const uint32_t col = shrink ? mix_rgb(0xE8B9A8, 0x2F6FE0, (*shrink)[i]) : color;
        for (int j = 0; j < segments; j++) {
            const float th = float(2 * M_PI * j / segments);
            out.verts.push_back(oa[i] + ra * std::cos(th));
            out.verts.push_back(ob[i] + rb * std::sin(th));
            out.verts.push_back(z);
            out.colors.push_back(col);
        }
    }
    // Apex and base caps.
    const uint32_t tip = uint32_t(out.verts.size() / 3);
    out.verts.push_back(oa[0]);
    out.verts.push_back(ob[0]);
    out.verts.push_back(0.f);
    out.colors.push_back(shrink ? mix_rgb(0xE8B9A8, 0x2F6FE0, shrink->front()) : color);
    const uint32_t top = uint32_t(out.verts.size() / 3);
    out.verts.push_back(oa[levels - 1]);
    out.verts.push_back(ob[levels - 1]);
    out.verts.push_back(float(length_mm));
    out.colors.push_back(shrink ? mix_rgb(0xE8B9A8, 0x2F6FE0, shrink->back()) : color);
    for (int i = 0; i + 1 < levels; i++)
        for (int j = 0; j < segments; j++) {
            const uint32_t p = v0 + i * segments + j, q = v0 + i * segments + (j + 1) % segments;
            out.faces.insert(out.faces.end(), {p, q, q + segments});
            out.faces.insert(out.faces.end(), {p, q + segments, uint32_t(p + segments)});
        }
    const uint32_t last = v0 + (levels - 1) * segments;
    for (int j = 0; j < segments; j++) {
        out.faces.insert(out.faces.end(), {tip, v0 + uint32_t((j + 1) % segments), v0 + uint32_t(j)});
        out.faces.insert(out.faces.end(), {top, last + uint32_t(j), last + uint32_t((j + 1) % segments)});
    }
}
}  // namespace

void lv_mesh(const LvRing &a, const LvRing &b, double length_mm, int segments, uint32_t color, Mesh &out) {
    out = Mesh{};
    if (!a.valid || !b.valid || !(length_mm > 0)) return;
    build(a, b, length_mm, 28, segments, 0.f, color, out);
}

namespace {
constexpr uint32_t CAVITY_RGB = 0xD92A33;
constexpr float HEAT_FULL = 0.5f;  // area loss shown as full red
// Top byte = opacity for the renderer (0 = opaque): a translucent shell.
constexpr uint32_t MYO_RGBA = 0x5CE9C4B6;

// Triangle emitter that orients every face away from its axis point, so all
// surfaces share one outward winding and back-face culling stays valid.
struct Emit {
    Mesh &m;
    std::vector<float> axis;  // per vertex: the centreline point it belongs to
    uint32_t vert(float x, float y, float z, float cx, float cy, float cz, uint32_t col) {
        m.verts.insert(m.verts.end(), {x, y, z});
        axis.insert(axis.end(), {cx, cy, cz});
        m.colors.push_back(col);
        return uint32_t(m.colors.size() - 1);
    }
    void tri(uint32_t a, uint32_t b, uint32_t c) {
        const float *p = &m.verts[3 * a], *q = &m.verts[3 * b], *r = &m.verts[3 * c];
        const float e1[3] = {q[0] - p[0], q[1] - p[1], q[2] - p[2]}, e2[3] = {r[0] - p[0], r[1] - p[1], r[2] - p[2]};
        const float n[3] = {e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0]};
        float h = 0;
        for (int k = 0; k < 3; k++)
            h += n[k] * ((p[k] + q[k] + r[k]) - (axis[3 * a + k] + axis[3 * b + k] + axis[3 * c + k]));
        if (h < 0) std::swap(b, c);
        m.faces.insert(m.faces.end(), {a, b, c});
    }
};

// Closed tube of stacked ellipses (radii ra/rb, centre offsets ox/oz at
// heights y), a rounded dome below the first ring reaching down to
// y[0] - depth, and a flat cap on the last ring (the mitral plane).
void tube(Emit &e, const std::vector<float> &ra, const std::vector<float> &rb, const std::vector<float> &ox,
          const std::vector<float> &oz, const std::vector<float> &y, float depth, int seg, int dome, uint32_t col,
          const std::vector<uint32_t> *cols = nullptr) {
    const int n = int(y.size());
    // Rings: dome rings first (from the tip upwards), then the measured levels.
    std::vector<uint32_t> idx;
    int rows = 0;
    // `cols` (optional) colours each measured level; the dome takes level 0.
    auto lc = [&](int i) { return cols ? (*cols)[std::clamp(i, 0, n - 1)] : col; };
    auto ring = [&](float sa, float sb, float cx, float yy, float cz, float axy, uint32_t rc) {
        for (int j = 0; j < seg; j++) {
            const float th = float(2 * M_PI * j / seg);
            idx.push_back(e.vert(cx + sa * std::cos(th), yy, cz + sb * std::sin(th), cx, axy, cz, rc));
        }
        rows++;
    };
    const float y0 = y[0];
    for (int k = 1; k < dome; k++) {
        const float ph = float(M_PI / 2 * k / dome);  // 0 at the tip, pi/2 at the first ring
        ring(ra[0] * std::sin(ph), rb[0] * std::sin(ph), ox[0], y0 - depth * std::cos(ph), oz[0], y0, lc(0));
    }
    for (int i = 0; i < n; i++) ring(ra[i], rb[i], ox[i], y[i], oz[i], y[i], lc(i));
    const uint32_t tip = e.vert(ox[0], y0 - depth, oz[0], ox[0], y0, oz[0], lc(0));
    const uint32_t top = e.vert(ox[n - 1], y[n - 1], oz[n - 1], ox[n - 1], y[n - 1] - 1.f, oz[n - 1], lc(n - 1));
    for (int j = 0; j < seg; j++) {
        const int k = (j + 1) % seg;
        e.tri(tip, idx[j], idx[k]);
        e.tri(top, idx[(rows - 1) * seg + j], idx[(rows - 1) * seg + k]);
        for (int r = 0; r + 1 < rows; r++) {
            const uint32_t p = idx[r * seg + j], q = idx[r * seg + k], u = idx[(r + 1) * seg + k], v = idx[(r + 1) * seg + j];
            e.tri(p, q, u);
            e.tri(p, u, v);
        }
    }
}
}  // namespace

uint32_t heat(float t) {
    // Red (diastolic, as at ED) -> violet -> blue (contracted).
    t = std::clamp(t, 0.f, 1.f);
    return t < 0.5f ? mix_rgb(0xE0262E, 0x9B4FC0, t * 2) : mix_rgb(0x9B4FC0, 0x2F6FE0, t * 2 - 1);
}

void lv_mesh_heart(const LvRing &a, const LvRing &b, const LvRing &ra, const LvRing &rb, double length_mm,
                   Mesh &out) {
    out = Mesh{};
    if (!a.valid || !b.valid || !(length_mm > 0)) return;
    constexpr int LEVELS = 28, SEG = 32, DOME = 6;
    std::vector<float> ha, oa, hb, ob, ea, eb;
    resample(a.half, LEVELS, ha);
    resample(a.off, LEVELS, oa);
    resample(b.half, LEVELS, hb);
    resample(b.off, LEVELS, ob);
    resample(a.epi, LEVELS, ea);
    resample(b.epi, LEVELS, eb);
    // Model axes: x = A2C width, y = long axis (apex at 0, base up), z = A4C width.
    const float L = float(length_mm);
    std::vector<float> zl(LEVELS);
    for (int i = 0; i < LEVELS; i++) zl[i] = float((i + 0.5) / LEVELS * L);
    // Myocardium at least 1 mm thick, so the shell never cuts into the cavity.
    for (int i = 0; i < LEVELS; i++) ea[i] = std::max(ea[i], ha[i] + 1.f), eb[i] = std::max(eb[i], hb[i] + 1.f);
    const float wall = std::clamp((a.apex_wall_mm + b.apex_wall_mm) / 2, 1.f, 25.f);
    Emit e{out};
    // Cavity: apex dome down to the measured apex (y = 0).
    // Heat colour per level: fraction of the disk area lost since ED
    // (0 -> red, HEAT_FULL or more -> blue), a regional wall-motion map.
    std::vector<uint32_t> cols;
    if (ra.valid && rb.valid) {
        float f[LV_LEVELS];
        for (int i = 0; i < LV_LEVELS; i++) {
            const float now = a.half[i] * b.half[i], ref = ra.half[i] * rb.half[i];
            f[i] = ref > 1e-3f ? std::clamp(1.f - now / ref, 0.f, 1.f) / HEAT_FULL : 0.f;
        }
        std::vector<float> fr;
        resample(f, LEVELS, fr);
        for (float v : fr) cols.push_back(heat(v));
    }
    tube(e, ha, hb, oa, ob, zl, zl[0], SEG, DOME, CAVITY_RGB, cols.empty() ? nullptr : &cols);
    // Epicardium: same centreline, LV + MYO radii, apex dome down through the
    // measured apical wall. Alpha in the top byte: drawn translucent.
    tube(e, ea, eb, oa, ob, zl, zl[0] + wall, SEG, DOME, MYO_RGBA);
}

}  // namespace app
