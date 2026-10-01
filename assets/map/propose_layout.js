// Generates the two-castle mirrored layout (layout.json, approved 2026-09-30)
// and checks it: pad overlaps, lanes clear, cover clear, pads inside bounds,
// exact mirroring, steepest pad-to-pad ramp, walking times.
// Team A is authored on the west (x < 0); team B is its mirror across x = 0.
// Roblox coordinates: ground plane (x, z), height y. Studs.
//
//   node assets/map/propose_layout.js              check only, prints the report
//   node assets/map/propose_layout.js layout.json  also writes the file
//
// Edit the numbers below, run it, and only write layout.json once the report
// shows no problems and the change has been approved (CLAUDE.md §6.2).
const fs = require("fs");
const out = process.argv[2];

const WALK = 16; // Roblox default WalkSpeed; the code never changes it
const RING = 5 * 20.4; // castle wall ring, outer, square: exactly 5 of the code's 20.4-stud wall blocks per side
const PAD_MARGIN = 8;
const LANE = { width: 30, length: 80 };
const EDGE_BELT = 60;
const BOUNDS = { min_x: -520, max_x: 520, min_z: -340, max_z: 340 };
const BOUNDARY_OFFSET = 30; // invisible wall this far outside map_bounds
// Largest measured footprint per type on the old map, rounded (layout.json, old island).
const FOOTPRINT = { Wood: 100, Wool: 117, Grain: 65, Stone: 85, Ore: 72 };
const padRadius = (types) => Math.max(...types.map((t) => FOOTPRINT[t])) / 2 + PAD_MARGIN;

const castleA = { id: "Castle_A", team: "A", center: { x: -370, y: 10, z: 0 } };
// Home: behind and beside the castle. Mid: flanks toward the middle. Forward: near
// the axis. Center: ON the axis, so each mirrors onto itself (shared, contested).
const slotsA = [
  { n: 1, ring: "home", types: ["Wood", "Grain"], x: -420, z: -190, y: 9 },
  { n: 2, ring: "home", types: ["Wool", "Grain"], x: -420, z: 195, y: 9 },
  { n: 3, ring: "mid", types: ["Stone", "Wood"], x: -250, z: -190, y: 8 },
  { n: 4, ring: "mid", types: ["Stone", "Wool"], x: -260, z: 185, y: 8 },
  { n: 5, ring: "mid", types: ["Stone", "Grain"], x: -170, z: 0, y: 6 },
  { n: 6, ring: "forward", types: ["Ore", "Stone"], x: -120, z: -235, y: 6 },
  { n: 7, ring: "forward", types: ["Ore", "Wood"], x: -115, z: 245, y: 6 },
];
const center = [
  { id: "Node_C1", ring: "center", types: ["Ore"], x: 0, z: -110, y: 4 },
  { id: "Node_C2", ring: "center", types: ["Ore"], x: 0, z: 110, y: 4 },
];

const mirror = (p) => ({ ...p, x: -p.x });
const r1 = (v) => Math.round(v * 10) / 10;

// ---------------------------------------------------------------- castles
// The interior is authored in castle-local "forward" coordinates: f points from the
// castle centre toward its gate, z is the world z. World x = centre.x + sign * f, so
// team B's castle (sign -1) is an exact mirror of A's.
const WALL_T = 4.0;                                        // castle kit wall thickness
const INNER = RING / 2 - WALL_T;                           // 47: inner face of the walls
const WALL_LINE = RING / 2 - WALL_T / 2;                   // 49: wall centre line
const TOWER_CLEAR = 9.0;                                   // corner tower footprint radius (base flare + upper drum)
const BAY = 20.4;
// rectangles as { f0, f1, z0, z1 }
const KEEP = { f0: -45, f1: -21, z0: -14, z1: 14, height: 26 };            // king's keep, door on its gate side
const STORAGE = { f0: -41, f1: -27, z0: -10, z1: 10 };                     // king's storage room inside the keep
const BARRACKS = { f0: -10, f1: 22, z0: -44, z1: -30, height: 12 };        // north side, door facing the courtyard
const WORKSHOP = { f0: -10, f1: 20, z0: 30, z1: 44, height: 11 };          // south side, door facing the courtyard
const GATE_INNER_F = WALL_LINE - 5;                                        // gatehouse inner face (half depth 5)

function castle(c, sign) {
  const half = RING / 2;
  const cx = c.center.x, y = c.center.y;
  const W = (f, z) => ({ x: cx + sign * f, y, z });                       // local -> world
  const rect = (r) => {                                                    // local rect -> world rect
    const xs = [cx + sign * r.f0, cx + sign * r.f1].sort((a, b) => a - b);
    return { min_x: xs[0], max_x: xs[1], min_z: r.z0, max_z: r.z1 };
  };
  const gate = W(half, 0);
  const facing = { x: sign, z: 0 };
  // the king's storage is the stockpile: its centre is where loot is taken
  const stockpile = W((STORAGE.f0 + STORAGE.f1) / 2, 0);
  const spawns = [];
  for (const f of [-4, 6, 16]) for (const z of [-40, -35]) spawns.push(W(f, z));   // inside the barracks
  const T = c.team;
  // 19 wall sections: 5 a side, minus the gate bay. F = front (gate side), R = rear,
  // N = north (-z), S = south (+z). Numbered along +z (F, R) or +f (N, S).
  const sections = [];
  const along = [-2, -1, 0, 1, 2].map((k) => k * BAY);
  along.forEach((t, k) => { if (k !== 2) sections.push({ id: `${T}_Wall_F${k + 1}`, ...W(WALL_LINE, t), facing: { x: sign, z: 0 } }); });
  along.forEach((t, k) => sections.push({ id: `${T}_Wall_R${k + 1}`, ...W(-WALL_LINE, t), facing: { x: -sign, z: 0 } }));
  along.forEach((t, k) => sections.push({ id: `${T}_Wall_N${k + 1}`, ...W(t, -WALL_LINE), facing: { x: 0, z: -1 } }));
  along.forEach((t, k) => sections.push({ id: `${T}_Wall_S${k + 1}`, ...W(t, WALL_LINE), facing: { x: 0, z: 1 } }));
  // front towers face the enemy and are open gun platforms; the rear ones keep their cones
  const towers = [
    { id: `${T}_Tower_FN`, kind: "gun", ...W(WALL_LINE, -WALL_LINE) },
    { id: `${T}_Tower_FS`, kind: "gun", ...W(WALL_LINE, WALL_LINE) },
    { id: `${T}_Tower_RN`, kind: "roofed", ...W(-WALL_LINE, -WALL_LINE) },
    { id: `${T}_Tower_RS`, kind: "roofed", ...W(-WALL_LINE, WALL_LINE) },
  ];
  const cannons = [
    { id: `${T}_Cannon_TowerN`, on: `${T}_Tower_FN`, ...W(WALL_LINE, -WALL_LINE), height: 27.6, aim: facing },
    { id: `${T}_Cannon_TowerS`, on: `${T}_Tower_FS`, ...W(WALL_LINE, WALL_LINE), height: 27.6, aim: facing },
    { id: `${T}_Cannon_GateN`, on: `${T}_Gate`, ...W(WALL_LINE, -6), height: 21.4, aim: facing },
    { id: `${T}_Cannon_GateS`, on: `${T}_Gate`, ...W(WALL_LINE, 6), height: 21.4, aim: facing },
  ];
  return {
    id: c.id, team: c.team, center: c.center,
    ring_size: { x: RING, z: RING }, wall_blocks_per_side: Math.round(RING / 20.4 * 10) / 10,
    pad: { shape: "square", size: RING + 2 * PAD_MARGIN, y },
    gate: { ...gate, id: `${T}_Gate`, door_id: `${T}_Gate_Door` }, gate_facing: facing, stockpile,
    spawn_points: spawns.map((s, i) => ({ id: `${T}_Spawn_${i + 1}`, ...s })),
    keep: { id: `${T}_Keep`, ...rect(KEEP), height: KEEP.height, door: W(KEEP.f1, 0), door_facing: facing,
            storage: { id: `${T}_King_Storage`, ...rect(STORAGE) } },
    barracks: { id: `${T}_Barracks`, ...rect(BARRACKS), height: BARRACKS.height, door: W(4, BARRACKS.z1), door_facing: { x: 0, z: 1 } },
    workshop: { id: `${T}_Workshop`, ...rect(WORKSHOP), height: WORKSHOP.height, door: W(4, WORKSHOP.z0), door_facing: { x: 0, z: -1 } },
    towers, wall_sections: sections, cannon_mounts: cannons,
  };
}
const castles = [castle(castleA, +1), castle({ ...castleA, id: "Castle_B", team: "B", center: mirror(castleA.center) }, -1)];

// ---------------------------------------------------------------- node slots
const slots = [];
for (const s of slotsA) {
  const base = { ring: s.ring, allowed_types: s.types, pad_radius: padRadius(s.types) };
  slots.push({ id: `Node_A${s.n}`, side: "A", mirror_pair: `Node_B${s.n}`, position: { x: s.x, y: s.y, z: s.z }, ...base });
  slots.push({ id: `Node_B${s.n}`, side: "B", mirror_pair: `Node_A${s.n}`, position: { x: -s.x, y: s.y, z: s.z }, ...base });
}
for (const s of center) {
  slots.push({ id: s.id, side: "shared", mirror_pair: s.id, position: { x: s.x, y: s.y, z: s.z },
    ring: s.ring, allowed_types: s.types, pad_radius: padRadius(s.types) });
}

// ---------------------------------------------------------------- lanes and cover
const lanes = castles.map((c) => ({
  id: `${c.team}_Lane`, castle: c.id, from: { x: c.gate.x, z: c.gate.z }, direction: c.gate_facing,
  width: LANE.width, length: LANE.length,
}));
const cover = [];
for (const c of castles) {
  for (const side of [-1, 1]) {
    // 24 wide, 40 long, starting 20 along the lane, 6 studs clear of its edge
    const along0 = 20, along1 = 60, lat0 = LANE.width / 2 + 6, lat1 = lat0 + 24;
    const xs = [c.gate.x + c.gate_facing.x * along0, c.gate.x + c.gate_facing.x * along1].sort((a, b) => a - b);
    const zs = [side * lat0, side * lat1].sort((a, b) => a - b);
    cover.push({ id: `${c.team}_Cover_${side < 0 ? "N" : "S"}`, beside_lane: `${c.team}_Lane`, // -Z is north
      min_x: xs[0], max_x: xs[1], min_z: zs[0], max_z: zs[1] });
  }
}

const layout = {
  meta: {
    status: "APPROVED 2026-09-30 (proposal in LAYOUT-PROPOSAL.md). Single source of truth for map work (CLAUDE.md §6).",
    interior_status: "APPROVED 2026-09-30: castle interior (keep + king's storage, barracks, workshop, cannon mounts, wall sections, towers); proposal in the LAYOUT-PROPOSAL.md addendum.",
    version: "1.1", date: "2026-09-30", units: "studs",
    coords: "Roblox: ground plane (x, z), height y. Blender: (x, y, z) -> (x, -z, y).",
    compass: "-Z = north, +X = east. Team A west, team B east.",
    replaces: "layout.old-island.json (old 16-plot island export, reference only)",
  },
  map_bounds: { ...BOUNDS, note: "Playable area. Everything inside is land; no water inside." },
  mirror_axis: { type: "plane", x: 0, note: "Team B = team A with x negated. Slots on x = 0 mirror onto themselves." },
  boundary: {
    type: "invisible_wall", offset_outside_bounds: BOUNDARY_OFFSET, corner_radius: 120, height: 60,
    placement: "Rounded rectangle 30 studs outside map_bounds, on the beach. Coast must lie beyond it. Plus a kill volume at y = -30 as a safety net.",
  },
  teams: [{ id: "A", side: "west", castle: "Castle_A", banner_color_placeholder: "#B8413A" },
          { id: "B", side: "east", castle: "Castle_B", banner_color_placeholder: "#3A5FB8" }],
  castles,
  resource_node_slots: slots,
  node_footprints: FOOTPRINT,
  gate_approach_lanes: lanes,
  cover_zones: cover,
  decoration_rules: { edge_belt_depth: EDGE_BELT, pines_only_in: ["edge belt", "cover_zones"], round_canopy_trees: "Wood node pads only" },
  zone: null,
  zone_note: "No shrinking zone: CLAUDE.md §15 lists it as likely cut for two fixed castles. Add back only if approved.",
};

// ---------------------------------------------------------------- checks
const problems = [];
const pads = [
  ...castles.map((c) => ({ id: c.id, kind: "square", x: c.center.x, z: c.center.z, half: c.pad.size / 2, y: c.pad.y })),
  ...slots.map((s) => ({ id: s.id, kind: "circle", x: s.position.x, z: s.position.z, r: s.pad_radius, y: s.position.y })),
];
const distToPad = (p, x, z) => p.kind === "circle"
  ? Math.max(0, Math.hypot(x - p.x, z - p.z) - p.r)
  : Math.hypot(Math.max(0, Math.abs(x - p.x) - p.half), Math.max(0, Math.abs(z - p.z) - p.half));
const padGap = (a, b) => {
  // sample a's outline, distance to b
  const pts = a.kind === "circle"
    ? [...Array(64).keys()].map((k) => [a.x + Math.cos(k * Math.PI / 32) * a.r, a.z + Math.sin(k * Math.PI / 32) * a.r])
    : [...Array(64).keys()].map((k) => { const t = k / 16, s = Math.floor(t), f = t - s; const h = a.half;
        const c = [[-h, -h], [h, -h], [h, h], [-h, h]]; const p0 = c[s], p1 = c[(s + 1) % 4];
        return [a.x + p0[0] + (p1[0] - p0[0]) * f, a.z + p0[1] + (p1[1] - p0[1]) * f]; });
  return Math.min(...pts.map(([x, z]) => distToPad(b, x, z)));
};
let minGap = Infinity, minPair = null;
for (let i = 0; i < pads.length; i++) for (let j = i + 1; j < pads.length; j++) {
  const g = Math.min(padGap(pads[i], pads[j]), padGap(pads[j], pads[i]));
  if (g < minGap) { minGap = g; minPair = [pads[i].id, pads[j].id]; }
  if (g < 20) problems.push(`pads ${pads[i].id} and ${pads[j].id} only ${r1(g)} apart`);
}
const inLane = (l, x, z, grow = 0) => {
  const rx = x - l.from.x, rz = z - l.from.z;
  const along = rx * l.direction.x + rz * l.direction.z, side = -rx * l.direction.z + rz * l.direction.x;
  return along >= -grow && along <= l.length + grow && Math.abs(side) <= l.width / 2 + grow;
};
for (const l of lanes) for (const p of pads) {
  if (p.id === l.castle) continue;
  for (let a = 0; a <= l.length; a += 4) for (const sd of [-15, 0, 15]) {
    const x = l.from.x + l.direction.x * a, z = l.from.z + sd;
    if (distToPad(p, x, z) === 0) { problems.push(`lane ${l.id} crosses pad ${p.id}`); a = 1e9; break; }
  }
}
for (const c of cover) for (const p of pads) {
  for (const x of [c.min_x, (c.min_x + c.max_x) / 2, c.max_x]) for (const z of [c.min_z, c.max_z])
    if (distToPad(p, x, z) === 0) problems.push(`cover ${c.id} overlaps pad ${p.id}`);
  for (const l of lanes) if (inLane(l, (c.min_x + c.max_x) / 2, (c.min_z + c.max_z) / 2)) problems.push(`cover ${c.id} inside ${l.id}`);
}
for (const p of pads) {
  const r = p.kind === "circle" ? p.r : p.half;
  if (p.x - r < BOUNDS.min_x || p.x + r > BOUNDS.max_x || p.z - r < BOUNDS.min_z || p.z + r > BOUNDS.max_z)
    problems.push(`pad ${p.id} leaves map_bounds`);
}
// symmetry: every slot's mirror exists at (-x, z) with same types and height
for (const s of slots) {
  const m = slots.find((o) => o.id === s.mirror_pair);
  if (!m || m.position.x !== -s.position.x || m.position.z !== s.position.z || m.position.y !== s.position.y
      || m.allowed_types.join() !== s.allowed_types.join()) problems.push(`slot ${s.id} is not mirrored`);
}
// slopes between neighbouring pads (edge to edge)
let steepest = 0, steepPair = null;
for (let i = 0; i < pads.length; i++) for (let j = i + 1; j < pads.length; j++) {
  const g = Math.max(1, Math.min(padGap(pads[i], pads[j]), padGap(pads[j], pads[i])));
  const deg = Math.atan(Math.abs(pads[i].y - pads[j].y) / g) * 180 / Math.PI;
  if (deg > steepest) { steepest = deg; steepPair = [pads[i].id, pads[j].id]; }
}

// ---------------------------------------------------------------- castle interior checks (local, team A)
const interior = { keep: KEEP, barracks: BARRACKS, workshop: WORKSHOP };
const rectGap = (a, b) => Math.hypot(Math.max(0, a.f0 - b.f1, b.f0 - a.f1), Math.max(0, a.z0 - b.z1, b.z0 - a.z1));
for (const [name, r] of Object.entries(interior)) {
  if (r.f0 < -INNER || r.f1 > INNER || r.z0 < -INNER || r.z1 > INNER) problems.push(`${name} pokes through the walls`);
  for (const sf of [-1, 1]) for (const sz of [-1, 1]) {            // clear of the corner towers
    const tf = sf * WALL_LINE, tz = sz * WALL_LINE;
    const d = Math.hypot(Math.max(0, r.f0 - tf, tf - r.f1), Math.max(0, r.z0 - tz, tz - r.z1));
    if (d < TOWER_CLEAR) problems.push(`${name} is within ${r1(d)} of a corner tower`);
  }
}
const names = Object.keys(interior);
let minBuildingGap = Infinity;
for (let i = 0; i < names.length; i++) for (let j = i + 1; j < names.length; j++) {
  const g = rectGap(interior[names[i]], interior[names[j]]);
  minBuildingGap = Math.min(minBuildingGap, g);
  if (g < 4) problems.push(`${names[i]} and ${names[j]} only ${r1(g)} apart`);
}
if (!(STORAGE.f0 >= KEEP.f0 && STORAGE.f1 <= KEEP.f1 && STORAGE.z0 >= KEEP.z0 && STORAGE.z1 <= KEEP.z1)) problems.push("storage is not inside the keep");
// the way in: gatehouse inner face to the keep door, 16 wide, nothing standing in it
const passage = { f0: KEEP.f1, f1: GATE_INNER_F, z0: -8, z1: 8 };
for (const name of ["barracks", "workshop"]) if (rectGap(passage, interior[name]) === 0) problems.push(`${name} blocks the gate-to-keep passage`);
for (const c of castles) {
  const s = (v) => (v.x - c.center.x) * Math.sign(c.gate_facing.x);       // world -> local f
  for (const sp of c.spawn_points) {
    const f = s(sp);
    if (!(f > BARRACKS.f0 && f < BARRACKS.f1 && sp.z > BARRACKS.z0 && sp.z < BARRACKS.z1)) problems.push(`${sp.id} is not inside the barracks`);
  }
  if (c.wall_sections.length !== 19) problems.push(`${c.id} has ${c.wall_sections.length} wall sections, not 19`);
  if (c.towers.length !== 4 || c.cannon_mounts.length !== 4) problems.push(`${c.id} towers/cannons count is off`);
}
// mirror: every interior position of B is A's with x negated, same z and height
const swapT = (id) => id.replace(/^A_/, "B_");
const [cA, cB] = castles;
const pairs = [
  ...cA.wall_sections.map((o) => [o, cB.wall_sections.find((p) => p.id === swapT(o.id))]),
  ...cA.towers.map((o) => [o, cB.towers.find((p) => p.id === swapT(o.id))]),
  ...cA.cannon_mounts.map((o) => [o, cB.cannon_mounts.find((p) => p.id === swapT(o.id))]),
  ...cA.spawn_points.map((o) => [o, cB.spawn_points.find((p) => p.id === swapT(o.id))]),
  [cA.keep.door, cB.keep.door], [cA.barracks.door, cB.barracks.door], [cA.workshop.door, cB.workshop.door], [cA.stockpile, cB.stockpile],
];
for (const [a, b] of pairs) {
  if (!b || b.x !== -a.x || b.z !== a.z || b.y !== a.y) problems.push(`interior item ${a.id || "door/stockpile"} is not mirrored`);
}
for (const k of ["keep", "barracks", "workshop"]) {
  const a = cA[k], b = cB[k];
  if (a.min_x !== -b.max_x || a.max_x !== -b.min_x || a.min_z !== b.min_z || a.max_z !== b.max_z) problems.push(`${k} footprint is not mirrored`);
}
const ids = new Set();
for (const c of castles) for (const o of [...c.wall_sections, ...c.towers, ...c.cannon_mounts, ...c.spawn_points, c.keep, c.barracks, c.workshop]) {
  if (ids.has(o.id)) problems.push(`duplicate id ${o.id}`);
  ids.add(o.id);
}

// travel (straight line, walking)
const A = castles[0];
const t = (x, z) => r1(Math.hypot(x - A.gate.x, z - A.gate.z) / WALK);
const travel = {
  gate_to_enemy_gate_s: r1((castles[1].gate.x - A.gate.x) / WALK),
  gate_to_center_s: t(0, 0),
  per_slot_from_A_gate_s: Object.fromEntries(slots.filter((s) => s.side !== "B").map((s) => [s.id, t(s.position.x, s.position.z)])),
};
const counts = {};
for (const s of slots) for (const ty of s.allowed_types) counts[ty] = (counts[ty] || 0) + 1;

const courtyard = {
  keep_door_to_gate_studs: r1(GATE_INNER_F - KEEP.f1),
  min_building_gap: r1(minBuildingGap),
  gate_passage_width: passage.z1 - passage.z0,
  barracks_to_gate_s: r1(Math.hypot(GATE_INNER_F - 4, BARRACKS.z1) / WALK),
};
console.log(JSON.stringify({ problems, min_pad_gap: r1(minGap), min_gap_between: minPair,
  steepest_pad_to_pad_deg: r1(steepest), steepest_between: steepPair, travel, slots: slots.length,
  slots_allowing_type: counts, courtyard, ids: ids.size }, null, 1));
if (out) fs.writeFileSync(out, JSON.stringify(layout, null, 2) + "\n");
