from collections import Counter
from dataclasses import dataclass
import math
import numpy as np


@dataclass(frozen=True)
class Config:
    work_area: tuple = (0, 120, 640, 480)
    max_hands: int = 2
    presence: float = 0.5
    detection_margin: float = 1.4
    landmark_margin: float = 1.5
    center_tau_s: float = 0.055
    shrink_tau_s: float = 0.25
    anchor_min_scale: float = 0.70
    min_side: float = 72.0
    max_side: float = 600.0
    retry_s: float = 0.35
    lost_expiry_s: float = 1.5
    local_search_scale: float = 1.6
    confirmation_frames: int = 2

def bbox(points):
    return np.r_[points.min(0), points.max(0)].astype(float)

def iou(a, b):
    d = np.maximum(0, np.minimum(a[2:], b[2:]) - np.maximum(a[:2], b[:2]))
    inter = np.prod(d)
    return float(inter / max(1, np.prod(a[2:] - a[:2]) + np.prod(b[2:] - b[:2]) - inter))

def roi_from_box(box, margin):
    a = np.asarray(box, float)
    return np.r_[(a[:2] + a[2:]) / 2, max(a[2:] - a[:2]) * margin]

def clipped_region(region, work):
    a = np.maximum(region[:2], work[:2])
    b = np.minimum(region[2:], work[2:])
    if min(b - a) < 32:
        return None
    return tuple(np.r_[a, b].round().astype(int).tolist())

class TwoHandTracker:
    def __init__(self, models, cfg=Config()):
        self.models, self.cfg = models, cfg
        self.tracks = []
        self.next_id = 1
        self.last_detect = -1e9
        self.last_time = None
        self.events = []

    def quality(self, obs, previous=None):
        xy = np.asarray(obs["points"])
        roi = np.asarray(obs["roi_used"])
        if not np.isfinite(xy).all() or not math.isfinite(obs["presence"]):
            return "nonfinite"
        if obs["presence"] < self.cfg.presence:
            return "presence"
        extent = np.ptp(xy, axis=0).max() / roi[2]
        if not 0.15 <= extent <= 1.05:
            return "extent"
        inside = np.max(np.abs(xy - roi[:2]), axis=1) <= roi[2] * 0.51
        if inside.sum() < 19:
            return "crop_edge"
        if previous is not None:
            old = np.asarray(previous["points"])
            palm = [0, 5, 9, 13, 17]
            if np.linalg.norm((xy[palm] - old[palm]).mean(0)) > roi[2] * 0.38:
                return "jump"
        return None

    def is_duplicate(self, obs, other):
        a, b = np.asarray(obs["points"]), np.asarray(other["points"])
        palm = [0, 5, 9, 13, 17]
        dist = np.linalg.norm(a[palm].mean(0) - b[palm].mean(0))
        size = min(np.ptp(a, 0).max(), np.ptp(b, 0).max())
        return dist < 0.3 * size or iou(bbox(a), bbox(b)) > 0.65

    def accept(self, track, obs, timestamp, dt, detection=False):
        target = roi_from_box(obs["box"], self.cfg.landmark_margin)
        target[2] = np.clip(target[2], max(self.cfg.min_side, track["anchor"] * self.cfg.anchor_min_scale), self.cfg.max_side)
        old = track["roi"]
        alpha = 1 - math.exp(-dt / self.cfg.center_tau_s)
        center = old[:2] + alpha * (target[:2] - old[:2])
        scale_alpha = 1.0 if target[2] > old[2] else 1 - math.exp(-dt / self.cfg.shrink_tau_s)
        side = old[2] + scale_alpha * (target[2] - old[2])
        # Keep every predicted point inside the next crop, with a 12% border.
        side = max(side, 2.24 * np.max(np.abs(np.asarray(obs["points"]) - center)))
        track.update(roi=np.r_[center, min(self.cfg.max_side, side)], obs=obs,
                     last_good=timestamp, failures=0, streak=track["streak"] + 1,
                     source="detection" if detection else "tracking")

    def step(self, frame, timestamp):
        dt = 1 / 30 if self.last_time is None else timestamp - self.last_time
        self.last_time = timestamp
        failures, searches, events = [], [], []
        accepted = []
        before = self.models.calls.copy()
        for track in sorted(self.tracks, key=lambda t: -t["streak"]):
            if track["failures"]:
                continue
            obs = self.models.landmark(frame, track["roi"])
            reason = self.quality(obs, track["obs"])
            if reason is None and any(self.is_duplicate(obs, x["obs"]) for x in accepted):
                reason = "duplicate"
            if reason is not None:
                track["failures"] += 1
                track["streak"] = 0
                failures.append({"id": track["id"], "reason": reason, "presence": obs["presence"]})
                events.append({"kind": "lost", "id": track["id"], "reason": reason})
                continue
            self.accept(track, obs, timestamp, dt)
            accepted.append(track)

        # Lost tracks retain their last location for nearby recovery. Never output stale points.
        self.tracks = [t for t in self.tracks if timestamp - t["last_good"] <= self.cfg.lost_expiry_s]
        need_search = len(accepted) < self.cfg.max_hands
        if need_search and timestamp - self.last_detect >= self.cfg.retry_s:
            lost = [t for t in self.tracks if t["failures"]]
            if lost:
                regions = [np.r_[t["roi"][:2] - t["roi"][2] * self.cfg.local_search_scale / 2,
                                  t["roi"][:2] + t["roi"][2] * self.cfg.local_search_scale / 2] for t in lost]
                region = clipped_region(np.r_[np.min([r[:2] for r in regions], 0), np.max([r[2:] for r in regions], 0)], self.cfg.work_area)
                kind = "nearby_recovery"
            else:
                region, kind = self.cfg.work_area, "work_area_acquisition"
            self.last_detect = timestamp
            if region is not None:
                searches.append({"kind": kind, "region": region})
                detections = sorted(self.models.detection(frame, region), key=lambda x: x[1], reverse=True)
                for box, score in detections:
                    if len(accepted) >= self.cfg.max_hands:
                        break
                    # Skip boxes already occupied before paying for another landmark inference.
                    if any(iou(np.asarray(box), np.asarray(t["obs"]["box"])) > 0.5 for t in accepted):
                        continue
                    roi = roi_from_box(box, self.cfg.detection_margin)
                    roi[2] = np.clip(roi[2], self.cfg.min_side, self.cfg.max_side)
                    obs = self.models.landmark(frame, roi)
                    reason = self.quality(obs)
                    if reason or any(self.is_duplicate(obs, t["obs"]) for t in accepted):
                        failures.append({"id": None, "reason": reason or "duplicate_detection", "presence": obs["presence"]})
                        continue
                    occupied_ids = {t["id"] for t in accepted}
                    nearby = [t for t in lost if t["id"] not in occupied_ids and
                              np.linalg.norm(t["roi"][:2] - roi[:2]) / max(t["roi"][2], roi[2]) < 0.6]
                    if nearby:
                        track = min(nearby, key=lambda t: np.linalg.norm(t["roi"][:2] - roi[:2]))
                        gap = timestamp - track["last_good"]
                        track.update(roi=roi, anchor=float(roi[2]))
                        events.append({"kind": "recovered", "id": track["id"], "gap_s": gap})
                    elif len(self.tracks) < self.cfg.max_hands:
                        track = {"id": self.next_id, "roi": roi, "anchor": float(roi[2]), "streak": 0,
                                 "failures": 0, "birth": timestamp}
                        self.next_id += 1
                        self.tracks.append(track)
                        events.append({"kind": "created", "id": track["id"]})
                    else:
                        continue
                    obs["detector_score"] = score
                    self.accept(track, obs, timestamp, dt, detection=True)
                    accepted.append(track)
        visible = []
        for track in accepted:
            obs = dict(track["obs"])
            obs.update(id=track["id"], confirmed=track["streak"] >= self.cfg.confirmation_frames,
                       roi_next=track["roi"].tolist(), source=track["source"])
            visible.append(obs)
        self.events.extend(dict(e, time_s=timestamp) for e in events)
        calls = self.models.calls - before
        return {"hands": visible, "failures": failures, "searches": searches,
                "events": events, "calls": dict(calls)}
