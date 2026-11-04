// Small software rasteriser for the reconstructed heart mesh: z-buffered
// flat-shaded triangles, per-part colours, orthographic view. Vertex work and
// the raster are split over both Cortex-A9 cores (upper / lower half).
#pragma once

#include <condition_variable>
#include <cstdint>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

#include "gfx.hpp"

namespace app {

class MeshRenderer {
public:
    MeshRenderer();
    ~MeshRenderer();
    MeshRenderer(const MeshRenderer &) = delete;
    MeshRenderer &operator=(const MeshRenderer &) = delete;
    // New mesh (per-vertex colours; a non-zero top byte is the face opacity,
    // taken from its first vertex). refit re-centres and re-scales the view;
    // keep it false between cases so size differences stay visible.
    void set_mesh(const std::vector<float> &verts, const std::vector<uint32_t> &faces,
                  const std::vector<uint32_t> &colors, bool refit);
    // Draw into canvas region (x, y, w, h); R maps model to view space
    // (x right, y up, z towards the viewer).
    // zoom scales the fitted size (ECG beat pulse); 1 = fit.
    void draw(gfx::Canvas &c, int x, int y, int w, int h, const float R[3][3], uint32_t bg, float zoom = 1.f);
    void draw(gfx::Canvas &c, int x, int y, int w, int h, float yaw, float pitch, uint32_t bg);
    bool ready() const { return !pos_.empty() && !faces_.empty(); }
    bool profile_ = false;       // print per-phase draw times
    double last_vert_ms = 0, last_raster_ms = 0;
    float winding_consistency() const { return consistency_; }
    int culling() const { return cull_; }

private:
    void transform(size_t i0, size_t i1, const float R[3][3], int w, int h, float scale);
    void raster(gfx::Canvas &c, int ox, int oy, int w, int band_y0, int band_y1, int x_lo, int x_hi,
                uint32_t bg);
    // Run fn on the helper core while the caller does its own half; join().
    void fork(std::function<void()> fn);
    void join();

    std::vector<uint32_t> faces_, rgb_;
    std::vector<float> pos_, nrm_;
    float centre_[3] = {0, 0, 0}, radius_ = 1;  // view fit (mean shape)
    float depth_r_ = 1;                          // depth range: this mesh's extent around centre_
    bool translucent_ = false;   // some colours carry an opacity byte
    int cull_ = 0;               // 0 none, -1/+1: keep faces of that screen-area sign
    float consistency_ = 0;
    std::vector<int32_t> vx_, vy_, vz_, vc_;
    std::vector<uint16_t> zbuf_;

    std::thread helper_;
    std::mutex m_;
    std::condition_variable cv_;
    std::function<void()> job_;
    bool busy_ = false, quit_ = false;
};

}  // namespace app
