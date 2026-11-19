# SPAAAAAAAAAACE — Game Design & MVP Technical Implementation Plan

## 1. Vision & Core Design Pillars

### 1.1 Honest Newtonian Physics & Component Mass Math
Every gameplay trade-off in **SPAAAAAAAAAACE** emerges from real 2D Newtonian mechanics (`GodotPhysics2D` with `gravity = 0`, `linear_damp = 0`, `angular_damp = 0`) rather than arbitrary stat multipliers:

* **Linear Motion (`F = M(t) · a`):** Total ship mass `M(t)` is the sum of dry component masses plus remaining fuel mass:
  ```text
  M(t) = m_hull + m_thruster + m_rcs + m_modules + m_fuel(t)
  ```
* **Rotational Motion (`τ = I(t) · α`):** Rotational moment of inertia `I(t)` scales with mass *and the square of each component's radial distance (`r²`) from the center of mass*:
  ```text
  I(t) = Σ (m_i · r_i²) + m_fuel(t) · r_tank²
  ```
* **Dynamic Fuel Depletion:** Thrusters consume fuel mass proportional to applied force (`fuel_burn_rate = Force × SpecificConsumption`). As fuel burns across a 3-lap race, both `M(t)` and `I(t)` decrease each physics frame, making the craft progressively lighter, faster to accelerate, and sharper to rotate on later laps.

### 1.2 Solving the "Small vs. Large Ship" Dilemma
Why wouldn't the smallest ship always win?

1. **Pure Racing Physics (Super-Linear Engine Scaling vs. `r²` Inertia Scaling):**
   * **Main Engines scale super-linearly:** Larger rocket engines achieve higher thrust density (`F_main / M`). A **Heavy Cruiser** has the highest straight-line acceleration and the strongest "flip-and-burn" retro-braking power when pointed directly opposite its velocity vector.
   * **Rotational Inertia scales with `r²`:** Because `I ∝ M · r²`, a large ship's rotational inertia grows much faster than its RCS torque. It rotates slowly (`α = τ_rcs / I`) and has weak lateral RCS relative to its mass.
   * **Resulting Driving Styles:**
     * **Light Ship ("Dart"):** Modest top acceleration, but snaps 180° almost instantaneously and has strong lateral RCS to arrest sideways drift. Excels on tight, technical hairpin tracks and is forgiving of late braking.
     * **Heavy Ship ("Cruiser"):** Blistering straight-line acceleration, but demands early commitment—pilots must initiate their 180° flip-and-burn well before a corner. Excels on sweeping high-speed circuits; punishes mistakes heavily.
2. **Future Roguelite & Drone Combat Loop (Post-MVP Architecture):**
   * Ships are **unmanned RC racing drones**, and racers enter each event with a **stock of ~4 drones** (respawning on destruction at a time/position penalty).
   * Heavy hulls can mount offensive weapons (missiles, lasers) with minimal percentage impact on their already-high inertia, hunting lighter drones.
   * Light drones must choose between running "naked" (maximum agility) or adding defensive modules (Shields, Chaff), which add mass and inertia, forcing larger thrusters and RCS packs in a classic roguelite build-crafting loop.

---

## 2. Architecture Overview

```text
[Main Menu (main_menu.tscn)]
   │  (Selected Ship, Track Seed, Control Mode)
   ▼
[GameState Autoload (game_state.gd)] ◄──► [user://best_times.cfg]
   │
   ▼
[Race Level (level.tscn)]
   ├── Track (track.gd): Procedural Curve2D Loop + Translucent Polygon2D + 12 Checkpoints
   ├── BackgroundController (background_generator.gd): 4 Parallax2D Layers (Stations & Asteroids)
   ├── PlayerShip (player_ship.gd): Newtonian RigidBody2D + Dynamic Fuel Mass + 3 Steering Modes
   └── HUD (hud.gd): Laps (1-3), Split/Best Timers, Fuel/Mass Readout, Prograde Velocity Vector
```

---

## 3. Proposed Changes by Component

### Component 1: Input Map & Multi-Mode Flight Controls

We will support both **Gamepad** and **Keyboard + Mouse (KBM)** out of the box, and allow switching between **three steering philosophies**:

1. **`STICK_AIM` (Gamepad Point-to-Aim):** Left stick direction sets target world heading (`stick.angle() + PI * 0.5`). The ship's fly-by-wire controller calculates the angular stopping distance from current `angular_velocity`, `rcs_torque`, and dynamic `inertia`, applying torque and counter-torque to land smoothly on the target angle.
2. **`MOUSE_AIM` (KBM Point-to-Aim):** Target world heading points from `PlayerShip.global_position` toward `get_global_mouse_position()`. Uses the exact same physical RCS torque and stopping-angle math as `STICK_AIM`—never snapping or cheating physics.
3. **`MANUAL_RCS` (Direct Rotational Thrust):**
   * Holding `turn_ccw` (Left Stick Left / `A` / `Left Arrow`) fires counter-clockwise RCS torque (`-rcs_torque`).
   * Holding `turn_cw` (Left Stick Right / `D` / `Right Arrow`) fires clockwise RCS torque (`+rcs_torque`).
   * When steering input is neutral (`abs(turn_axis) <= deadzone`), RCS automatically fires opposing torque to halt rotation—**unless** the ship is in **Decoupled Mode** (`toggle_rotational_stabilization` toggled off, or `hold_decoupled` held down), in which case the ship spins freely with zero angular damping.

#### [MODIFY] `project.godot`
Add KBM and manual RCS input actions alongside the existing joypad bindings:

| Action | Gamepad Binding | Keyboard / Mouse Binding | Purpose |
| :--- | :--- | :--- | :--- |
| `boost` | Right Trigger (Axis 5) | `W`, `Up Arrow`, `Left Mouse` | Main forward thruster |
| `stabilize_momentum` | L1 / LB (Button 9) | `S`, `Down Arrow`, `Space`, `Right Mouse` | Smart retro-burn / linear RCS brake |
| `turn_ccw` | Left Stick Left (Axis 0, -1.0) | `A`, `Left Arrow` | Manual RCS rotate counter-clockwise |
| `turn_cw` | Left Stick Right (Axis 0, +1.0) | `D`, `Right Arrow` | Manual RCS rotate clockwise |
| `look_left` / `right` / `up` / `down` | Left Stick (Axes 0 & 1) | — | Stick Point-to-Aim vector |
| `toggle_rotational_stabilization` | R1 / RB (Button 10) | `R` | Toggle Decoupled rotation mode |
| `hold_decoupled` | L2 / Left Trigger (Axis 4) | `Shift` | Momentary hold for Decoupled rotation |
| `cycle_steering_mode` | `Select` / `Back` (Button 4) | `Tab` | Cycle `STICK_AIM` / `MOUSE_AIM` / `MANUAL_RCS` |
| `quick_restart` | `Start` (Button 6) | `Backspace` | Restart current 3-lap race |
| `pause_menu` | `B` / East Button | `Escape` | Return to Main Menu |

---

### Component 2: Component Mass Math, Dynamic Fuel & 3 Ship Profiles

#### [NEW] `ship_defs.gd`
A static data/math script (`class_name ShipDefs`) that defines the 3 playable drones from physical component weights and computes derived telemetry for both `PlayerShip` and the Main Menu UI:

```text
Dry Mass:   M_dry = m_hull + m_engine + m_rcs
Wet Mass:   M_wet = M_dry + m_fuel_max
Inertia:    I(m_fuel) = I_dry + m_fuel * r_tank²   (where I_dry = 0.5 * M_dry * r_eff²)
```

| Stat / Component | 1. "Dart" (Light Drone) | 2. "Vector" (Medium Drone) | 3. "Titan" (Heavy Cruiser) |
| :--- | :--- | :--- | :--- |
| **Sprite (`SpaceShipsPack-AntuZ`)** | `A-01.png` (scale `0.28`) | `D-10.png` (scale `0.35`) | `H-16.png` (scale `0.45`) |
| **Hull + Frame Mass (`m_hull`)** | `0.45 kg` | `0.80 kg` | `1.50 kg` |
| **Main Engine Mass (`m_engine`)** | `0.20 kg` | `0.40 kg` | `1.00 kg` |
| **RCS Pack Mass (`m_rcs`)** | `0.15 kg` | `0.20 kg` | `0.30 kg` |
| **Dry Mass (`M_dry`)** | **`0.80 kg`** | **`1.40 kg`** | **`2.80 kg`** |
| **Max Fuel Mass (`m_fuel_max`)** | **`0.20 kg`** | **`0.40 kg`** | **`0.90 kg`** |
| **Wet Mass at Start (`M_wet`)** | **`1.00 kg`** | **`1.80 kg`** | **`3.70 kg`** |
| **Effective Radius (`r_eff`)** | `4.8` → `I_wet ≈ 11.5` | `6.0` → `I_wet ≈ 32.4` | `8.5` → `I_wet ≈ 133.6` |
| **Main Thrust (`F_boost`)** | `620 N` | `1,350 N` | `3,300 N` |
| **Linear Accel (Wet → Dry)** | `620 → 775 px/s²` | `750 → 964 px/s²` | **`892 → 1,178 px/s²`** *(Fastest)* |
| **RCS Torque (`τ_rcs`)** | `3,200 N·px` | `5,400 N·px` | `9,500 N·px` |
| **Angular Accel `α` (Wet → Dry)** | **`278 → 347 rad/s²`** *(Snappiest)* | `166 → 214 rad/s²` | `71 → 94 rad/s²` *(Slowest turn)* |
| **Lateral RCS Brake (`F_rcs_linear`)** | `240 N` (`240 px/s²` wet) | `320 N` (`178 px/s²` wet) | `420 N` (`113 px/s²` wet) |
| **Fuel Burn Rate (Main / RCS)** | `0.0022` / `0.0006 kg/s` | `0.0045` / `0.0010 kg/s` | `0.0105` / `0.0018 kg/s` |

> **Why these numbers work:**
> * **Titan (Heavy)** has **44% higher straight-line acceleration** than the Dart (`892` vs `620 px/s²` wet, climbing to `1,178 px/s²` as its `0.90 kg` fuel load burns off!), making it a monster on long straights and high-speed sweepers if you flip-and-burn early.
> * **Dart (Light)** has **nearly 4× higher angular acceleration** (`278` vs `71 rad/s²`) and **more than 2× stronger lateral RCS deceleration** (`240` vs `113 px/s²`), allowing it to snap 180° instantly and arrest sideways drift in tight hairpins.
> * If fuel reaches `0.0 kg`, main thrust drops to an emergency reserve mode (`25%` thrust) so the player isn't soft-locked, heavily rewarding fuel management over the 3 laps.

#### [MODIFY] `player_ship.gd`
* Apply selected ship profile on `_ready()` and recompute `mass` and `inertia` every `_physics_process(delta)` as `fuel_mass` decreases from main thruster and RCS usage.
* Implement the 3 steering modes (`STICK_AIM`, `MOUSE_AIM`, `MANUAL_RCS`) and decoupled rotation check (`not rotational_stabilize or Input.is_action_pressed("hold_decoupled")`).
* Dynamically control `$ExhaustSprite` visibility and scale based on active main thruster output (whether boosting manually or firing main engine during retro-braking).

---

### Component 3: Procedural Track Generation, Translucent Surface & Checkpoints

#### [MODIFY] `track.gd`
Replace the static 2-line setup with a procedural closed-loop spline track generator that supports both **Preset Track Archetypes** (seeded) and **Random Seeds**:

1. **Preset Track Profiles & Random Generation:**
   * **Track 1 — "Titan's Ring" (High-Speed Circuit):** Large radius (`~9,000 px`), wide lane (`520 px`), fewer radial control points (`10` points), low radial jitter. Long straights and sweeping curves where Heavy ships shine.
   * **Track 2 — "Lagrange GP" (Balanced Circuit):** Medium radius (`~7,500 px`), medium width (`440 px`), `14` control points with moderate chicane variation.
   * **Track 3 — "Kessler Slalom" (Technical Hairpins):** Tighter radius (`~6,500 px`), narrower lane (`380 px`), `18` control points with high radial oscillation creating sharp hairpins where Light ships dominate.
   * **Track 4 — "Random Sector" (Procedural Seed):** Generates a new random seed every time (with a "Re-roll Seed" button in the menu).
2. **Closed Spline Math (`Curve2D`):**
   * Generate `N` control points in polar coordinates `(R_i, θ_i)` around the origin with smooth Catmull-Rom tangents (`in` and `out` handles on a `Curve2D`), baked at even intervals (`bake_interval = 120.0`).
   * At each sampled centerline point `P_k` with unit tangent `T_k` and unit normal `N_k`:
     * `P_outer[k] = P_k + N_k * (Width / 2)`
     * `P_inner[k] = P_k - N_k * (Width / 2)`
3. **Translucent Track Surface & Visual Markings:**
   * **Track Bed (`Polygon2D` / Triangle Strip):** Generated between `P_outer` and `P_inner` with a translucent deep-cyan/slate fill (`Color(0.08, 0.22, 0.35, 0.32)`) so the player clearly sees the drivable track surface while still seeing the parallax space background beneath it.
   * **Centerline Guide (`Line2D`):** Subtle low-opacity tinted line (`Color(0.4, 0.8, 1.0, 0.2)`) along the spline centerline.
   * **Outer & Inner Walls (`Line2D` + `RectangleShape2D` segments):** High-contrast glowing border lines (`Color(0.2, 0.85, 1.0, 0.9)`) with continuous segment collision shapes.
   * **Start/Finish Line & Checkpoints:**
     * Checkered/highlighted visual gate at `P_0`, where `PlayerShip` spawns aligned with `T_0`.
     * `12` evenly spaced `Area2D` checkpoints along the track loop. Passing checkpoints in order (`0 -> 1 -> ... -> 11 -> 0`) increments the lap counter and records split/lap times, preventing players from reversing over the start line to cheat a lap.
     * Next active checkpoint is subtly highlighted on the track so the direction of travel is unmistakable.

---

### Component 4: Auto-Populated Multi-Layer Parallax Background

#### [NEW] `background_generator.gd`
Attached to a `BackgroundController` node in `level.tscn` (replacing the 5 hardcoded single-sprite `Parallax2D` nodes):
* Automatically reads the generated track's bounding box (with padding) and uses a seeded `RandomNumberGenerator` to populate **4 `Parallax2D` depth layers**:
  1. **Deep Space Stations (`scroll_scale = 0.04`, `z_index = -30`):** Large, distant stations from `kenney_space-shooter-extension/PNG/Sprites X2/Station/` (`spaceStation_017.png`–`025.png`), dimly modulated (`Color(0.5, 0.55, 0.7, 0.7)`).
  2. **Distant Asteroid Belt (`scroll_scale = 0.15`, `z_index = -25`):** Small/medium meteors from `kenney_simple-space/PNG/Default/meteor_*.png` and `kenney_space-shooter-extension/PNG/Sprites X2/Meteors/`.
  3. **Mid-Field Satellites & Debris (`scroll_scale = 0.30`, `z_index = -20`):** Satellites and structural parts scattered at medium scale.
  4. **Near-Field Asteroids (`scroll_scale = 0.55`, `z_index = -15`):** Closer, higher-contrast asteroids that streak past rapidly under the translucent track ribbon, providing immediate visual feedback for the ship's velocity vector and drift angle.

---

### Component 5: Pre-Race Menu, In-Race HUD & Persistent Best Times

#### [NEW] `game_state.gd`
An Autoload singleton (`GameState`) that:
* Holds current selections: `selected_ship_id` (`0..2`), `selected_track_id` (`0..3`), `custom_track_seed`, and `steering_mode` (`STICK_AIM`, `MOUSE_AIM`, `MANUAL_RCS`).
* Loads and saves best times per track (`best_race_time` for 3 laps and `best_lap_time` for a single lap, plus which ship set the record) using Godot's `ConfigFile` at `user://best_times.cfg`.

#### [NEW] `main_menu.tscn` & `main_menu.gd`
Set as the project's `run/main_scene` (or accessible at startup and via `Esc` from `level.tscn`):
* **Track Selector Panel:** Choose between *Titan's Ring (High-Speed)*, *Lagrange GP (Balanced)*, *Kessler Slalom (Technical)*, or *Random Sector* (with a Track Minimap Preview rendered via a `Line2D` thumbnail and saved **Best 3-Lap Time** / **Best Single Lap** display).
* **Ship Selector Panel:** Choose between *Dart (Light)*, *Vector (Medium)*, and *Titan (Heavy)*. Shows the ship's sprite, description, component mass breakdown (`Dry Mass`, `Fuel Mass`, `Moment of Inertia`), and normalized comparison bars for:
  * **Linear Acceleration (`F / M`)**
  * **Rotational Agility (`τ / I`)**
  * **Lateral RCS Control**
  * **Fuel Endurance**
* **Controls Selector:** Choose default steering mode (*Gamepad Stick Aim*, *Mouse Point-to-Aim*, or *Manual RCS Turn*) + quick control binding legend.
* **"Launch Race" Button:** Transitions into `level.tscn`.

#### [NEW] `hud.gd` (inside `level.tscn`)
A `CanvasLayer` HUD displaying:
* **Top-Left (Timing & Laps):**
  * `LAP 1 / 3` & `CHECKPOINT 4 / 12`
  * Current Lap Time, Last Lap Time, Total Race Time
  * Track Record (Best 3-Lap Race & Best Single Lap)
* **Bottom-Left (Ship Telemetry & Dynamic Mass):**
  * Speed (`px/s`)
  * Fuel Bar (`%` and remaining `kg`)
  * Live Ship Mass (`kg`) & Inertia (`I`) readout so you can watch the ship get lighter in real time as fuel burns
  * Steering Mode (`STICK AIM` / `MOUSE AIM` / `MANUAL RCS`) & Stabilizer Status (`COUPLED` vs `DECOUPLED`)
* **Center / Ship-Relative HUD:**
  * Subtle **Velocity Vector Indicator (Prograde Marker)** around the ship showing the exact direction the ship is drifting vs. where its nose is pointed—essential for Newtonian flight.
* **Race Finish Overlay:**
  * Appears upon completing Lap 3, showing Total 3-Lap Time, Best Lap Time, `NEW RECORD!` badges if applicable, and buttons for **Race Again (`Start` / `Backspace`)** or **Main Menu (`Esc`)**.

---

## 4. Verification Plan

1. **Headless / Script Validation:**
   * Run Godot CLI check (`godot --headless --quit --path /home/williamg/Projects/godot/spaaaaaaaaaace`) to verify all GDScript files, scenes, and UIDs parse with zero errors or warnings.
2. **Physics & Fuel Math Verification:**
   * Verify that selecting each of the 3 ships initializes the expected `mass` and `inertia`, that thrusting reduces `fuel_mass` and updates `RigidBody2D.mass` and `RigidBody2D.inertia` smoothly each physics frame, and that the Heavy ship accelerates faster in a straight line while the Light ship rotates ~4× faster.
3. **Controls Verification:**
   * Test all 3 steering modes (`STICK_AIM`, `MOUSE_AIM`, `MANUAL_RCS`) and verify that `Decoupled` mode (toggle `R`/`R1` or hold `Shift`/`L2`) disables automatic rotational braking.
4. **Track, Checkpoints & Persistence Verification:**
   * Verify closed-loop generation for all 3 preset tracks and random seeds, confirm translucent track surface rendering and wall collisions, complete a 3-lap run, and verify `user://best_times.cfg` persists records across restarts.


---

## 5. Development Log & Next Session Queue

### Completed So Far (Step 1)
* **SI Component Mass & Dynamic Fuel Physics (`player_ship.gd`):**
  * Editable `@export` part masses (`thruster_mass`, `fuel_mass`, `ship_part_3_mass`, `ship_part_4_mass`, `ship_part_5_mass`) structured via `_get_ship_parts()` for future per-part Center-of-Mass / inertia radius expansion.
  * Square-cube thruster scaling (`max_thrust = reference_thrust * (thruster_mass / reference_thruster_mass)^(2/3)`).
  * Real linear fuel burn (`kg/s = F / (I_sp * 9.80665)`) updating `mass` and `inertia` every physics tick (`I = total_mass * inertia_radius_m²`), plus `reset_fuel` input binding.
  * Fixed the 2-frame bang-bang torque overshoot ("~1 RPM ghost spin") using single-tick proportional torque clamping for rotational stabilization, stick aiming, and linear RCS braking.
* **Thruster Visuals & Live Telemetry (`level.tscn`, `rcs_thruster.tscn`, `player_ship.gd`):**
  * Main `ExhaustSprite` visibility & scale tied to active main thruster output.
  * 6 reusable `RCSThruster` sub-scene instances (`BowPort`, `BowStarboard`, `SternPort`, `SternStarboard`, `RetroPort`, `RetroStarboard`) wired with boolean on/off visibility based on active rotational and local-space linear RCS thrust.
  * Top-left `TelemetryLayer` HUD showing live Fuel, Mass (wet/dry), Inertia, Max Thrust/G, Burn Rate/Accel, and Speed.

---

### Next Session Queue (Step 2)

#### 1. Fix 60 Hz RCS Visual Flickering
* **Problem:** Because RCS thruster visibility is evaluated every physics tick (`60 Hz`), tiny corrective pulses cause the nozzles to strobe/flicker at 60 FPS, which looks unrealistic since real RCS solenoid valves have a minimum pulse width and don't cycle at 60 Hz.
* **Planned Fix:**
  * Add a configurable minimum valve pulse duration / visual hold timer (e.g., `rcs_min_pulse_duration = 0.06–0.10 s`) and/or a visual trigger threshold / hysteresis per nozzle so once an RCS thruster fires, it stays cleanly lit for a believable valve puff instead of strobing frame-by-frame.

#### 2. Implement 3 Distinct Ships (Acceleration vs. RCS Turn Rate Trade-Off)
* **Design Goal:** Three playable ship profiles driven by real SI `thruster_mass` and `fuel_mass` trade-offs (with square-cube thrust scaling and uniform `inertia_radius_m` / larger hull radius as appropriate):
  1. **Light Ship:** Smallest thruster mass & fuel mass → lowest straight-line acceleration, highest RCS turn rate (`α = τ / I`).
  2. **Medium Ship:** Balanced thruster mass, fuel mass, and turn rate (current baseline).
  3. **Heavy Ship:** Largest thruster mass & fuel mass → highest straight-line acceleration (bigger thruster overcoming dry hull mass), lowest RCS turn rate (highest total mass & inertia).
* **How to Structure Multiple Ships in Godot (No Duplicating `Camera2D` / `HUD`):**
  * Keep **one** `PlayerShip` scene/node (with its attached `Camera2D`, `TelemetryLayer`, and `RCSThrusters`), and apply a swappable **Ship Profile** to it whenever a ship is selected (updating its part masses, `inertia_radius_m`, sprite texture/scale, collision size, and RCS nozzle positions).
  * **Storage Format Choice (Decide when resuming):**
    * **JSON (`ships.json`):** Universal, plain-text, easy to edit in `nvim`, easy to diff in Git, and mod-friendly.
    * **Godot Custom `Resource` (`.tres`):** Also plain-text, natively editable in the Godot Inspector with drag-and-drop `Texture2D` previews and strict GDScript typing (no manual JSON parsing).
    * Both formats plug cleanly into the exact same `apply_ship_profile(profile)` method on `PlayerShip`.
* **Testing Hook:** Add a quick ship-cycle key/button so all 3 ships can be compared immediately on the track before building the Main Menu.
