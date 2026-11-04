#include "gfx.hpp"

#include <algorithm>
#include <cstdlib>
#include <cstring>

#include <ft2build.h>
#include FT_FREETYPE_H

namespace gfx {

// Same class colours as host/camus_stream_host.py (background, LV, MYO, LA).
const uint32_t CLASS_COLOR[4] = {rgb(0, 0, 0), rgb(235, 64, 52), rgb(50, 205, 90), rgb(55, 125, 235)};

// Exact round(v / 255) for v <= 255*255 without a divide (the A9 has no
// integer divider): (v + 128 + ((v + 128) >> 8)) >> 8.
static inline unsigned div255(unsigned v) {
    v += 128;
    return (v + (v >> 8)) >> 8;
}

uint32_t mix(uint32_t a, uint32_t b, unsigned t) {
    const unsigned s = 255 - t;
    const unsigned r = div255(((a >> 16) & 0xFF) * s + ((b >> 16) & 0xFF) * t);
    const unsigned g = div255(((a >> 8) & 0xFF) * s + ((b >> 8) & 0xFF) * t);
    const unsigned bl = div255((a & 0xFF) * s + (b & 0xFF) * t);
    return (r << 16) | (g << 8) | bl;
}

namespace {
struct Clip {
    int x0, y0, x1, y1;
    bool empty() const { return x0 >= x1 || y0 >= y1; }
};
Clip clip(const Canvas &c, int x, int y, int w, int h) {
    return {std::max(x, 0), std::max(y, 0), std::min(x + w, c.w), std::min(y + h, c.h)};
}
}  // namespace

void Canvas::fill(uint32_t c) {
    for (int y = 0; y < h; y++) std::fill_n(row(y), w, c);
}

void Canvas::rect(int x, int y, int rw, int rh, uint32_t c) {
    const Clip k = clip(*this, x, y, rw, rh);
    if (k.empty()) return;
    for (int yy = k.y0; yy < k.y1; yy++) std::fill(row(yy) + k.x0, row(yy) + k.x1, c);
}

void Canvas::blend_rect(int x, int y, int rw, int rh, uint32_t c, unsigned alpha) {
    const Clip k = clip(*this, x, y, rw, rh);
    if (k.empty()) return;
    for (int yy = k.y0; yy < k.y1; yy++) {
        uint32_t *p = row(yy);
        for (int xx = k.x0; xx < k.x1; xx++) p[xx] = mix(p[xx], c, alpha);
    }
}

void Canvas::dim(int x, int y, int rw, int rh) {
    const Clip k = clip(*this, x, y, rw, rh);
    if (k.empty()) return;
    for (int yy = k.y0; yy < k.y1; yy++) {
        uint32_t *p = row(yy);
        for (int xx = k.x0; xx < k.x1; xx++) {
            const uint32_t v = p[xx];
            // Each channel * 3/8 (never carries into the next), plus a dark blue tint.
            p[xx] = ((v >> 2) & 0x3F3F3F) + ((v >> 3) & 0x1F1F1F) + 0x030509;
        }
    }
}

void Canvas::round_rect(int x, int y, int rw, int rh, int r, uint32_t c, unsigned alpha) {
    const Clip k = clip(*this, x, y, rw, rh);
    if (k.empty()) return;
    for (int yy = k.y0; yy < k.y1; yy++) {
        uint32_t *p = row(yy);
        const int dy = yy < y + r ? y + r - yy : (yy >= y + rh - r ? yy - (y + rh - r - 1) : 0);
        if (!dy && alpha >= 255) {  // rows between the corners: a plain fill
            std::fill(p + k.x0, p + k.x1, c);
            continue;
        }
        for (int xx = k.x0; xx < k.x1; xx++) {
            const int dx = xx < x + r ? x + r - xx : (xx >= x + rw - r ? xx - (x + rw - r - 1) : 0);
            if (dx && dy && dx * dx + dy * dy > r * r) continue;
            p[xx] = alpha >= 255 ? c : mix(p[xx], c, alpha);
        }
    }
}

void Canvas::frame(int x, int y, int rw, int rh, uint32_t c, int t) {
    rect(x, y, rw, t, c);
    rect(x, y + rh - t, rw, t, c);
    rect(x, y, t, rh, c);
    rect(x + rw - t, y, t, rh, c);
}

void Canvas::vgradient(int x, int y, int rw, int rh, uint32_t top, uint32_t bottom) {
    for (int i = 0; i < rh; i++) rect(x, y + i, rw, 1, mix(top, bottom, rh > 1 ? i * 255 / (rh - 1) : 0));
}

void Canvas::vgradient_part(int x, int y, int rw, int rh, int gy, int gh, uint32_t top, uint32_t bottom) {
    for (int i = 0; i < rh; i++) {
        const int t = std::clamp(y + i - gy, 0, gh - 1);
        rect(x, y + i, rw, 1, mix(top, bottom, gh > 1 ? t * 255 / (gh - 1) : 0));
    }
}

void Canvas::line(int x0, int y0, int x1, int y1, uint32_t c, int t) {
    const int dx = std::abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
    const int dy = -std::abs(y1 - y0), sy = y0 < y1 ? 1 : -1;
    int err = dx + dy;
    const int o = t / 2;
    for (;;) {
        if (t <= 1) {
            if (x0 >= 0 && x0 < w && y0 >= 0 && y0 < h) row(y0)[x0] = c;
        } else {
            rect(x0 - o, y0 - o, t, t, c);
        }
        if (x0 == x1 && y0 == y1) break;
        const int e2 = 2 * err;
        if (e2 >= dy) { err += dy; x0 += sx; }
        if (e2 <= dx) { err += dx; y0 += sy; }
    }
}

void Canvas::disc(int cx, int cy, int r, uint32_t c) {
    for (int dy = -r; dy <= r; dy++) {
        const int yy = cy + dy;
        if (yy < 0 || yy >= h) continue;
        int dx = 0;
        while ((dx + 1) * (dx + 1) + dy * dy <= r * r) dx++;
        const int a = std::max(cx - dx, 0), b = std::min(cx + dx + 1, w);
        if (a < b) std::fill(row(yy) + a, row(yy) + b, c);
    }
}

void Canvas::blit_seg(const uint8_t *gray, const uint8_t *mask, int sw, int sh, int dx, int dy, int dw,
                      int dh, unsigned fill_alpha) {
    // Per-class colour tables: interior = gray blended with the class colour,
    // boundary = solid class colour.
    static uint32_t lut[4][256];
    static unsigned lut_alpha = ~0u;
    if (lut_alpha != fill_alpha) {
        for (int v = 0; v < 256; v++) {
            const uint32_t g = rgb(v, v, v);
            lut[0][v] = g;
            for (int k = 1; k < 4; k++) lut[k][v] = mix(g, CLASS_COLOR[k], fill_alpha);
        }
        lut_alpha = fill_alpha;
    }
    static std::vector<uint8_t> edge;
    if (mask) {
        edge.assign(size_t(sw) * sh, 0);
        for (int y = 0; y < sh; y++)
            for (int x = 0; x < sw; x++) {
                const uint8_t m = mask[y * sw + x];
                if (!m) continue;
                const bool e = x == 0 || y == 0 || x == sw - 1 || y == sh - 1 || mask[y * sw + x - 1] != m ||
                               mask[y * sw + x + 1] != m || mask[(y - 1) * sw + x] != m ||
                               mask[(y + 1) * sw + x] != m;
                edge[y * sw + x] = e;
            }
    }
    static std::vector<int> xmap;
    xmap.resize(dw);
    for (int x = 0; x < dw; x++) xmap[x] = x * sw / dw;
    const Clip k = clip(*this, dx, dy, dw, dh);
    for (int yy = k.y0; yy < k.y1; yy++) {
        const int sy = (yy - dy) * sh / dh;
        const uint8_t *g = gray + sy * sw;
        const uint8_t *m = mask ? mask + sy * sw : nullptr;
        const uint8_t *e = mask ? edge.data() + sy * sw : nullptr;
        uint32_t *p = row(yy);
        for (int xx = k.x0; xx < k.x1; xx++) {
            const int sx = xmap[xx - dx];
            const uint8_t cls = m ? (m[sx] & 3) : 0;
            p[xx] = (cls && e[sx]) ? CLASS_COLOR[cls] : lut[cls][g[sx]];
        }
    }
}

void Canvas::blit_gray(const uint8_t *gray, int sw, int sh, int dx, int dy, int dw, int dh, uint32_t tint) {
    const Clip k = clip(*this, dx, dy, dw, dh);
    for (int yy = k.y0; yy < k.y1; yy++) {
        const uint8_t *g = gray + ((yy - dy) * sh / dh) * sw;
        uint32_t *p = row(yy);
        for (int xx = k.x0; xx < k.x1; xx++) p[xx] = mix(0, tint, g[(xx - dx) * sw / dw]);
    }
}

// ---- Font --------------------------------------------------------------------
struct Font::Impl {
    FT_Library lib = nullptr;
    FT_Face face = nullptr;
    int cur_size = 0;
};

Font::Font(const std::string &path, int face_index) : impl_(new Impl) {
    if (FT_Init_FreeType(&impl_->lib)) throw hw::Error("FreeType init failed");
    if (FT_New_Face(impl_->lib, path.c_str(), face_index, &impl_->face))
        throw hw::Error("cannot open font " + path);
}

Font::~Font() {
    if (impl_->face) FT_Done_Face(impl_->face);
    if (impl_->lib) FT_Done_FreeType(impl_->lib);
}

const Font::Glyph &Font::glyph(uint32_t cp, int size) {
    const uint64_t key = (uint64_t(size) << 32) | cp;
    auto it = cache_.find(key);
    if (it != cache_.end()) return it->second;
    if (impl_->cur_size != size) {
        FT_Set_Pixel_Sizes(impl_->face, 0, size);
        impl_->cur_size = size;
    }
    Glyph g{0, 0, 0, 0, size / 2, {}};
    if (!FT_Load_Char(impl_->face, cp, FT_LOAD_RENDER | FT_LOAD_TARGET_LIGHT)) {
        const FT_GlyphSlot s = impl_->face->glyph;
        g.w = s->bitmap.width;
        g.h = s->bitmap.rows;
        g.left = s->bitmap_left;
        g.top = s->bitmap_top;
        g.advance = int((s->advance.x + 32) >> 6);
        g.a.resize(size_t(g.w) * g.h);
        for (int y = 0; y < g.h; y++)
            std::memcpy(&g.a[size_t(y) * g.w], s->bitmap.buffer + y * s->bitmap.pitch, g.w);
    }
    return cache_.emplace(key, std::move(g)).first->second;
}

namespace {
// Decode one UTF-8 code point; advances i.
uint32_t next_cp(const std::string &s, size_t &i) {
    const uint8_t c = s[i++];
    if (c < 0x80) return c;
    int n = c >= 0xF0 ? 3 : c >= 0xE0 ? 2 : 1;
    uint32_t cp = c & (0x3F >> n);
    while (n-- && i < s.size()) cp = (cp << 6) | (uint8_t(s[i++]) & 0x3F);
    return cp;
}
}  // namespace

int Font::measure(const std::string &s, int size) {
    int w = 0;
    for (size_t i = 0; i < s.size();) w += glyph(next_cp(s, i), size).advance;
    return w;
}

int Font::draw(Canvas &c, int x, int y, const std::string &s, int size, uint32_t color) {
    const int x_start = x;
    for (size_t i = 0; i < s.size();) {
        const Glyph &g = glyph(next_cp(s, i), size);
        const int gx = x + g.left, gy = y - g.top;
        for (int r = 0; r < g.h; r++) {
            const int yy = gy + r;
            if (yy < 0 || yy >= c.h) continue;
            uint32_t *p = c.row(yy);
            const uint8_t *a = &g.a[size_t(r) * g.w];
            for (int q = 0; q < g.w; q++) {
                const int xx = gx + q;
                if (a[q] && xx >= 0 && xx < c.w) p[xx] = a[q] == 255 ? color : mix(p[xx], color, a[q]);
            }
        }
        x += g.advance;
    }
    return x - x_start;
}

// ---- Display -----------------------------------------------------------------
namespace {
constexpr uint32_t OPAQUE = 0xFF000000u;
}  // namespace

// Arrow: 'X' black outline, '.' white fill; hot spot at the tip.
Display::Display() : vdma_(hw::VDMA_BASE, 0x100) {
    for (auto &f : fb_) f.reset(new hw::DmaBuf(size_t(W) * H * 4));
    static const char *ARROW[] = {
        "X",           "XX",          "X.X",         "X..X",        "X...X",        "X....X",
        "X.....X",     "X......X",    "X.......X",   "X........X",  "X.........X",  "X......XXXXX",
        "X...X..X",    "X..XX..X",    "X.X  X..X",   "XX   X..X",   "X     X..X",   "      X..X",
        "       XX",
    };
    arrow_ = {0, 0, 12, int(sizeof ARROW / sizeof *ARROW), {}};
    arrow_.px.assign(size_t(arrow_.w) * arrow_.h, 0);
    for (int r = 0; r < arrow_.h; r++)
        for (int k = 0; ARROW[r][k]; k++)
            if (ARROW[r][k] != ' ') arrow_.px[r * arrow_.w + k] = OPAQUE | (ARROW[r][k] == '.' ? 0xFFFFFF : 0);
    // Crosshair: 1 px white arms with a black outline and a gap at the centre.
    crosshair_ = {10, 10, 21, 21, std::vector<uint32_t>(21 * 21, 0)};
    for (int d = -10; d <= 10; d++) {
        if (std::abs(d) < 3) continue;
        for (int o = -1; o <= 1; o++) {
            const uint32_t col = OPAQUE | (o ? 0 : 0xFFFFFF);
            auto set = [&](int x, int y) {
                uint32_t &p = crosshair_.px[(y + 10) * 21 + x + 10];
                if (!(p & 0xFFFFFF)) p = col;  // white wins where arms cross outlines
            };
            set(d, o);
            set(o, d);
        }
    }
}

void Display::flush_rows(int buf, int y0, int y1) {
    y0 = std::max(y0, 0), y1 = std::min(y1, H);
    if (y0 < y1) fb_[buf]->flush(size_t(y0) * W * 4, size_t(y1 - y0) * W * 4);
}

// Put back the pixels under buffer b's cursor imprint; returns its row span.
std::pair<int, int> Display::restore(int b) {
    Imprint &im = imp_[b];
    if (!im.on) return {0, 0};
    const Sprite &s = *im.sprite;
    uint32_t *fb = reinterpret_cast<uint32_t *>(fb_[b]->data());
    for (int r = 0; r < s.h; r++)
        for (int k = 0; k < s.w; k++) {
            const int x = im.x + k, y = im.y + r;
            if (s.px[r * s.w + k] && x >= 0 && x < W && y >= 0 && y < H) fb[y * W + x] = im.under[r * s.w + k];
        }
    im.on = false;
    return {im.y, im.y + s.h};
}

// Stamp the cursor into buffer b; returns its row span.
std::pair<int, int> Display::stamp(int b) {
    if (!cur_on_) return {0, 0};
    Imprint &im = imp_[b];
    const Sprite &s = cross_ ? crosshair_ : arrow_;
    im.sprite = &s;
    im.x = cx_ - s.hx, im.y = cy_ - s.hy;
    im.under.resize(s.px.size());
    uint32_t *fb = reinterpret_cast<uint32_t *>(fb_[b]->data());
    for (int r = 0; r < s.h; r++)
        for (int k = 0; k < s.w; k++) {
            const int x = im.x + k, y = im.y + r;
            const uint32_t p = s.px[r * s.w + k];
            if (!p || x < 0 || x >= W || y < 0 || y >= H) continue;
            im.under[r * s.w + k] = fb[y * W + x];
            fb[y * W + x] = p & 0xFFFFFF;
        }
    im.on = true;
    return {im.y, im.y + s.h};
}

void Display::cursor_move(int x, int y) {
    std::lock_guard<std::mutex> l(cm_);
    bool cross = false;
    for (const Rect &r : cross_areas_) cross |= r.contains(x, y);
    if (cur_on_ && x == cx_ && y == cy_ && cross == cross_) return;
    const auto a = restore(front_);
    cur_on_ = true, cx_ = x, cy_ = y, cross_ = cross;
    const auto b = stamp(front_);
    // Small flushes (a few rows each), never the 3.6 MB frame.
    if (a.second <= b.first || b.second <= a.first) {
        flush_rows(front_, a.first, a.second);
        flush_rows(front_, b.first, b.second);
    } else {
        flush_rows(front_, std::min(a.first, b.first), std::max(a.second, b.second));
    }
}

void Display::cursor_hide() {
    std::lock_guard<std::mutex> l(cm_);
    if (!cur_on_) return;
    const auto a = restore(front_);
    cur_on_ = false;
    flush_rows(front_, a.first, a.second);
}

void Display::cursor_crosshair(const std::vector<Rect> &areas) {
    std::lock_guard<std::mutex> l(cm_);
    cross_areas_ = areas;
}

void Display::start() {
    for (auto &f : fb_) {
        uint32_t *p = reinterpret_cast<uint32_t *>(f->data());
        std::fill_n(p, W * H, rgb(10, 14, 22));
        f->flush();
    }
    vdma_.wr(0x00, 0x4);  // MM2S reset
    for (int i = 0; i < 1000 && (vdma_.rd(0x00) & 0x4); i++) hw::sleep_us(10);
    vdma_.wr(0x00, 0x1);  // run, park mode
    for (int i = 0; i < 3; i++) vdma_.wr(0x5C + 4 * i, fb_[i]->phys());
    vdma_.wr(0x28, 0);        // park on frame store 0
    vdma_.wr(0x58, W * 4);    // stride, frame delay 0
    vdma_.wr(0x54, W * 4);    // hsize bytes
    vdma_.wr(0x50, H);        // vsize: starts the channel
    back_ = 1, front_ = 0;
}

// The back buffer was the front two presents ago and may still carry that
// cursor imprint: remove it first, so partial redraws start from clean pixels.
Canvas Display::back() {
    std::lock_guard<std::mutex> l(cm_);
    const auto r = restore(back_);
    if (r.first < r.second) dirty_[back_] = {std::min(dirty_[back_].first, r.first), std::max(dirty_[back_].second, r.second)};
    return Canvas{reinterpret_cast<uint32_t *>(fb_[back_]->data()), W, H, W};
}

void Display::present(int y0, int y1) {
    if (y0 <= 0 && y1 >= H) present(std::vector<std::pair<int, int>>{});
    else present(std::vector<std::pair<int, int>>{{y0, y1}});
}

// spans empty = whole frame.
void Display::present(std::vector<std::pair<int, int>> spans) {
    std::lock_guard<std::mutex> l(cm_);
    const int b = back_;
    front_ = b;
    const auto c = stamp(b);  // cursor onto the new frame before the flush
    if (spans.empty()) {
        fb_[b]->flush();
    } else {
        // Plus the cursor and any restored imprint outside the redraw; merge
        // overlapping spans so no row is cleaned twice.
        spans.push_back(c);
        spans.push_back(dirty_[b]);
        std::sort(spans.begin(), spans.end());
        int s0 = H, s1 = 0;
        for (const auto &s : spans) {
            if (s.first >= s.second) continue;
            if (s0 < s1 && s.first <= s1) {
                s1 = std::max(s1, s.second);
                continue;
            }
            if (s0 < s1) flush_rows(b, s0, s1);
            s0 = s.first, s1 = s.second;
        }
        if (s0 < s1) flush_rows(b, s0, s1);
    }
    dirty_[b] = {H, 0};
    vdma_.wr(0x28, uint32_t(b));  // MM2S park pointer; takes effect at the next frame
    back_ = (b + 1) % 3;
}

}  // namespace gfx
