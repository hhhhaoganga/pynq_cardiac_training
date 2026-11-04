// 720p XRGB8888 output (static-shell VDMA, triple buffered, park mode),
// a small software canvas and FreeType text.
#pragma once

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "hw.hpp"

namespace gfx {

constexpr int W = 1280, H = 720;

inline constexpr uint32_t rgb(unsigned r, unsigned g, unsigned b) { return (r << 16) | (g << 8) | b; }
uint32_t mix(uint32_t a, uint32_t b, unsigned t255);  // a*(1-t) + b*t

struct Canvas {
    uint32_t *px = nullptr;
    int w = 0, h = 0, stride = 0;  // stride in pixels

    uint32_t *row(int y) const { return px + size_t(y) * stride; }
    void fill(uint32_t c);
    void rect(int x, int y, int w, int h, uint32_t c);
    void blend_rect(int x, int y, int w, int h, uint32_t c, unsigned alpha);
    void dim(int x, int y, int w, int h);  // fast 3/8 darkening (shifts only)
    void round_rect(int x, int y, int w, int h, int r, uint32_t c, unsigned alpha = 255);
    void frame(int x, int y, int w, int h, uint32_t c, int t = 1);
    void vgradient(int x, int y, int w, int h, uint32_t top, uint32_t bottom);
    // The part (x, y, w, h) of a vertical gradient spanning rows [gy, gy + gh).
    void vgradient_part(int x, int y, int w, int h, int gy, int gh, uint32_t top, uint32_t bottom);
    void line(int x0, int y0, int x1, int y1, uint32_t c, int t = 1);
    void disc(int cx, int cy, int r, uint32_t c);
    // 256x256 gray image scaled to dst with the class mask blended on top
    // (mask may be null). Class colours: 1 LV, 2 MYO, 3 LA.
    void blit_seg(const uint8_t *gray, const uint8_t *mask, int sw, int sh, int dx, int dy, int dw,
                  int dh, unsigned fill_alpha = 110);
    void blit_gray(const uint8_t *gray, int sw, int sh, int dx, int dy, int dw, int dh, uint32_t tint);
};

extern const uint32_t CLASS_COLOR[4];

class Font {
public:
    Font(const std::string &path, int face_index);
    ~Font();
    // Draw UTF-8 text with its baseline at y; returns the advance in pixels.
    int draw(Canvas &c, int x, int y, const std::string &utf8, int size, uint32_t color);
    int measure(const std::string &utf8, int size);
    // Horizontally centre / right-align around x.
    int draw_center(Canvas &c, int cx, int y, const std::string &s, int size, uint32_t color) {
        return draw(c, cx - measure(s, size) / 2, y, s, size, color);
    }
    int draw_right(Canvas &c, int rx, int y, const std::string &s, int size, uint32_t color) {
        return draw(c, rx - measure(s, size), y, s, size, color);
    }

private:
    struct Glyph {
        int w, h, left, top, advance;
        std::vector<uint8_t> a;
    };
    const Glyph &glyph(uint32_t cp, int size);
    struct Impl;
    std::unique_ptr<Impl> impl_;
    std::unordered_map<uint64_t, Glyph> cache_;
};

struct Rect {
    int x = 0, y = 0, w = 0, h = 0;
    bool contains(int px, int py) const { return px >= x && px < x + w && py >= y && py < y + h; }
    bool operator==(const Rect &o) const { return x == o.x && y == o.y && w == o.w && h == o.h; }
};

// Triple-buffered scan-out through the static VDMA (MM2S, park mode).
// The mouse cursor is a software overlay stamped into the buffer being
// scanned out (with save-under), so it follows the mouse at event rate no
// matter how long a UI frame takes; present() moves it to the new frame.
class Display {
public:
    Display();
    void start();          // reset VDMA and scan out buffer 0
    Canvas back();         // buffer to draw the next frame into
    // Flush rows [y0, y1) of the back buffer (whole frame by default) and park
    // the VDMA on it.
    void present(int y0 = 0, int y1 = H);
    // Partial frame: only these row spans [first, second) were redrawn.
    void present(std::vector<std::pair<int, int>> spans);
    int back_index() const { return back_; }
    uint32_t vdma_status() const { return vdma_.rd(0x04); }

    // Thread safe (mouse thread / UI thread).
    void cursor_move(int x, int y);           // also shows the cursor
    void cursor_hide();
    void cursor_crosshair(const std::vector<Rect> &areas);  // crosshair inside these

private:
    struct Sprite {
        int hx, hy, w, h;                     // hot spot, size
        std::vector<uint32_t> px;             // 0 = transparent, else 0xFF000000 | rgb
    };
    struct Imprint {                          // cursor pixels stamped into one buffer
        bool on = false;
        int x = 0, y = 0;
        const Sprite *sprite = nullptr;
        std::vector<uint32_t> under;          // what the cursor covers
    };
    // Caller holds cm_. Both return the touched row span [first, second).
    std::pair<int, int> stamp(int buf);
    std::pair<int, int> restore(int buf);
    void flush_rows(int buf, int y0, int y1);

    hw::Mmio vdma_;
    std::unique_ptr<hw::DmaBuf> fb_[3];
    int back_ = 1, front_ = 0;
    std::mutex cm_;
    bool cur_on_ = false, cross_ = false;
    int cx_ = W / 2, cy_ = H / 2;
    std::vector<Rect> cross_areas_;
    Sprite arrow_, crosshair_;
    Imprint imp_[3];
    std::pair<int, int> dirty_[3] = {{H, 0}, {H, 0}, {H, 0}};  // restored rows not yet flushed
};

}  // namespace gfx
