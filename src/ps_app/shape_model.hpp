// PS-side shape reconstruction for the E-PiVox K16 predictor. The PL returns
// 16 INT8 codes; the model is an SDF-PCA over a 64^3 grid (mm, x,y,z order):
//   sdf = base + sum_k code_k * basis_k      (folded offline, see
//   tools/export_shape_model.py; inside = sdf <= 0)
// followed by a surface-nets mesh of the zero level set for display.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace app {

struct Mesh {
    std::vector<float> verts;      // xyz, mm
    std::vector<uint32_t> faces;   // triangle indices
    std::vector<uint32_t> colors;  // per vertex 0xRRGGBB
};

class ShapeModel {
public:
    bool load(const std::string &path, std::string *error);
    int res() const { return res_; }
    int components() const { return k_; }
    // Normalised coefficients as the network predicts them (code * output_scale).
    void coefficients(const int8_t codes[16], float out[16]) const;
    // SDF of one case; returns the inside voxel count and fills the inside map
    // (1 byte per voxel). Streams an int16 copy of the basis (the A9 reads DDR at
    // ~450 MB/s, so bytes are time); voxels whose value lies within the int16
    // error bound of zero are recomputed from the float basis, so inside/outside
    // is decided exactly as with float arithmetic.
    uint32_t reconstruct(const int8_t codes[16], std::vector<float> &sdf, std::vector<uint8_t> &inside) const;
    double voxel_ml() const { return spacing_[0] * spacing_[1] * spacing_[2] / 1000.0; }
    // Zero level-set mesh. Vertices are coloured by their signed distance to the
    // mean shape (blue: inside the mean envelope, red: outside).
    void extract(const std::vector<float> &sdf, const std::vector<uint8_t> &inside, Mesh &mesh) const;
    // Mean shape (all codes zero).
    void mean_mesh(Mesh &mesh) const;
    mutable bool profile = false;  // print per-phase times
    mutable uint32_t last_fixups = 0;

    // ---- systolic motion (data/shape_motion.bin, tools: beat_motion/export_motion.py)
    // A generic physiological motion model: ED -> ES SDF change regressed from
    // the K16 coefficients over 1000 synthetically contracted Rodero meshes,
    //   dS = mbase + sum_k code_k * mbasis_k,   sdf(w) = sdf_ED + w * dS.
    bool load_motion(const std::string &path, std::string *error);
    bool has_motion() const { return !mq_.empty(); }
    void motion(const int8_t codes[16], std::vector<float> &ds) const;
    // sdf_ED + w * ds; returns the inside voxel count.
    uint32_t blend(const std::vector<float> &sdf, const std::vector<float> &ds, float w, std::vector<float> &out,
                   std::vector<uint8_t> &inside) const;

private:
    int res_ = 0, k_ = 0;
    float origin_[3] = {}, spacing_[3] = {}, out_scale_ = 0;
    std::vector<float> base_, basis_;   // float basis kept for the exact fix-up
    std::vector<int16_t> q_;            // basis_k / qscale_k, rounded
    float qscale_[16] = {};
    std::vector<int16_t> mq_;           // [mbase, mbasis_0..K-1], int16
    float mscale_[17] = {};
};

}  // namespace app
