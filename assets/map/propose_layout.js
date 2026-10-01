// Generates the mirrored battlefield layout (layout.json v2.0, the exterior from
// MAP-REVISION-PROPOSAL.md, approved for an in-game preview 2026-10-01) and checks it:
// pad gaps, the central road clear, crater/barricade/cover clearances, the L tunnels,
// pads inside bounds, exact mirroring, steepest pad-to-pad ramp, walking times.
// Team A is authored on the west (x < 0); team B is its mirror across x = 0.
// Roblox coordinates: ground plane (x, z), height y. Studs. -Z is north.
//
//   node assets/map/propose_layout.js              check only, prints the report
//   node assets/map/propose_layout.js layout.json  also writes the file
//
// THE CASTLE INTERIOR IS NOT HERE. The 2026-09-30 keep, storage, barracks, workshop and
// cannon mounts are stale (DESIGN.md, 2026-10-01) and were dropped; the new interior
// needs its own approved proposal. The only things inside the walls are the tunnel exit,
// the reserved rear half, and TEMPORARY preview spawns that are not a design decision.
const fs = require("fs");
const out = process.argv[2];

const WALK = 16; // Roblox default WalkSpeed; the code never changes it
const BAY = 20.4; // castle kit wall bay
const BAYS = 9; // per side
const RING = BAYS * BAY; // 183.6, outer face to outer face
const WALL_T = 4.0; // castle kit wall thickness
const PAD_MARGIN = 8.2; // pad edge beyond the ring: 200 x 200 pad
const ROAD = { width: 30, z: 0 };
const EDGE_BELT = 60;
const BOUNDS = { min_x: -520, max_x: 520, min_z: -340, max_z: 340 };
const BOUNDARY_OFFSET = 30; // invisible wall this far outside map_bounds
const FIELD_Y = 4;
// Largest measured footprint per type on the old map, rounded (layout.old-island.json).
const FOOTPRINT = { Wood: 100, Wool: 117, Grain: 65, Stone: 85, Ore: 72 };
const NODE_MARGIN = 8;
const padRadius = (types) => Math.max(...types.map((t) => FOOTPRINT[t])) / 2 + NODE_MARGIN;

// Minimum clearances the checks enforce. The proposal's own audit measured the closest
// pads at 11.9 (node-node) and 9.9 (node-castle) and accepted them, so the pad rule is
// "a ramp's width apart", not the older 20.
const MIN = { pad_gap: 8, road_to_pad: 40, road_to_crater: 15, road_to_barricade: 20, road_to_cover: 10,
  crater_to_pad: 20, cover_to_pad: 0, tunnel_portal_to_pad: 10, tunnel_exit_to_wall: 10 };

const castleA = { id: "Castle_A", team: "A", center: { x: -280, y: 10, z: 0 } };
// Home: behind and beside the castle. Mid: flanks. Forward: toward the axis. Center: ON
// the axis, so each mirrors onto itself (shared, contested). Only slot 5 moved from v1.1:
// (-170, 0) would sit on the enlarged castle pad and the road.
const slotsA = [
  { n: 1, ring: "home", types: ["Wood", "Grain"], x: -420, z: -190, y: 9 },
  { n: 2, ring: "home", types: ["Wool", "Grain"], x: -420, z: 195, y: 9 },
  { n: 3, ring: "mid", types: ["Stone", "Wood"], x: -250, z: -190, y: 8 },
  { n: 4, ring: "mid", types: ["Stone", "Wool"], x: -260, z: 185, y: 8 },
  { n: 5, ring: "mid", types: ["Stone", "Grain"], x: -125, z: 125, y: 6, moved_from: { x: -170, z: 0 } },
  { n: 6, ring: "forward", types: ["Ore", "Stone"], x: -120, z: -235, y: 6 },
  { n: 7, ring: "forward", types: ["Ore", "Wood"], x: -115, z: 245, y: 6 },
];
const center = [
  { id: "Node_C1", ring: "center", types: ["Ore"], x: 0, z: -110, y: 4 },
  { id: "Node_C2", ring: "center", types: ["Ore"], x: 0, z: 110, y: 4 },
];
// Team A's battlefield features; B mirrors them.
const CRATERS_A = [{ n: 1, x: -105, z: -65 }, { n: 2, x: -55, z: 48 }];
const CRATER = { outer_radius: 18, floor_radius: 9, floor_depth: 1.5, rim_height: 1.5 };
const BARRICADES_A = [{ n: "N", x: -125, z: -37 }, { n: "S", x: -125, z: 37 }];
const BARRICADE = { length_x: 12, depth_z: 4, height: 3.5 };
const COVER_A = [
  { id: "A_Cover_N", purpose: "gate-side cover north of the road", min_x: -177, max_x: -132, min_z: -68, max_z: -40 },
  { id: "A_Cover_S", purpose: "gate-side cover south of the road", min_x: -177, max_x: -132, min_z: 40, max_z: 68 },
  { id: "A_Cover_Tunnel", purpose: "hides the tunnel entrance", min_x: -105, max_x: -65, min_z: -138, max_z: -102 },
];
const TUNNEL_A = { entrance: { x: -85, z: -120 }, bend: { x: -260, z: -120 }, exit: { x: -260, z: -55 } };
const TUNNEL = { width: 6, clear_height: 3.5, one_traveller: true };
// PREVIEW ONLY: somewhere safe to stand inside the walls so the in-game review can start.
// South-front courtyard, away from the tunnel exit (north-front) and the reserved rear half.
// Not barracks positions; the interior proposal replaces them.
const PREVIEW_SPAWNS_F = [20, 32, 44];
const PREVIEW_SPAWNS_Z = [36, 46];

const mirror = (p) => ({ ...p, x: -p.x });
const r1 = (v) => Math.round(v * 10) / 10;
const swapAB = (id) => id.replace(/^A_/, "B_").replace(/_A(\d)/, "_B$1");

// ---------------------------------------------------------------- castles (exterior shell only)
// Authored in castle-local "forward" coordinates: f points from the castle centre toward
// its gate, z is world z. World x = centre.x + sign * f, so B (sign -1) mirrors A exactly.
const HALF = RING / 2; // 91.8: outer face
const WALL_LINE = HALF - WALL_T / 2; // 89.8: wall centre line
const INNER = HALF - WALL_T; // 87.8: inner face

function castle(c, sign) {
  const cx = c.center.x, y = c.center.y;
  const W = (f, z) => ({ x: r1(cx + sign * f), y, z: r1(z) });
  const T = c.team;
  const facing = { x: sign, z: 0 };
  // 35 wall sections: 9 a side less the gate bay. F = front (gate side), R = rear,
  // N = north (-z), S = south (+z). Numbered along +z (F, R) or +f (N, S).
  const sections = [];
  const along = [...Array(BAYS).keys()].map((k) => r1((k - (BAYS - 1) / 2) * BAY));
  const gateBay = (BAYS - 1) / 2;
  along.forEach((t, k) => { if (k !== gateBay) sections.push({ id: `${T}_Wall_F${k + 1}`, ...W(WALL_LINE, t), facing }); });
  along.forEach((t, k) => sections.push({ id: `${T}_Wall_R${k + 1}`, ...W(-WALL_LINE, t), facing: { x: -sign, z: 0 } }));
  along.forEach((t, k) => sections.push({ id: `${T}_Wall_N${k + 1}`, ...W(t, -WALL_LINE), facing: { x: 0, z: -1 } }));
  along.forEach((t, k) => sections.push({ id: `${T}_Wall_S${k + 1}`, ...W(t, WALL_LINE), facing: { x: 0, z: 1 } }));
  const towers = [
    { id: `${T}_Tower_FN`, ...W(WALL_LINE, -WALL_LINE) },
    { id: `${T}_Tower_FS`, ...W(WALL_LINE, WALL_LINE) },
    { id: `${T}_Tower_RN`, ...W(-WALL_LINE, -WALL_LINE) },
    { id: `${T}_Tower_RS`, ...W(-WALL_LINE, WALL_LINE) },
  ];
  const spawns = [];
  for (const f of PREVIEW_SPAWNS_F) for (const z of PREVIEW_SPAWNS_Z) spawns.push(W(f, z));
  const rearX = [cx, cx - sign * INNER].sort((a, b) => a - b);
  return {
    id: c.id, team: c.team, center: c.center,
    ring_size: { x: r1(RING), z: r1(RING) }, wall_bays_per_side: BAYS, wall_thickness: WALL_T,
    pad: { shape: "square", size: r1(RING + 2 * PAD_MARGIN), y },
    gate: { ...W(HALF, 0), id: `${T}_Gate`, door_id: `${T}_Gate_Door`, bay: `${T}_Wall_F${gateBay + 1}` },
    gate_facing: facing,
    art_heights_placeholder: { wall_top: 20.4, tower_battlement: 30.9, tower_tip: 49, gate_opening_height: 18.2,
      note: "Measured against a 5-stud soldier in the concept image, 2026-10-01 (TARGET-LAYOUT-PROPOSAL.md option C); replaces the proposal's 60-65 tips." },
    towers, wall_sections: sections,
    tunnel_exit: { id: `${T}_Tunnel_Exit`, ...W(TUNNEL_A.exit.x - castleA.center.x, TUNNEL_A.exit.z) },
    reserved_rear_half: { min_x: r1(rearX[0]), max_x: r1(rearX[1]), min_z: -INNER, max_z: INNER,
      note: "Keep and separate stockpile go here once an interior proposal is approved; their entry points must be at least 60 studs of courtyard route from the tunnel exit." },
    temporary_preview_spawns: spawns.map((s, i) => ({ id: `${T}_PreviewSpawn_${i + 1}`, ...s })),
    interior: null,
    interior_note: "NOT DEFINED. Keep, stockpile, barracks, workshop, spawns, tower access and ballista mounts need a new interior proposal (DESIGN.md open decisions). v1.1 positions are in git history and are stale.",
  };
}
const castles = [castle(castleA, +1), castle({ ...castleA, id: "Castle_B", team: "B", center: mirror(castleA.center) }, -1)];

// ---------------------------------------------------------------- node slots
const slots = [];
for (const s of slotsA) {
  const base = { ring: s.ring, allowed_types: s.types, pad_radius: padRadius(s.types) };
  const moved = s.moved_from ? { moved_2026_10_01_from: s.moved_from } : {};
  slots.push({ id: `Node_A${s.n}`, side: "A", mirror_pair: `Node_B${s.n}`, position: { x: s.x, y: s.y, z: s.z }, ...base, ...moved });
  slots.push({ id: `Node_B${s.n}`, side: "B", mirror_pair: `Node_A${s.n}`, position: { x: -s.x, y: s.y, z: s.z }, ...base,
    ...(s.moved_from ? { moved_2026_10_01_from: mirror(s.moved_from) } : {}) });
}
for (const s of center) {
  slots.push({ id: s.id, side: "shared", mirror_pair: s.id, position: { x: s.x, y: s.y, z: s.z },
    ring: s.ring, allowed_types: s.types, pad_radius: padRadius(s.types) });
}

// ---------------------------------------------------------------- the battlefield
const [cA, cB] = castles;
const road = { id: "Central_Road", surface: "dirt", from: { x: cA.gate.x, z: ROAD.z }, to: { x: cB.gate.x, z: ROAD.z },
  width: ROAD.width, min_x: cA.gate.x, max_x: cB.gate.x, min_z: ROAD.z - ROAD.width / 2, max_z: ROAD.z + ROAD.width / 2,
  note: "Collision-clear 30 studs: no props, nodes or trees. The dirt colour may meander and widen at the gates." };
const craters = [];
for (const k of CRATERS_A) for (const [side, sx] of [["A", 1], ["B", -1]])
  craters.push({ id: `${side}_Crater_${k.n}`, x: sx * k.x, y: FIELD_Y, z: k.z, ...CRATER, placeholder_profile: true });
const barricades = [];
for (const b of BARRICADES_A) for (const [side, sx] of [["A", 1], ["B", -1]])
  barricades.push({ id: `${side}_Barricade_${b.n}`, x: sx * b.x, y: FIELD_Y, z: b.z, ...BARRICADE, yaw_deg: 0 });
const cover = [];
for (const c of COVER_A) {
  cover.push({ ...c });
  cover.push({ ...c, id: swapAB(c.id), min_x: -c.max_x, max_x: -c.min_x });
}
const tunnels = [["A", 1], ["B", -1]].map(([side, sx]) => {
  const p = (q) => ({ x: sx * q.x, z: q.z });
  const e = p(TUNNEL_A.entrance), b = p(TUNNEL_A.bend), x = p(TUNNEL_A.exit);
  return { id: `${side}_Tunnel`, team: side, entrance: e, bend: b, exit: x, cover_zone: `${side}_Cover_Tunnel`,
    outer_leg: Math.abs(b.x - e.x), inner_leg: Math.abs(x.z - b.z), ...TUNNEL,
    note: "Underground; only the two portals are art in the preview. Crawl speed, width and clearance are placeholders." };
});

const layout = {
  meta: {
    status: "APPROVED FOR AN IN-GAME VISUAL PREVIEW 2026-10-01 (MAP-REVISION-PROPOSAL.md). Exterior battlefield only; subject to revision after the in-game review.",
    interior_status: "NOT DEFINED. The 2026-09-30 interior (v1.1, in git history) is stale and was removed. A new interior proposal is required before Keep, stockpile, barracks, workshop, spawn or ballista positions exist. temporary_preview_spawns are for the visual review only.",
    version: "2.0", date: "2026-10-01", units: "studs",
    coords: "Roblox: ground plane (x, z), height y. Blender: (x, y, z) -> (x, -z, y).",
    compass: "-Z = north, +X = east. Team A west, team B east.",
    generator: "assets/map/propose_layout.js",
    replaces: "layout.json v1.1 (2026-09-30: 102-stud rings at x = ±370, gate lanes, interior). Older: layout.old-island.json.",
  },
  map_bounds: { ...BOUNDS, note: "Playable area. Everything inside is land; no water inside." },
  mirror_axis: { type: "plane", x: 0, note: "Team B = team A with x negated. Slots on x = 0 mirror onto themselves." },
  boundary: {
    type: "invisible_wall", offset_outside_bounds: BOUNDARY_OFFSET, corner_radius: 120, height: 60,
    placement: "Rounded rectangle 30 studs outside map_bounds, on the beach. Coast must lie beyond it. Plus a kill volume at y = -30 as a safety net.",
  },
  heights: { castle_pad_y: 10, field_y: FIELD_Y, note: "Gentle, walkable approaches. No inland water, no mountain ring." },
  teams: [{ id: "A", side: "west", castle: "Castle_A", banner_color_placeholder: "#B8413A" },
          { id: "B", side: "east", castle: "Castle_B", banner_color_placeholder: "#3A5FB8" }],
  castles,
  central_road: road,
  resource_node_slots: slots,
  node_footprints: FOOTPRINT,
  craters,
  barricades,
  cover_zones: cover,
  tunnels,
  decoration_rules: { edge_belt_depth: EDGE_BELT, pines_only_in: ["edge belt", "cover_zones"], round_canopy_trees: "Wood node pads only",
    never_in: ["central_road", "pads", "craters", "barricades"] },
  zone: null,
  zone_note: "No shrinking zone in the current two-team design. DESIGN.md parks the old free-for-all zone.",
};

// ---------------------------------------------------------------- checks
const problems = [];
const pads = [
  ...castles.map((c) => ({ id: c.id, kind: "rect", min_x: c.center.x - c.pad.size / 2, max_x: c.center.x + c.pad.size / 2,
    min_z: c.center.z - c.pad.size / 2, max_z: c.center.z + c.pad.size / 2, y: c.pad.y, x: c.center.x, z: c.center.z })),
  ...slots.map((s) => ({ id: s.id, kind: "circle", x: s.position.x, z: s.position.z, r: s.pad_radius, y: s.position.y })),
];
// signed-ish distance from a point to a shape's outline (0 inside)
const distTo = (p, x, z) => {
  if (p.kind === "circle") return Math.max(0, Math.hypot(x - p.x, z - p.z) - p.r);
  return Math.hypot(Math.max(0, p.min_x - x, x - p.max_x), Math.max(0, p.min_z - z, z - p.max_z));
};
const outline = (a) => {
  if (a.kind === "circle") return [...Array(96).keys()].map((k) => [a.x + Math.cos(k * Math.PI / 48) * a.r, a.z + Math.sin(k * Math.PI / 48) * a.r]);
  const pts = [];
  for (let k = 0; k <= 32; k++) {
    const t = k / 32;
    const x = a.min_x + (a.max_x - a.min_x) * t, z = a.min_z + (a.max_z - a.min_z) * t;
    pts.push([x, a.min_z], [x, a.max_z], [a.min_x, z], [a.max_x, z]);
  }
  return pts;
};
const gap = (a, b) => Math.min(Math.min(...outline(a).map(([x, z]) => distTo(b, x, z))), Math.min(...outline(b).map(([x, z]) => distTo(a, x, z))));
const rect = (o, id) => ({ id: id || o.id, kind: "rect", min_x: o.min_x, max_x: o.max_x, min_z: o.min_z, max_z: o.max_z });
const circ = (id, x, z, r) => ({ id, kind: "circle", x, z, r });
const roadR = rect(road);
const craterC = craters.map((c) => circ(c.id, c.x, c.z, c.outer_radius));
const barrR = barricades.map((b) => rect({ min_x: b.x - b.length_x / 2, max_x: b.x + b.length_x / 2, min_z: b.z - b.depth_z / 2, max_z: b.z + b.depth_z / 2 }, b.id));
const coverR = cover.map((c) => rect(c));
const report = {};
const need = (label, value, min) => {
  report[label] = r1(value);
  if (value < min - 1e-6) problems.push(`${label} is ${r1(value)}, needs >= ${min}`);
};

// pads apart
let minPad = Infinity, minPadPair = null;
for (let i = 0; i < pads.length; i++) for (let j = i + 1; j < pads.length; j++) {
  const g = gap(pads[i], pads[j]);
  if (g < minPad) { minPad = g; minPadPair = [pads[i].id, pads[j].id]; }
}
need("min_pad_gap", minPad, MIN.pad_gap);
report.min_pad_gap_between = minPadPair;
// road: no pad on it except the castles it joins (whose gates are its ends)
need("road_to_nearest_node_pad", Math.min(...pads.filter((p) => p.kind === "circle").map((p) => gap(p, roadR))), MIN.road_to_pad);
for (const c of castles) {
  const p = pads.find((q) => q.id === c.id);
  // the road starts at the gate, so it crosses only the pad's apron outside the ring
  const apron = Math.min(p.max_x, roadR.max_x) - Math.max(p.min_x, roadR.min_x);
  if (apron > PAD_MARGIN + 1e-6) problems.push(`road runs ${r1(apron)} into ${c.id}'s pad, past its gate`);
  report.road_over_castle_pad_apron = r1(apron);
  if (Math.abs(c.gate.x - (c.team === "A" ? road.min_x : road.max_x)) > 1e-6 || c.gate.z !== road.from.z) problems.push(`road does not end at ${c.id}'s gate`);
}
need("road_to_nearest_crater", Math.min(...craterC.map((c) => gap(c, roadR))), MIN.road_to_crater);
need("road_to_nearest_barricade", Math.min(...barrR.map((b) => gap(b, roadR))), MIN.road_to_barricade);
need("road_to_nearest_cover_zone", Math.min(...coverR.map((c) => gap(c, roadR))), MIN.road_to_cover);
// gate-to-gate clear line: sample the road at avatar (2) and ram (12, placeholder) half widths
for (const hw of [2, 6, ROAD.width / 2]) for (let x = road.min_x; x <= road.max_x; x += 2) for (const dz of [-hw, 0, hw]) {
  for (const o of [...craterC, ...barrR, ...coverR, ...pads.filter((p) => p.kind === "circle")])
    if (distTo(o, x, dz) === 0) { problems.push(`road blocked by ${o.id} at x ${r1(x)}`); x = 1e9; break; }
}
// craters, barricades, cover vs pads and each other
need("crater_to_nearest_pad", Math.min(...craterC.flatMap((c) => pads.map((p) => gap(c, p)))), MIN.crater_to_pad);
need("barricade_to_nearest_pad", Math.min(...barrR.flatMap((b) => pads.map((p) => gap(b, p)))), MIN.crater_to_pad);
need("cover_to_nearest_pad", Math.min(...coverR.flatMap((c) => pads.map((p) => gap(c, p)))), MIN.cover_to_pad);
need("crater_to_nearest_cover_or_barricade", Math.min(...craterC.flatMap((c) => [...coverR, ...barrR].map((o) => gap(c, o)))), 5);
for (const c of coverR) for (const o of coverR) if (c !== o && gap(c, o) === 0) problems.push(`cover ${c.id} overlaps ${o.id}`);
// crater profile: rim high enough to shelter a crouched avatar (Roblox R15 crouch eye ~2.5 above feet)
report.crater_floor_to_rim = CRATER.floor_depth + CRATER.rim_height;
if (CRATER.floor_depth + CRATER.rim_height < 2.5) problems.push("crater floor-to-rim is under a crouched avatar's eye height");
report.crater_wall_slope_deg = r1(Math.atan((CRATER.floor_depth + CRATER.rim_height) / (CRATER.outer_radius - CRATER.floor_radius) * 2) * 180 / Math.PI);
if (BARRICADE.height < 3 || BARRICADE.height > 5) problems.push("barricade height is outside crouch-cover range 3-5");
// tunnels: an L, legs as approved, entrance outside the walls and in its cover, exit inside the courtyard
for (const t of tunnels) {
  const c = castles.find((q) => q.team === t.team);
  const sign = Math.sign(c.gate_facing.x);
  if (t.entrance.z !== t.bend.z || t.bend.x !== t.exit.x) problems.push(`${t.id} is not an L`);
  if (t.outer_leg !== 175 || t.inner_leg !== 65) problems.push(`${t.id} legs ${t.outer_leg}/${t.inner_leg}, not 175/65`);
  if (t.outer_leg <= t.inner_leg) problems.push(`${t.id}: the long leg must approach the castle`);
  const cz = coverR.find((q) => q.id === t.cover_zone);
  if (!cz || distTo(cz, t.entrance.x, t.entrance.z) !== 0) problems.push(`${t.id} entrance is not inside ${t.cover_zone}`);
  const padRect = pads.find((p) => p.id === c.id);
  need(`${t.id}_entrance_to_nearest_pad`, Math.min(...pads.map((p) => distTo(p, t.entrance.x, t.entrance.z))) - t.width / 2, MIN.tunnel_portal_to_pad);
  if (distTo(padRect, t.bend.x, t.bend.z) === 0) problems.push(`${t.id} bend is under the castle pad (should be outside the walls)`);
  const lx = (t.exit.x - c.center.x) * sign, lz = t.exit.z - c.center.z;
  need(`${t.id}_exit_to_inner_wall`, Math.min(INNER - Math.abs(lx), INNER - Math.abs(lz)) - t.width / 2, MIN.tunnel_exit_to_wall);
  if (!(lx > 0 && lz < 0)) problems.push(`${t.id} exit is not in the north/front courtyard quadrant`);
  if (Math.abs(t.exit.x - c.tunnel_exit.x) > 1e-6 || t.exit.z !== c.tunnel_exit.z) problems.push(`${t.id} exit disagrees with ${c.id}.tunnel_exit`);
  report[`${t.id}_exit_to_rear_half_line`] = r1(lx);
  // the outer leg runs under open field: report how close it passes to node pads
  let closest = Infinity;
  for (let x = Math.min(t.entrance.x, t.bend.x); x <= Math.max(t.entrance.x, t.bend.x); x += 1)
    for (const p of pads.filter((q) => q.kind === "circle")) closest = Math.min(closest, distTo(p, x, t.entrance.z));
  report[`${t.id}_outer_leg_to_nearest_node_pad`] = r1(closest - t.width / 2);
  // temporary spawns: inside the courtyard, out of the rear half, away from the exit
  for (const s of c.temporary_preview_spawns) {
    const sf = (s.x - c.center.x) * sign, sz = s.z - c.center.z;
    if (Math.abs(sf) > INNER - 4 || Math.abs(sz) > INNER - 4) problems.push(`${s.id} is not inside the courtyard`);
    if (sf <= 0) problems.push(`${s.id} is in the reserved rear half`);
    if (Math.hypot(s.x - t.exit.x, s.z - t.exit.z) < 60) problems.push(`${s.id} is within 60 of the tunnel exit`);
  }
}
// bounds
for (const p of [...pads, ...coverR, ...craterC]) {
  const [x0, x1, z0, z1] = p.kind === "circle" ? [p.x - p.r, p.x + p.r, p.z - p.r, p.z + p.r] : [p.min_x, p.max_x, p.min_z, p.max_z];
  if (x0 < BOUNDS.min_x || x1 > BOUNDS.max_x || z0 < BOUNDS.min_z || z1 > BOUNDS.max_z) problems.push(`${p.id} leaves map_bounds`);
}
// mirror: every slot / feature's twin at (-x, z), same size and height
for (const s of slots) {
  const m = slots.find((o) => o.id === s.mirror_pair);
  if (!m || m.position.x !== -s.position.x || m.position.z !== s.position.z || m.position.y !== s.position.y
      || m.allowed_types.join() !== s.allowed_types.join() || m.pad_radius !== s.pad_radius) problems.push(`slot ${s.id} is not mirrored`);
}
const twin = (list, o) => list.find((q) => q.id === swapAB(o.id));
for (const list of [craters, barricades]) for (const o of list.filter((q) => q.id.startsWith("A_"))) {
  const m = twin(list, o);
  if (!m || m.x !== -o.x || m.z !== o.z || JSON.stringify({ ...m, id: 0, x: 0 }) !== JSON.stringify({ ...o, id: 0, x: 0 })) problems.push(`${o.id} is not mirrored`);
}
for (const o of cover.filter((q) => q.id.startsWith("A_"))) {
  const m = twin(cover, o);
  if (!m || m.min_x !== -o.max_x || m.max_x !== -o.min_x || m.min_z !== o.min_z || m.max_z !== o.max_z) problems.push(`${o.id} is not mirrored`);
}
const [tA, tB] = tunnels;
for (const k of ["entrance", "bend", "exit"]) if (tB[k].x !== -tA[k].x || tB[k].z !== tA[k].z) problems.push(`tunnel ${k} is not mirrored`);
const castleItems = (c) => [...c.wall_sections, ...c.towers, ...c.temporary_preview_spawns, c.tunnel_exit, { ...c.gate, id: c.gate.id }];
for (const a of castleItems(cA)) {
  const b = castleItems(cB).find((p) => p.id === swapAB(a.id));
  if (!b || b.x !== -a.x || b.z !== a.z || b.y !== a.y) problems.push(`castle item ${a.id} is not mirrored`);
}
if (cA.center.x !== -cB.center.x || cA.pad.size !== cB.pad.size) problems.push("castles are not mirrored");
if (road.min_x !== -road.max_x) problems.push("road is not centred on the mirror axis");
// counts and ids
for (const c of castles) {
  if (c.wall_sections.length !== 4 * BAYS - 1) problems.push(`${c.id} has ${c.wall_sections.length} wall sections, not ${4 * BAYS - 1}`);
  if (c.towers.length !== 4) problems.push(`${c.id} has ${c.towers.length} towers`);
}
if (slots.length !== 16) problems.push(`${slots.length} node slots, not 16`);
const ids = new Set();
for (const o of [...castles.flatMap(castleItems), ...slots, ...craters, ...barricades, ...cover, ...tunnels]) {
  if (ids.has(o.id)) problems.push(`duplicate id ${o.id}`);
  ids.add(o.id);
}
// slopes between neighbouring pads (edge to edge)
let steepest = 0, steepPair = null;
for (let i = 0; i < pads.length; i++) for (let j = i + 1; j < pads.length; j++) {
  const g = Math.max(1, gap(pads[i], pads[j]));
  const deg = Math.atan(Math.abs(pads[i].y - pads[j].y) / g) * 180 / Math.PI;
  if (deg > steepest) { steepest = deg; steepPair = [pads[i].id, pads[j].id]; }
}

const t = (x, z) => r1(Math.hypot(x - cA.gate.x, z - cA.gate.z) / WALK);
const travel = {
  gate_to_enemy_gate_s: r1((cB.gate.x - cA.gate.x) / WALK),
  gate_to_center_s: t(0, 0),
  per_slot_from_A_gate_s: Object.fromEntries(slots.filter((s) => s.side !== "B").map((s) => [s.id, t(s.position.x, s.position.z)])),
};
const counts = {};
for (const s of slots) for (const ty of s.allowed_types) counts[ty] = (counts[ty] || 0) + 1;
console.log(JSON.stringify({ problems, clearances: report, steepest_pad_to_pad_deg: r1(steepest), steepest_between: steepPair,
  castle_width_to_gate_gap: r1(RING / (cB.gate.x - cA.gate.x)), travel, slots: slots.length, slots_allowing_type: counts,
  wall_sections_per_castle: cA.wall_sections.length, ids: ids.size }, null, 1));
if (out) {
  if (problems.length) { console.error("not written: fix the problems first"); process.exit(1); }
  fs.writeFileSync(out, JSON.stringify(layout, null, 2) + "\n");
}
