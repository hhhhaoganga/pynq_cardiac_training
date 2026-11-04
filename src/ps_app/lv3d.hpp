// Biplane geometric left-ventricle reconstruction on the PS, from the
// segmentation masks the PL produces frame by frame. Same method as the
// manual biplane EF measurement in biplane.hpp (method of disks), but the
// landmarks are found automatically so every frame can be measured:
//
//   base = midpoint of the LV / LA interface (mitral annulus),
//   apex = LV pixel farthest from the base,
//   LV_LEVELS disks perpendicular to apex -> base; each disk gives a half
//   width and the lateral offset of its centre (LvRing).
//
// Pairing the rings of the A2C and A4C views of the same phase gives one
// ellipse per disk (A2C width = x axis, A4C width = y axis) and
//   V = pi * sum(a_i * b_i) * L / LV_LEVELS.
// Stacking the ellipses is the display mesh (lv_mesh).
//
// Everything here is plain PS arithmetic: the PL stays on rm_seg, so the
// 3D model can beat while segmentation keeps streaming.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

#include "app.hpp"
#include "biplane.hpp"      // Pt
#include "shape_model.hpp"  // Mesh

namespace app {

// Automatic landmarks on one 256x256 mask (class 1 = LV, 3 = LA).
// Returns false when there is no usable LV region.
bool lv_landmarks(const uint8_t *mask, int w, int h, double sx, double sy, Pt &apex, Pt &base);

// Disk profile of one frame. false when the mask has no measurable LV.
bool lv_measure(const uint8_t *mask, int w, int h, double sx, double sy, LvRing &out);

// Volume (mL) of the paired rings, using a common disk height.
double lv_volume_ml(const LvRing &a, const LvRing &b, double length_mm);

// Display mesh of one phase: stacked ellipses from the apex (z = 0) to the
// base (z = length), plus the apex cap. `scale_epi` > 1 adds a translucent
// outer shell colour; pass 1 for the cavity itself.
void lv_mesh(const LvRing &a, const LvRing &b, double length_mm, int segments, uint32_t color, Mesh &out);

// Display mesh of one phase: the red cavity plus the back half of the
// myocardium (epicardium from LV + MYO) as a cut-away, so the wall thickness
// is visible and the cavity is not hidden: the board's rasteriser is opaque
// (no alpha), so a translucent shell like the PC rendering is not possible.
// Long axis = model y, apex at the bottom.
// The cavity is heat coloured per level by its area loss against `ra`/`rb`
// (the ED rings): red = diastolic (as at ED), blue = contracted.
void lv_mesh_heart(const LvRing &a, const LvRing &b, const LvRing &ra, const LvRing &rb, double length_mm,
                   Mesh &out);

// Temporal smoothing over one cycle: a [0.25 0.5 0.25] kernel on half/off/length,
// so single-frame segmentation jitter does not make the model flicker.
void lv_smooth(std::vector<LvRing> &rings);

}  // namespace app
