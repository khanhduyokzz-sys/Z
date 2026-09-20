# DSWUnity

<p align="center">
  <strong>Native iOS Free Fire ESP Overlay + Aim Engine</strong><br>
  Contact / Support: <a href="https://t.me/duydzne">https://t.me/duydzne</a>
</p>

---

## 📌 Overview

**DSWUnity** is a high-performance rootless iOS ESP overlay + aim assist for Free Fire. It runs entirely outside the game process, acquires kernel read/write via exploit chain, opens a SpringBoard remote-call channel, and streams live enemy geometry into a passthrough overlay window rendered locally with `CAShapeLayer`.

---

## ✨ ESP Features

- **2D Bounding Box** — projected from live bone transforms
- **Tracelines** — clear enemy direction vectors
- **Health Bar** — live HP percentage
- **Nickname** — decoded UTF-16 in-place
- **Distance Meter** — precise distance in metres
- **Enemy Counter** — real-time player counter inside render range
- **Anti-Screen-Capture** — hide overlay from screenshots & screen recordings
- **Adaptive Tick Rate** — 1 to 30 Hz refresh rate

---

## 🎯 Aim Engine (VIP Standard)

- **Aimbot** — kernel-steered aim rotation (Slerp smoothing, instant retarget)
- **FOV Circle** — VIP mint circle drawn at screen centre; selection window is 3× the circle radius
- **Aim Lock Line** — crosshair → locked target line
- **Aim Position** — Head / Neck / Chest / Upper-Head bone targeting
- **Trigger Modes** — Always · Firing · Scoping · Firing+Scope (auto-fire)
- **Bullet Prediction** — real PhysicalCCT velocity + weapon fire-interval / damage-range profile
- **Smart Filters** — ignore bots, ignore knocked, PVS visibility check
- **Fail Closed** — every write is gated behind the Aim write domain and disarmed when Aimbot is off

---

## 📱 Contact

Telegram: [https://t.me/duydzne](https://t.me/duydzne)
