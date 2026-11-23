# SPAAAAAAAAAACE — Game Design & MVP Technical Implementation Plan

## 0. Current Progress & Next Session Queue

### Completed So Far
* **Modular Part Resource System & 36-Part 4-Tier Catalog (`parts/ship_part.gd`, `hull_part.gd`, `thruster_part.gd`, `rcs_part.gd`, `ship_data.gd`):**
  * Ships are composed of swappable `Resource` pointers (`HullPart`, `ThrusterPart`, `RCSPart`, `aux_parts`) with `SizeClass` compatibility (`SMALL`, `MEDIUM`, `LARGE`, `UNIVERSAL`).
  * Full 36-part catalog across `Small`, `Medium`, and `Large` classes and Tech Tiers `T1–T4` (`Steel → Titanium → Carbon → Exotic` hulls; `Chemical → NTR → Fusion Torch → Exotic` engines; `Hydrazine → Resistojet → Plasma → Exotic` RCS) with live D-pad hot-swapping.
* **SI Component Mass, Inertia & Unified Fuel Physics (`player_ship.gd`):**
  * Total `mass` and uniform `inertia` (`I = Σ m · r²`) derived dynamically from installed `ShipPart` masses + shared `fuel_mass` tank (updating live every physics tick as propellant burns).
  * Square-cube scaling (`2/3` exponent × part `tech_thrust_multiplier`) for **both** main thrusters and symmetric RCS nozzles (equidistant at `hull.rcs_lever_arm_m`).
  * Shared propellant tank (`fuel_mass`) feeding both main engine (`thruster.specific_impulse`) and RCS nozzles (`rcs.specific_impulse`), refilled via `reset_fuel`.
  * Live top-left telemetry HUD (`TelemetryLayer`) showing Ship Name, Installed Parts `[T1–T4]` & `I_sp`, Fuel, Mass, Inertia, Turn Rate, Derived RCS Torque, Max Thrust/G, Burn Rates, Accel, Speed, and Track Type/Seed.
* **RCS Pulse-Clamping, Valve Timing & Deadband (`player_ship.gd`):**
  * Fixed the 2-frame bang-bang overshoot ghost-spin bug using time-optimal phase-plane aiming + PWM final-tick pulse clamping.
  * Added per-nozzle minimum valve on/off timers (`0.08 s` / `0.08 s`) for crisp boolean RCS plumes and a `0.025 rad` (`1.4°`) stick-aim deadband to stop analog stick noise from wasting fuel.
* **3 Swappable Ship Hulls (`hull_small/medium/large.tscn`):**
  * Visually fitted `HullCollision` reparented onto `PlayerShip`, per-hull exhaust base scaling, and live D-pad size/tier cycling.
* **True-Perspective Continuous-Depth Space Background (`background_objects.gd`):**
  * Continuous 3D distance `Z` (`2.2..110`) with toroidal wrapping, Gaussian bell-curve AntuZ meteors with size-limited structural spin (`1 / R`), Kenney X2 stations, colossal deep-space anchors (`xl` meteors & `017`/`026` megastations), and exact 3D camera-altitude projection (eliminating 2D dolly-zoom warp).
* **4-Tier Procedural Track Generator, Minimap & Course-Sightline Camera (`track.gd`, `minimap.gd`, `ship_camera.gd`):**
  * Asymmetric Convex Hull + Perpendicular Edge Carving generator with 4 escalating track types (`Type 1 - Speedway`, `Type 2 - Circuit`, `Type 3 - Technical`, `Type 4 - Switchback`), cycled via `new_track` (`N`) and saved with type & seed via `save_track` (`S`) to `user://saved_tracks.json`.
  * Top-right corner minimap (`minimap.gd`) showing track walls, start marker, and live ship chevron (flip-and-burn projection kept in code, toggled off by default).
  * 3-zone honest course-sightline camera (`ship_camera.gd`) following a heavily smoothed gentle-arc camera rail with a critically damped spring (`close_zoom = 1.50` in tight turns, `default_zoom = 1.15` normal, `wide_zoom = 0.85` on major straights).

### Thermal System & Overburn Propulsion (Implemented MVP + Post-MVP Balance Plan)
* **Overburn (Emergency Thrust Augmentation — Implemented):**
  * Triggered via dedicated `overburn` bind: fires the main engine at **full throttle × `200%` thrust (`2.0×`)** at the cost of **`400%` fuel consumption (`4.0×`)** (effectively halving `I_sp` like real-world propellant-injected thrust augmentation) and heavy thermal buildup.
  * Solves zero-G braking emergencies without fake arcade brakes: lets pilots burn extra fuel and thermal headroom to save a missed braking point or launch hard out of a hairpin.
* **Ship Thermal Pool, Stefan-Boltzmann Radiation & Safety Interlock (Implemented):**
  * Engine adds `overburn_heat_kw` while overburning; hull radiates heat continuously via exact **Stefan-Boltzmann `T⁴` cooling** (`300 K → 650 K`, so hot hulls radiate dramatically faster than cool hulls, rewarding redline management).
  * **Default Safety Interlock:** At `100%` heat, the engine's onboard thermal safety cuts off **Overburn only** until heat drops below `25%`, while normal `100%` main thrust remains usable.
  * **Future Safety-Disabled / Jailbroken Engines:** Specialized high-risk engines or manufacturer mods can disable the thermal safety interlock, allowing pilots to push past `100%` heat for desperate saves at the risk of **permanently burning out the engine** (forcing deployment of the next RC drone stock in the race).
* **Part Stat Ownership & Post-MVP Cooling Rebalance:**
  * **Heat Generation (`ThrusterPart`):** Each engine defines `overburn_heat_kw` (scaling up across Chemical → NTR → Fusion → Exotic), allowing cool-running vs. hot-running engine perks across tiers and manufacturers.
  * **Baseline Passive Cooling (`HullPart`):** Single-part baseline cooling (`max_radiative_cooling_kw`, `heat_capacity_kj`) lives on the **Hull**, scaling with material tier (`Steel → Titanium → Carbon → Exotic`) and hull size.
  * **MVP vs. Post-MVP Rebalance Note:** Current bare-hull passive cooling is intentionally tuned to be comfortable and self-sufficient for the MVP (before auxiliary modules exist). Once auxiliary cooling parts and lasers are introduced, **bare-hull passive cooling should be nerfed significantly** so that vacuum behaves like a true thermos — making current-level heat management achievable *only* by investing mass into a dedicated cooling system (creating a genuine ultralight "naked" vs. actively/passively cooled build trade-off).
  * **Future Auxiliary Heat Sinks (`AuxPart` / `DefensePart` — Two Distinct Archetypes):**
    * **Passive Radiators:** Add dry mass to permanently boost `max_radiative_cooling_kw` (strong against sustained heat and enemy Lasers).
    * **Active Expendable Heat Sinks (Thermal Slug Ejectors):** Carry a magazine of solid high-heat-capacity blocks/slugs (scaling from basic metals up to exotic sci-fi thermal-storage materials). Triggering one rapidly dumps a large burst of ship heat into a slug and **ejects the superheated slug into space**, instantly cooling the ship **and shedding the slug's real mass** (lowering ship mass & inertia mid-race).
* **Thermal HUD Gauge (Implemented):**
  * GUI-movable/resizable bottom-center heat gauge (`heat_gauge.gd`) that fills `0% → 100%`, shifting smoothly **yellow → orange → red**, with a `25%` safety-recovery tick and crimson pulse during lockout.

### Post-MVP Stretch Goals (Generational Space-Racing Roguelite)
* **Generational Family Bloodline & Career Circuit:**
  * Each run is a career across increasingly difficult, higher-payout racing leagues in a futuristic spectator sport; when a run ends, the next run continues as a **descendant in the same family line** carrying forward legacy unlocks/heirlooms.
* **Part Manufacturers, Economy & Garage / Shop UI:**
  * Prize money, manufacturer catalogs with distinct design philosophies (e.g., ultra-light composite makers, high-`I_sp` nuclear/fusion engine houses, high-torque RCS specialists), roguelite shop drafts between races, and an in-game Garage UI respecting `SizeClass` compatibility.
* **Core Tech-Tier Progression Rule:**
  * Moving up in tech tier (e.g., 1960s Chemical → Nuclear Thermal → MPD Plasma → Fusion Torch; Steel → Carbon-Composite; Hydrazine RCS → Plasma RCS) should improve **acceleration, fuel staying time, AND turn rate together** (achieved via lighter advanced materials + higher thrust density + higher `I_sp`), reserving heavy trade-off parts for specialized optional variants or weapons/defenses.
* **Advanced Propulsion & Attitude Control Parts:**
  * Full tech-tree progression across all 3 ship classes: 1960s Chemical (`310 s`) → Nuclear Thermal (`~900 s`) → Magnetoplasmadynamic / MPD Plasma (`~1,800 s`) → Fusion Torch / Epstein-style Drives (`2,500+ s`).
  * **Electric Reaction Wheels / Control Moment Gyroscopes (CMGs)** (zero-fuel rotation with saturation limits) and weight-shedding hulls/tanks.
* **Weapons, Countermeasures & Combat Triangle (All Built on `ShipPart` Weight Math):**
  * Unmanned RC drone fleets (e.g., 4 drone stocks per race with respawn penalties), with hull hardpoint limits (`weapon_slots` / `defense_slots` on `HullPart`) giving Large hulls the firepower advantage.
  * **Weapons (`WeaponPart extends ShipPart`, plus higher-tech tiers of each):**
    * **Kinetic Repeaters:** Rapid projectile weapons; carry ammo mass (shedding weight as fired) and impart real Newtonian recoil impulses.
    * **Lasers:** Hitscan/beam energy weapons; no ammo mass, but generate heavy thermal load requiring heat dissipation.
    * **Missiles:** Guided ordnance; heavy payload mass that drops off the ship on launch.
  * **Countermeasures & Defenses (`DefensePart extends ShipPart`, plus higher-tech tiers of each):**
    * **Kinetic Shielding:** Counters Kinetic Repeaters at the cost of shield generator mass.
    * **Heat Dissipation Systems (Radiators / Heat Sinks):** Counters enemy Lasers *and* manages heat from your own high-output lasers/drives at the cost of radiator mass.
    * **Chaff Pods:** Counters Missiles by breaking guidance locks; sheds minor mass as charges are deployed.
  * **Optional Strategy & Physics Depth:** Mid-race Pit/Refuel lanes, and per-part physical Center-of-Mass / pixel-based rotational inertia (`I = Σ m_i · r_i²`).
* **Dynamic Speed-Based Camera Zoom:**
  * Smoothly lerp `Camera2D.zoom` out as speed increases (zoomed in close when slow, wider view of upcoming corners at high speed).

### Next MVP Steps
* **Playable Racing Loop:** Controls (KBM Mouse-Aim + Manual RCS + Decoupled hold), Procedural Track + Translucent Track Ribbon + Checkpoints, Auto-Populated Parallax Asteroids/Stations, Main Menu & 3-Lap Time Trial Persistence.

---

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
