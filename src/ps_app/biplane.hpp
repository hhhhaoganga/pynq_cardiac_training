// Biplane Simpson (method of disks) from manually placed landmarks, ported
// from the FreeRTOS camus_biplane.h. 20 disks perpendicular to the apex ->
// mitral-base-midpoint axis; the CAMUS/VITAL convention uses one common disk
// height, the longest of the four ED/ES long axes. The landmarks are never
// guessed here.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace app {

constexpr int DISKS = 20;

struct Pt {
    double x = 0, y = 0;  // mask pixel coordinates
};

struct DiskProfile {
    double length_mm = 0;
    double diameter_mm[DISKS] = {};
    Pt chord[DISKS][2];  // chord end points, for drawing
};

struct BiplaneResult {
    double edv_ml = 0, esv_ml = 0, ef_percent = 0, disk_height_mm = 0;
};

// 0 ok; -1 bad input, -2 axis too short, -3 disk centre outside LV,
// -4 chord leaves the image.
inline int measure_profile(const uint8_t *mask, int w, int h, double sx, double sy, Pt apex, Pt base,
                           DiskProfile &out) {
    out = DiskProfile{};
    if (!mask || w < 2 || h < 2 || !(sx > 0) || !(sy > 0) || apex.x < 0 || apex.x >= w || apex.y < 0 ||
        apex.y >= h || base.x < 0 || base.x >= w || base.y < 0 || base.y >= h)
        return -1;
    const double dx = (base.x - apex.x) * sx, dy = (base.y - apex.y) * sy;
    const double length = std::hypot(dx, dy);
    if (length <= 2 * std::max(sx, sy)) return -2;
    const double step = std::min(sx, sy) / 4, limit = std::hypot(w * sx, h * sy);
    for (int d = 0; d < DISKS; d++) {
        const double t = (d + 0.5) / DISKS;
        const double cx = apex.x * sx + t * dx, cy = apex.y * sy + t * dy;
        const int ix = int(std::floor(cx / sx + 0.5)), iy = int(std::floor(cy / sy + 0.5));
        if (ix < 0 || ix >= w || iy < 0 || iy >= h || mask[iy * w + ix] != 1) return -3;
        double extent[2] = {0, 0};
        // Stop at the first boundary, never bridge islands or holes.
        for (int side = 0; side < 2; side++) {
            const double sign = side ? 1 : -1;
            bool hit = false;
            for (double r = step; r <= limit; r += step) {
                const int x = int(std::floor((cx - sign * r * dy / length) / sx + 0.5));
                const int y = int(std::floor((cy + sign * r * dx / length) / sy + 0.5));
                if (x < 0 || x >= w || y < 0 || y >= h) return -4;
                if (mask[y * w + x] != 1) {
                    extent[side] = r - step / 2;
                    hit = true;
                    break;
                }
            }
            if (!hit) return -4;
            out.chord[d][side] = {(cx - sign * extent[side] * dy / length) / sx,
                                  (cy + sign * extent[side] * dx / length) / sy};
        }
        out.diameter_mm[d] = extent[0] + extent[1];
    }
    out.length_mm = length;
    return 0;
}

inline bool volume_at_length(const DiskProfile &a, const DiskProfile &b, double length_mm, double &ml) {
    ml = 0;
    if (!(a.length_mm > 0) || !(b.length_mm > 0) || !(length_mm > 0)) return false;
    double sum = 0;
    for (int i = 0; i < DISKS; i++) {
        if (!(a.diameter_mm[i] > 0) || !(b.diameter_mm[i] > 0)) return false;
        sum += a.diameter_mm[i] * b.diameter_mm[i];
    }
    ml = M_PI * sum * length_mm / (4.0 * DISKS * 1000.0);
    return std::isfinite(ml) && ml > 0;
}

// a = one view, b = the other; volumes are symmetric in the two views.
inline bool measure_cycle(const DiskProfile &a_ed, const DiskProfile &b_ed, const DiskProfile &a_es,
                          const DiskProfile &b_es, BiplaneResult &out) {
    out = BiplaneResult{};
    const double len = std::max({a_ed.length_mm, b_ed.length_mm, a_es.length_mm, b_es.length_mm});
    BiplaneResult r;
    if (!volume_at_length(a_ed, b_ed, len, r.edv_ml) || !volume_at_length(a_es, b_es, len, r.esv_ml) ||
        r.esv_ml > r.edv_ml)
        return false;
    r.ef_percent = 100.0 * (r.edv_ml - r.esv_ml) / r.edv_ml;
    r.disk_height_mm = len / DISKS;
    out = r;
    return true;
}

inline const char *profile_error(int rc) {
    switch (rc) {
    case -1: return "点不在图像内";
    case -2: return "长轴太短";
    case -3: return "轴线上有圆盘中心不在左心室内";
    case -4: return "圆盘弦越出图像";
    default: return "";
    }
}

}  // namespace app
