// Generates the mirrored battlefield layout (layout.json v2.2, the exterior from
// MAP-PATHS-EXPANSION-PROPOSAL.md and the approved interior from
// CASTLE-INTERIOR-V2-PROPOSAL.md) and checks it:
// pad gaps, both ram paths clear, crater/barricade/cover clearances, the L tunnels,
// pads inside bounds, exact mirroring, steepest pad-to-pad ramp, walking times.
// Team A is authored on the west (x < 0); team B is its mirror across x = 0.
// Roblox coordinates: ground plane (x, z), height y. Studs. -Z is north.
//
//   node assets/map/propose_layout.js              check only, prints the report
//   node assets/map/propose_layout.js layout.json  also writes the file
//
// The interior below is approved spatial data for both castles. It does not imply that
// the old 2026-09-30 workshop/cannon gameplay or meshes are approved for this layout.
const fs = require("fs");
const out = process.argv[2];

const WALK = 16; // Roblox default WalkSpeed; the code never changes it
const BAY = 20.4; // castle kit wall bay
const BAYS = 9; // per side
const RING = BAYS * BAY; // 183.6, outer face to outer face
const WALL_T = 4.0; // castle kit wall thickness
const PAD_MARGIN = 8.2; // pad edge beyond the ring: 200 x 200 pad
const ROUTE_WIDTH = 18;
const EDGE_BELT = 60;
const BOUNDS = { min_x: -780, max_x: 780, min_z: -340, max_z: 340 };
const BOUNDARY_OFFSET = 30; // invisible wall this far outside map_bounds
const FIELD_Y = 4;
// Largest measured footprint per type on the old map, rounded (layout.old-island.json).
const FOOTPRINT = { Wood: 100, Wool: 117, Grain: 65, Stone: 85, Ore: 72 };
const NODE_MARGIN = 8;
const padRadius = (types) => Math.max(...types.map((t) => FOOTPRINT[t])) / 2 + NODE_MARGIN;

// Minimum clearances the checks enforce. The proposal's own audit measured the closest
// pads at 11.9 (node-node) and 9.9 (node-castle) and accepted them, so the pad rule is
// "a ramp's width apart", not the older 20.
const MIN = { pad_gap: 8, route_to_pad: 40, route_to_crater: 15, route_to_barricade: 20, route_to_cover: 10,
  crater_to_pad: 20, cover_to_pad: 0, tunnel_portal_to_pad: 10, tunnel_exit_to_wall: 10 };

const castleA = { id: "Castle_A", team: "A", center: { x: -420, y: 10, z: 0 } };
// Home: behind and beside the castle. Mid: flanks. Forward: toward the axis. Center: ON
// the axis, so each mirrors onto itself (shared, contested). Their positions
// preserve gathering on both sides of the two clear ram routes.
const slotsA = [
  { n: 1, ring: "home", types: ["Wood", "Grain"], x: -560, z: -190, y: 9 },
  { n: 2, ring: "home", types: ["Wool", "Grain"], x: -560, z: 195, y: 9 },
  { n: 3, ring: "mid", types: ["Stone", "Wood"], x: -390, z: -190, y: 8 },
  { n: 4, ring: "mid", types: ["Stone", "Wool"], x: -400, z: 185, y: 8 },
  { n: 5, ring: "mid", types: ["Stone", "Grain"], x: -250, z: 135, y: 6 },
  { n: 6, ring: "forward", types: ["Ore", "Stone"], x: -190, z: -235, y: 6 },
  { n: 7, ring: "forward", types: ["Ore", "Wood"], x: -185, z: 245, y: 6 },
];
const center = [
  { id: "Node_C1", ring: "center", types: ["Ore"], x: 0, z: -140, y: 4 },
  { id: "Node_C2", ring: "center", types: ["Ore"], x: 0, z: 140, y: 4 },
];
// Team A's battlefield features; B mirrors them.
const CRATERS_A = [{ n: 1, x: -105, z: 0 }];
const CRATER = { outer_radius: 18, floor_radius: 9, floor_depth: 1.5, rim_height: 1.5 };
const BARRICADES_A = [{ n: "Outer", x: -155, z: 0 }, { n: "Inner", x: -45, z: 0 }];
const BARRICADE = { length_x: 12, depth_z: 4, height: 3.5 };
const COVER_A = [
  { id: "A_Cover_N", purpose: "gate-side cover north of the north ram route", min_x: -317, max_x: -272, min_z: -68, max_z: -40 },
  { id: "A_Cover_S", purpose: "gate-side cover south of the south ram route", min_x: -317, max_x: -272, min_z: 40, max_z: 68 },
  { id: "A_Cover_Tunnel", purpose: "hides the tunnel entrance", min_x: -245, max_x: -205, min_z: -138, max_z: -102 },
];
const TUNNEL_A = { entrance: { x: -225, z: -120 }, bend: { x: -400, z: -120 }, exit: { x: -400, z: -55 } };
const TUNNEL = { width: 6, clear_height: 3.5, one_traveller: true };
const BARRACKS_SPAWNS = [[-60, -66], [-50, -66], [-40, -66], [-60, -57], [-50, -57], [-40, -57]];

const mirror = (p) => ({ ...p, x: -p.x });
const r1 = (v) => Math.round(v * 10) / 10;
const swapAB = (id) => id.replace(/^A_/, "B_").replace(/_A(\d)/, "_B$1");

// ---------------------------------------------------------------- castles and approved spatial interior
// Authored in castle-local "forward" coordinates: f points from the castle centre toward
// its gate, z is world z. World x = centre.x + sign * f, so B (sign -1) mirrors A exactly.
const HALF = RING / 2; // 91.8: outer face
const WALL_LINE = HALF - WALL_T / 2; // 89.8: wall centre line
const INNER = HALF - WALL_T; // 87.8: inner face

function castle(c, sign) {
  const cx = c.center.x, y = c.center.y;
  const W = (f, z) => ({ x: r1(cx + sign * f), y, z: r1(z) });
  const T = c.team;
  const P = (id, f, z, extra = {}) => ({ id: `${T}_${id}`, ...W(f, z), ...extra });
  const R = (id, f0, f1, z0, z1) => {
    const x0 = W(f0, z0).x, x1 = W(f1, z1).x;
    return { id: `${T}_${id}`, min_x: Math.min(x0, x1), max_x: Math.max(x0, x1),
      min_z: z0, max_z: z1, y };
  };
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
  const interior = {
    status: "APPROVED 2026-10-01 (CASTLE-INTERIOR-V2-PROPOSAL.md); geometry only. Gameplay values and final art remain open.",
    coordinate_frame: "World Roblox studs. Local f increases toward this castle's gate; Team B mirrors Team A across x = 0.",
    keep: {
      ...R("Keep", -76, -32, -22, 22),
      front_door: P("Keep_FrontDoor", -32, 0, { clear_width: 10 }),
      entrance_hall: R("Keep_EntranceHall", -72, -32, -6, 6),
      stockpile_room: {
        ...R("Stockpile_Room", -72, -54, 6, 18),
        door: P("Stockpile_Room_Door", -63, 6, { clear_width: 8 }),
        interaction: P("Stockpile_Interaction", -63, 12),
      },
    },
    barracks: { ...R("Barracks", -70, -28, -75, -48),
      door: P("Barracks_Door", -49, -48, { clear_width: 10 }) },
    specialists: [
      { role: "Blacksmith", ...R("Blacksmith_Forge", -12, 16, 47, 75),
        door: P("Blacksmith_Door", 2, 47, { clear_width: 8 }) },
      { role: "Alchemist", ...R("Alchemist", -18, 6, -76, -50),
        door: P("Alchemist_Door", -6, -50, { clear_width: 8 }) },
      { role: "Fletcher", ...R("Fletcher", 41, 66, -76, -50),
        door: P("Fletcher_Door", 53.5, -50, { clear_width: 8 }) },
      { role: "Carpenter", ...R("Carpenter", 31, 55, 46, 74),
        door: P("Carpenter_Door", 43, 46, { clear_width: 8 }),
        ram_opening: P("Carpenter_RamOpening", 55, 60, { clear_width: 12 }) },
    ],
    spawn_points: BARRACKS_SPAWNS.map(([f, z], i) => P(`Barracks_Spawn_${i + 1}`, f, z)),
    surfaces: {
      blacksmith_forecourt: R("Blacksmith_Forecourt", -17, 21, 28, 47),
    },
    clear_areas: {
      main_gate_to_keep: R("MainRoute", -32, INNER, -9, 9),
      tunnel_landing: R("TunnelLanding", 14, 26, -61, -49),
      tunnel_egress: R("TunnelEgress", 14, 26, -49, -9),
      ram_assembly_pad: R("RamAssemblyPad", 57, 77, 44, 64),
      ram_turning_area: R("RamTurningArea", 57, 82, 9, 44),
      keep_front_circulation: R("KeepFrontCirculation", -30, -18, -48, 47),
      open_south_rear_courtyard: R("OpenSouthRearCourtyard", -76, -48, 43, 69),
    },
    tower_access: [P("Tower_Access_RN", -80, -80), P("Tower_Access_RS", -80, 80),
      P("Tower_Access_FN", 80, -80), P("Tower_Access_FS", 80, 80)],
    ballista_mount: { ...P("Gatehouse_Ballista_Mount", HALF, 0), y: r1(y + 21.4),
      height_note: "Gatehouse-roof mount height is an art placeholder; verify against the final gate mesh.",
      aim: { x: sign, z: 0 }, access: P("Gatehouse_Ballista_Access", 79, -23) },
  };
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
      note: "The Keep and its internal stockpile room occupy the approved rear part of the courtyard." },
    interior,
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
const routePoints = (sign) => [
  { x: cA.gate.x, z: 0 }, { x: -260, z: sign * 20 }, { x: -180, z: sign * 42 },
  { x: 180, z: sign * 42 }, { x: 260, z: sign * 20 }, { x: cB.gate.x, z: 0 },
];
const routes = [["North", -1], ["South", 1]].map(([name, sign]) => ({
  id: `${name}_Ram_Route`, surface: "worn_earth_and_stone", width: ROUTE_WIDTH,
  centerline: routePoints(sign),
  note: "18-stud collision-clear route from gate to gate. Stone and dirt color can vary within the route; no props, nodes, trees or grass tall enough to obstruct a ram.",
}));
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
    status: "Expanded exterior and paired ram routes approved 2026-10-03 (MAP-PATHS-EXPANSION-PROPOSAL.md); interior geometry approved 2026-10-01 (CASTLE-INTERIOR-V2-PROPOSAL.md). Subject to in-game review.",
    interior_status: "APPROVED SPATIAL LAYOUT 2026-10-01. The Keep contains the stockpile room. The 2026-09-30 workshop/cannon interior and gameplay are stale; approved coordinates do not imply the new art or logic is built.",
    version: "2.2", date: "2026-10-03", units: "studs",
    coords: "Roblox: ground plane (x, z), height y. Blender: (x, y, z) -> (x, -z, y).",
    compass: "-Z = north, +X = east. Team A west, team B east.",
    generator: "assets/map/propose_layout.js",
    replaces: "layout.json v2.1 (2026-10-01: 1,040-stud island, castles at x = ±280, one 30-stud road). Older: layout.old-island.json.",
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
  ram_routes: routes,
  resource_node_slots: slots,
  node_footprints: FOOTPRINT,
  craters,
  barricades,
  cover_zones: cover,
  tunnels,
  decoration_rules: { edge_belt_depth: EDGE_BELT, pines_only_in: ["edge belt", "cover_zones"], round_canopy_trees: "Wood node pads only",
    never_in: ["ram_routes", "pads", "craters", "barricades"] },
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
const craterC = craters.map((c) => circ(c.id, c.x, c.z, c.outer_radius));
const barrR = barricades.map((b) => rect({ min_x: b.x - b.length_x / 2, max_x: b.x + b.length_x / 2, min_z: b.z - b.depth_z / 2, max_z: b.z + b.depth_z / 2 }, b.id));
const coverR = cover.map((c) => rect(c));
const routeSamples = (route) => route.centerline.slice(1).flatMap((b, i) => {
  const a = route.centerline[i], n = Math.ceil(Math.hypot(b.x - a.x, b.z - a.z));
  return [...Array(n + 1).keys()].map((k) => ({ x: a.x + (b.x - a.x) * k / n, z: a.z + (b.z - a.z) * k / n }));
});
const routeGap = (route, shape) => Math.min(...routeSamples(route).map((p) => distTo(shape, p.x, p.z))) - route.width / 2;
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
// Each path must carry a ram, stay clear of resources/cover, and end at both gates.
for (const route of routes) {
  if (route.width < 18) problems.push(`${route.id} is narrower than the approved 18-stud corridor`);
  const first = route.centerline[0], last = route.centerline.at(-1);
  if (first.x !== cA.gate.x || first.z !== cA.gate.z || last.x !== cB.gate.x || last.z !== cB.gate.z)
    problems.push(`${route.id} does not join both facing gates`);
  need(`${route.id}_to_nearest_node_pad`, Math.min(...pads.filter((p) => p.kind === "circle").map((p) => routeGap(route, p))), MIN.route_to_pad);
  need(`${route.id}_to_nearest_crater`, Math.min(...craterC.map((c) => routeGap(route, c))), MIN.route_to_crater);
  need(`${route.id}_to_nearest_barricade`, Math.min(...barrR.map((b) => routeGap(route, b))), MIN.route_to_barricade);
  need(`${route.id}_to_nearest_cover_zone`, Math.min(...coverR.map((c) => routeGap(route, c))), MIN.route_to_cover);
  report[`${route.id}_length`] = r1(route.centerline.slice(1).reduce((sum, p, i) =>
    sum + Math.hypot(p.x - route.centerline[i].x, p.z - route.centerline[i].z), 0));
}
if (routes.length !== 2 || routes[0].centerline.length !== routes[1].centerline.length)
  problems.push("there must be two equal waypoint lists for the ram routes");
else for (let i = 0; i < routes[0].centerline.length; i++) {
  const n = routes[0].centerline[i], s = routes[1].centerline[i];
  if (n.x !== s.x || n.z !== -s.z) problems.push(`ram routes diverge asymmetrically at waypoint ${i}`);
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
}
// Approved interior: every building fits, nested stockpile can be reached through the
// Keep hall, preview spawns are retired, and the reserved fighting paths stay open.
const containsPoint = (r, p) => p.x >= r.min_x && p.x <= r.max_x && p.z >= r.min_z && p.z <= r.max_z;
const containsRect = (outer, inner) => inner.min_x >= outer.min_x && inner.max_x <= outer.max_x
  && inner.min_z >= outer.min_z && inner.max_z <= outer.max_z;
const overlaps = (a, b) => Math.min(a.max_x, b.max_x) > Math.max(a.min_x, b.min_x)
  && Math.min(a.max_z, b.max_z) > Math.max(a.min_z, b.min_z);
const onEdge = (r, p) => containsPoint(r, p)
  && (p.x === r.min_x || p.x === r.max_x || p.z === r.min_z || p.z === r.max_z);
const interiorRects = (c) => {
  const i = c.interior;
  return [i.keep, i.keep.entrance_hall, i.keep.stockpile_room, i.barracks,
    ...i.specialists, ...Object.values(i.surfaces), ...Object.values(i.clear_areas)];
};
const interiorPoints = (c) => {
  const i = c.interior;
  return [i.keep.front_door, i.keep.stockpile_room.door, i.keep.stockpile_room.interaction,
    i.barracks.door, ...i.specialists.flatMap((s) => [s.door, ...(s.ram_opening ? [s.ram_opening] : [])]),
    ...i.spawn_points, ...i.tower_access, i.ballista_mount, i.ballista_mount.access];
};
for (const c of castles) {
  const i = c.interior, k = i.keep, s = k.stockpile_room, a = i.clear_areas;
  const castleInner = { min_x: c.center.x - INNER, max_x: c.center.x + INNER, min_z: -INNER, max_z: INNER };
  const buildings = [k, i.barracks, ...i.specialists];
  const forecourt = i.surfaces.blacksmith_forecourt;
  if (!containsRect(castleInner, forecourt)) problems.push(`${forecourt.id} exceeds inner wall face`);
  for (const b of buildings.filter((item) => item.role !== "Blacksmith"))
    if (overlaps(b, forecourt)) problems.push(`${forecourt.id} overlaps ${b.id}`);
  for (const route of Object.values(a))
    if (overlaps(route, forecourt)) problems.push(`${forecourt.id} blocks ${route.id}`);
  for (const b of buildings) if (!containsRect(castleInner, b)) problems.push(`${b.id} exceeds inner wall face`);
  for (let j = 0; j < buildings.length; j++) for (let h = j + 1; h < buildings.length; h++)
    if (overlaps(buildings[j], buildings[h])) problems.push(`${buildings[j].id} overlaps ${buildings[h].id}`);
  if (!containsRect(k, s) || !containsRect(k, k.entrance_hall)) problems.push(`${k.id} does not contain its stockpile room and entrance hall`);
  if (!containsPoint(s, s.interaction) || !containsPoint(s, s.door)) problems.push(`${s.id} interaction or door lies outside the room`);
  if (!containsPoint(k.entrance_hall, s.door) || !containsPoint(k.entrance_hall, k.front_door))
    problems.push(`${k.id} hall does not connect front and stockpile doors`);
  for (const [r, p] of [[k, k.front_door], [s, s.door], [i.barracks, i.barracks.door],
      ...i.specialists.flatMap((b) => [[b, b.door], ...(b.ram_opening ? [[b, b.ram_opening]] : [])])])
    if (!onEdge(r, p)) problems.push(`${p.id} is not on the edge of ${r.id}`);
  if (i.spawn_points.length !== 6) problems.push(`${c.id} needs six provisional barracks spawns`);
  for (const p of i.spawn_points) if (!containsPoint(i.barracks, p)) problems.push(`${p.id} lies outside barracks`);
  for (const b of buildings) for (const route of [a.main_gate_to_keep, a.tunnel_landing, a.tunnel_egress,
      a.ram_assembly_pad, a.ram_turning_area, a.keep_front_circulation, a.open_south_rear_courtyard])
    if (overlaps(b, route)) problems.push(`${b.id} blocks ${route.id}`);
  const d = Math.hypot(c.tunnel_exit.x - k.front_door.x, c.tunnel_exit.z - k.front_door.z);
  need(`${c.id}_tunnel_exit_to_keep_door`, d, 60);
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
const castleItems = (c) => [...c.wall_sections, ...c.towers, ...interiorPoints(c), c.tunnel_exit, { ...c.gate, id: c.gate.id }];
for (const a of castleItems(cA)) {
  const b = castleItems(cB).find((p) => p.id === swapAB(a.id));
  if (!b || b.x !== -a.x || b.z !== a.z || b.y !== a.y) problems.push(`castle item ${a.id} is not mirrored`);
}
for (const a of interiorRects(cA)) {
  const b = interiorRects(cB).find((r) => r.id === swapAB(a.id));
  if (!b || b.min_x !== -a.max_x || b.max_x !== -a.min_x || b.min_z !== a.min_z
      || b.max_z !== a.max_z || b.y !== a.y) problems.push(`interior footprint ${a.id} is not mirrored`);
}
if (cA.center.x !== -cB.center.x || cA.pad.size !== cB.pad.size) problems.push("castles are not mirrored");
for (const route of routes) {
  const pts = route.centerline;
  for (let i = 0; i < pts.length; i++)
    if (pts[i].x !== -pts[pts.length - 1 - i].x || pts[i].z !== pts[pts.length - 1 - i].z)
      problems.push(`${route.id} is not mirrored across x = 0`);
}
// counts and ids
for (const c of castles) {
  if (c.wall_sections.length !== 4 * BAYS - 1) problems.push(`${c.id} has ${c.wall_sections.length} wall sections, not ${4 * BAYS - 1}`);
  if (c.towers.length !== 4) problems.push(`${c.id} has ${c.towers.length} towers`);
}
if (slots.length !== 16) problems.push(`${slots.length} node slots, not 16`);
const ids = new Set();
for (const o of [...castles.flatMap(castleItems), ...castles.flatMap(interiorRects), ...slots, ...craters, ...barricades, ...cover, ...tunnels]) {
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
  ram_route_s_at_walk_speed: r1(report[`${routes[0].id}_length`] / WALK),
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
