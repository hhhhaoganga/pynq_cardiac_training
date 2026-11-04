// echo_demo: PYNQ-Z2 board runtime for the DFX echocardiography demo.
//   - loads the full image (static shell + segmentation) and starts 720p HDMI
//   - TCP 5001: CMS1 frames -> segmentation results (host/camus_stream_host.py),
//     plus shape cases and explicit mode requests
//   - swaps the reconfigurable slot between segmentation and shape on demand
//   - plays a built-in demo loop while no host is connected
//   - turns the 3D view with a JY62 attitude sensor on Pmod JB (PS UART1)
//   - shows a USB (UVC) camera live on its own page
//   - reads an AD8232 ECG (Arduino on USB serial): heart rate, trace, beat-gated 3D playback
// Usage: echo_demo [--root DIR] [--no-demo] [--demo-idle S] [--no-imu] [--no-camera] [--no-ecg]
//                  [--camera-size WxH]
#include <atomic>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <pthread.h>
#include <thread>
#include <unistd.h>
#include <vector>

#include "app.hpp"
#include "demo.hpp"
#include "ecg.hpp"
#include "gfx.hpp"
#include "imu.hpp"
#include "net.hpp"
#include "render3d.hpp"
#include "shape_model.hpp"
#include "ui.hpp"
#include "worker.hpp"

namespace {
std::atomic<bool> g_stop{false};
void on_signal(int) { g_stop = true; }

// Reconstruct the reference fixture cases from their expected codes and
// compare the inside-voxel count with tools/export_shape_model.py (float32
// summation order may move a voxel or two on the zero level set).
std::string check_shape_model(const app::ShapeModel &model, const std::string &data) {
    std::ifstream ref(data + "/shape_reference.txt");
    std::ifstream exp(data + "/shape_fixtures/expected.bin", std::ios::binary);
    std::vector<char> codes((std::istreambuf_iterator<char>(exp)), std::istreambuf_iterator<char>());
    if (!ref || codes.empty()) return "形状重建自检：缺少参考数据";
    int cases = 0, worst = 0;
    std::vector<float> sdf;
    std::vector<uint8_t> inside;
    const uint64_t t0 = hw::now_us();
    for (std::string line; std::getline(ref, line);) {
        std::istringstream ss(line);
        size_t idx;
        std::string id;
        long expect;
        if (!(ss >> idx >> id >> expect) || (idx + 1) * 16 > codes.size()) continue;
        const long got = long(model.reconstruct(reinterpret_cast<const int8_t *>(&codes[idx * 16]), sdf, inside));
        worst = std::max(worst, int(std::labs(got - expect)));
        cases++;
    }
    const double ms = (hw::now_us() - t0) / 1000.0 / std::max(cases, 1);
    char msg[128];
    std::snprintf(msg, sizeof msg, "形状重建自检 %d 例：体素最大偏差 %d (%s)，%.1f ms/例", cases, worst,
                  worst <= 8 ? "通过" : "失败", ms);
    return msg;
}

// --bench-shape: time the PS stages on fixture codes (no PL access).
int bench_shape(const app::ShapeModel &model, const std::string &data) {
    std::ifstream exp(data + "/shape_fixtures/expected.bin", std::ios::binary);
    std::vector<char> codes((std::istreambuf_iterator<char>(exp)), std::istreambuf_iterator<char>());
    std::vector<float> sdf;
    std::vector<uint8_t> inside;
    app::Mesh mesh;
    app::MeshRenderer r;
    std::vector<uint32_t> px(size_t(688) * 580);
    gfx::Canvas c{px.data(), 688, 580, 688};
    double t_rec = 0, t_ext = 0, t_draw = 0;
    const int n = std::min<int>(10, int(codes.size() / 16));
    for (int i = 0; i < n; i++) {
        uint64_t t = hw::now_us();
        model.reconstruct(reinterpret_cast<const int8_t *>(&codes[i * 16]), sdf, inside);
        t_rec += (hw::now_us() - t) / 1000.0, t = hw::now_us();
        model.extract(sdf, inside, mesh);
        t_ext += (hw::now_us() - t) / 1000.0, t = hw::now_us();
        r.set_mesh(mesh.verts, mesh.faces, mesh.colors, i == 0);
        r.draw(c, 0, 0, 688, 580, 0.6f + i * 0.3f, -0.35f, 0);
        t_draw += (hw::now_us() - t) / 1000.0;
    }
    std::printf("bench: reconstruct %.2f ms, extract %.2f ms, set_mesh+draw %.2f ms (%zu tris, winding %.3f, cull %d)\n",
                t_rec / n, t_ext / n, t_draw / n, mesh.faces.size() / 3, r.winding_consistency(), r.culling());
    uint64_t t = hw::now_us();
    for (int i = 0; i < 10; i++) r.draw(c, 0, 0, 688, 580, 0.6f + i * 0.3f, -0.35f, 0);
    std::printf("bench: draw only %.2f ms\n", (hw::now_us() - t) / 10000.0);
    r.profile_ = true;
    r.draw(c, 0, 0, 688, 580, 0.6f, -0.35f, 0);
    t = hw::now_us();
    model.profile = true;
    for (int i = 0; i < 3; i++) model.extract(sdf, inside, mesh);
    std::printf("bench: last reconstruct fix-ups %u voxels\n", model.last_fixups);
    model.profile = false;
    if (model.has_motion()) {
        // motion_reference.txt: idx id es_inside ed_inside (export_motion.py, float32).
        std::ifstream ref(data + "/motion_reference.txt");
        std::vector<float> ds, sw;
        double t_mot = 0, t_ph = 0;
        int cases = 0, worst = 0;
        for (std::string line; std::getline(ref, line);) {
            std::istringstream ss(line);
            size_t idx;
            std::string id;
            long es, ed;
            if (!(ss >> idx >> id >> es >> ed) || (idx + 1) * 16 > codes.size()) continue;
            const int8_t *cd = reinterpret_cast<const int8_t *>(&codes[idx * 16]);
            model.reconstruct(cd, sdf, inside);
            uint64_t t1 = hw::now_us();
            model.motion(cd, ds);
            t_mot += (hw::now_us() - t1) / 1000.0, t1 = hw::now_us();
            const long got = long(model.blend(sdf, ds, 1.f, sw, inside));
            model.extract(sw, inside, mesh);
            t_ph += (hw::now_us() - t1) / 1000.0;
            worst = std::max(worst, int(std::labs(got - es)));
            cases++;
        }
        std::printf("bench: motion self-check %d cases, ES inside max diff %d (%s); motion field %.2f ms, "
                    "blend+extract %.2f ms per phase\n",
                    cases, worst, cases && worst <= 64 ? "PASS" : "FAIL", t_mot / std::max(cases, 1),
                    t_ph / std::max(cases, 1));
    }
    return 0;
}

std::string exe_dir() {
    char buf[512];
    const ssize_t n = ::readlink("/proc/self/exe", buf, sizeof buf - 1);
    if (n <= 0) return ".";
    buf[n] = 0;
    std::string p(buf);
    return p.substr(0, p.find_last_of('/'));
}
}  // namespace

int main(int argc, char **argv) {
    std::setvbuf(stdout, nullptr, _IOLBF, 0);
    app::Config cfg;
    cfg.root = exe_dir();
    bool bench = false;
    for (int i = 1; i < argc; i++) {
        const std::string a = argv[i];
        if (a == "--bench-shape") bench = true;
        else if (a == "--root" && i + 1 < argc) cfg.root = argv[++i];
        else if (a == "--no-demo") cfg.demo = false;
        else if (a == "--no-imu") cfg.imu = false;
        else if (a == "--no-camera") cfg.camera = false;
        else if (a == "--no-ecg") cfg.ecg = false;
        else if (a == "--knot-pl") { cfg.knot_pl = true; cfg.demo = false; }
        else if (a == "--hand-pl") { cfg.hand_pl = true; cfg.knot_pl = true; cfg.demo = false; }
        else if (a == "--camera-size" && i + 1 < argc &&
                 std::sscanf(argv[i + 1], "%dx%d", &cfg.cam_w, &cfg.cam_h) == 2) i++;
        else if (a == "--demo-idle" && i + 1 < argc) cfg.demo_idle_s = std::atoi(argv[++i]);
        else {
            std::fprintf(stderr,
                         "usage: %s [--root DIR] [--no-demo] [--demo-idle S] [--no-imu] [--no-camera] [--no-ecg]"
                         " [--camera-size WxH]\n",
                         argv[0]);
            return 2;
        }
    }
    if (cfg.firmware_dir.empty()) cfg.firmware_dir = cfg.root + "/firmware";
    std::signal(SIGPIPE, SIG_IGN);
    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);

    try {
        app::ShapeModel model;
        std::string err;
        const bool have_model = model.load(cfg.root + "/data/shape_model.bin", &err);
        if (have_model) {
            std::string merr;
            if (model.load_motion(cfg.root + "/data/shape_motion.bin", &merr))
                std::printf("main: systolic motion model loaded\n");
            else
                std::printf("main: no motion model (%s); E-PiVox mesh stays static\n", merr.c_str());
        }
        if (bench) {
            if (!have_model) return 1;
            std::printf("%s\n", check_shape_model(model, cfg.root + "/data").c_str());
            return bench_shape(model, cfg.root + "/data");
        }
        app::UiState ui;
        if (!have_model) {
            std::printf("main: no shape model (%s); showing PCA codes only\n", err.c_str());
        } else {
            const std::string check = check_shape_model(model, cfg.root + "/data");
            std::printf("main: shape model %d^3 SDF, K=%d; %s\n", model.res(), model.components(), check.c_str());
            ui.log(app::clock_text() + "  " + check);
        }
        app::Queue<app::Job> jobs(4);
        app::Net net(jobs, ui);
        gfx::Display display;
        app::Worker worker(cfg, jobs, ui, net, have_model ? &model : nullptr);
        worker.boot();        // full bitstream: static shell + rm_seg
        display.start();      // VDMA lives in the static shell
        app::Mouse mouse(gfx::W, gfx::H);
        mouse.on_move = [&display](int x, int y) { display.cursor_move(x, y); };
        // JY62 is optional: without it (or with --no-imu) the view auto-rotates as before.
        std::unique_ptr<app::Imu> imu;
        if (cfg.imu) {
            try {
                imu = std::make_unique<app::Imu>();
                std::printf("main: JY62 on %s\n", imu->backend().c_str());
            } catch (const std::exception &e) {
                std::printf("main: no JY62 (%s)\n", e.what());
            }
        }
        // The camera thread waits for a device itself, so a missing camera costs nothing.
        std::unique_ptr<app::Camera> cam;
        if (cfg.camera) cam = std::make_unique<app::Camera>(cfg.cam_w, cfg.cam_h);
        // Knot / hand detection for the camera page (integer programs in data/nn).
        std::unique_ptr<app::Detector> det;
        if (cam) det = std::make_unique<app::Detector>(cfg.root + "/data/nn", cam.get(), cfg.knot_pl ? &jobs : nullptr,cfg.hand_pl);
        std::unique_ptr<app::Ecg> ecg;
        if (cfg.ecg) {
            // The recording can be switched in from the UI; ECHO_ECG_REPLAY also makes it the start-up source.
            const char *rp = std::getenv("ECHO_ECG_REPLAY");
            ecg = std::make_unique<app::Ecg>(rp ? std::string(rp) : cfg.root + "/data/ecg/rec_30s.bin", rp != nullptr);
        }
        app::Ui screen(cfg, ui, display, have_model ? &model : nullptr, jobs, &mouse, imu.get(), cam.get(),
                       det.get(), ecg.get());
        app::Demo demo(cfg, jobs, ui, net);
        net.start();
        // Named threads: `top -H` shows which one is busy.
        auto named = [](const char *name, auto fn) {
            std::thread t([name, fn] {
                pthread_setname_np(pthread_self(), name);
                fn();
            });
            t.detach();
        };
        named("worker", [&worker] { worker.run(); });
        named("ui", [&screen] { screen.run(); });
        named("demo", [&demo] { demo.run(); });
        named("mouse", [&mouse] { mouse.run(); });
        if (imu)
            named("imu", [&imu] {
                try {
                    imu->run();
                } catch (const std::exception &e) {
                    std::printf("imu: stopped (%s)\n", e.what());
                }
            });
        if (det) named("detect", [&det] { det->run(); });
        if (cam)
            named("camera", [&cam] {
                try {
                    cam->run();
                } catch (const std::exception &e) {
                    std::printf("camera: stopped (%s)\n", e.what());
                }
            });
        if (ecg) named("ecg", [&ecg] { ecg->run(); });
        std::printf("main: running (VDMA MM2S_SR=0x%08X)\n", display.vdma_status());
        while (!g_stop) ::pause();
        std::printf("main: stopping\n");
        // The frame buffers are freed on exit; stop scan-out so the VDMA never
        // reads recycled memory (HDMI timing continues from the static VTG).
        hw::Mmio(hw::VDMA_BASE, 0x100).wr(0x00, 0x4);
        std::_Exit(0);
    } catch (const std::exception &e) {
        std::fprintf(stderr, "echo_demo: %s\n", e.what());
        return 1;
    }
}
