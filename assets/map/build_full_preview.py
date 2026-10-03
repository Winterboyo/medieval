"""Build a composed battlefield preview from the approved map and castle builders.

This is a Blender review scene, not an FBX export. It keeps terrain, cover, and
the exact two mirrored castle assemblies in one view, so art is judged at the
same scale and coordinates as layout.json v2.1.

Run in Blender with __file__ set, then:
    bpy.app.driver_namespace["full_preview"]["build"]()
"""
import bpy
import importlib.util
import json
import os

_HERE = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else os.getcwd()
_ROOT = os.path.normpath(os.path.join(_HERE, "..", ".."))


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


BF = _load("full_preview_battlefield", os.path.join(_HERE, "build_battlefield.py"))
KIT = _load("full_preview_castle", os.path.join(_ROOT, "assets", "castle", "build_castle.py"))


def _clear_review():
    old = bpy.data.scenes.get("Battlefield_Full_Preview")
    if old is None:
        return
    for coll in list(old.collection.children):
        old.collection.children.unlink(coll)
        if coll.name.startswith("Full_Preview_"):
            for obj in list(coll.objects):
                bpy.data.objects.remove(obj)
            bpy.data.collections.remove(coll)
    bpy.data.scenes.remove(old)


def build():
    _clear_review()
    # The two source scenes are generated from their scripts, never edited here.
    battlefield = BF.build()
    castle = KIT.build()
    with open(os.path.join(_ROOT, "layout.json"), encoding="utf-8") as file:
        layout = json.load(file)
    team_a = layout["castles"][0]
    offset = (team_a["center"]["x"], -team_a["center"]["z"], team_a["pad"]["y"])

    scene = bpy.data.scenes.new("Battlefield_Full_Preview")
    scene.world = battlefield["scene"].world
    scene.view_settings.view_transform = battlefield["scene"].view_settings.view_transform
    for coll in battlefield["scene"].collection.children:
        if coll.name != "BF_Castles":
            scene.collection.children.link(coll)
    castles = bpy.data.collections.new("Full_Preview_Castles")
    scene.collection.children.link(castles)
    dummies = bpy.data.collections.new("Full_Preview_Dummies")
    scene.collection.children.link(dummies)
    lighting = bpy.data.collections.new("Full_Preview_Forge_Lighting")
    scene.collection.children.link(lighting)

    for source_name in ("Castle_Assembly", "Castle_Assembly_B"):
        source = bpy.data.collections[source_name]
        for obj in source.objects:
            layout_id = obj.get("layout_id", obj.name)
            # The battlefield already carries its approved tunnel exit hatch.
            if layout_id.endswith("_Tunnel_Exit"):
                continue
            copy = obj.copy()
            copy.data = obj.data
            copy.name = layout_id
            copy.location = (obj.location.x + offset[0],
                             obj.location.y + offset[1],
                             obj.location.z + offset[2])
            copy["layout_id"] = layout_id
            copy["traces_to"] = "layout.json castle assembly " + layout_id
            castles.objects.link(copy)

    blacksmith = next(s for s in team_a["interior"]["specialists"]
                      if s["role"] == "Blacksmith")
    dummy_mesh = BF.make_dummy(BF.KIT.castle_material(), name="Full_Preview_Dummy_5stud")
    BF.place(dummies, "Full_Preview_Dummy_Blacksmith", dummy_mesh,
             (blacksmith["door"]["x"] + 6.5, -blacksmith["door"]["z"] + 9.0,
              blacksmith["y"]), 0.0,
             "preview avatar scale beside layout.json A_Blacksmith_Door")
    for team, x in (("A", blacksmith["door"]["x"] + 6.0),
                    ("B", -blacksmith["door"]["x"] - 6.0)):
        lamp = bpy.data.lights.new("Full_Preview_Forge_Fire_" + team, "POINT")
        lamp.color = (1.0, 0.31, 0.09)
        lamp.energy = 1600
        lamp.shadow_soft_size = 1.6
        obj = bpy.data.objects.new("Full_Preview_Forge_Fire_" + team, lamp)
        obj.location = (x, -((blacksmith["min_z"] + blacksmith["max_z"]) / 2) - 6,
                        blacksmith["y"] + 4.2)
        obj["traces_to"] = "preview forge glow at layout.json " + team + "_Blacksmith_Forge"
        lighting.objects.link(obj)

    bpy.context.window.scene = scene
    scene.view_layers[0].update()
    markers = scene.view_layers[0].layer_collection.children.get("BF_Layout_Markers")
    if markers is not None:
        markers.hide_viewport = True
    scene.view_layers[0].update()

    ids = {o["layout_id"] for o in castles.objects}
    for team in ("A", "B"):
        required = (team + "_Keep", team + "_Blacksmith_Forge",
                    team + "_Blacksmith_Forge_Roof", team + "_Blacksmith_Forge_Detail",
                    team + "_Blacksmith_Forecourt",
                    team + "_Fletcher", team + "_Fletcher_Detail",
                    team + "_Alchemist", team + "_Alchemist_Detail",
                    team + "_Carpenter", team + "_Carpenter_Detail",
                    team + "_Barracks", team + "_Gate_Door")
        missing = set(required) - ids
        if missing:
            raise AssertionError("Missing castle pieces: " + ", ".join(sorted(missing)))
    return dict(scene=scene, castle_count=len(castles.objects),
                castle_mesh_stats=castle["stats"],
                battlefield_stats=battlefield["stats"])


def show(scene):
    BF.show(scene, markers=False)


def export_interior_fbx(scene, path):
    """Export only the mirrored castle interiors at layout world coordinates.

    The exterior walls and terrain already live in battlefield.fbx. The export
    deliberately excludes them so Studio receives no duplicate geometry.
    """
    coll = bpy.data.collections["Full_Preview_Castles"]
    interiors = ("Keep", "Stockpile_Contents", "Barracks", "Blacksmith_Forge",
                 "Blacksmith_Forecourt", "Fletcher", "Alchemist", "Carpenter",
                 "Ballista", "Tower_Access")
    objs = [o for o in coll.objects if any(o.get("layout_id", "").startswith(team + "_" + role)
            for team in ("A", "B") for role in interiors)]
    if len(objs) != 40:
        raise AssertionError("Interior export count changed: %d" % len(objs))
    layer = scene.view_layers[0]
    win = bpy.context.window
    previous_scene = win.scene
    previous_selection = [o for o in layer.objects if o.select_get(view_layer=layer)]
    previous_active = layer.objects.active
    renamed = []
    try:
        win.scene = scene
        for o in objs:
            wanted = o["layout_id"]
            holder = bpy.data.objects.get(wanted)
            if holder is not None and holder is not o:
                holder.name = wanted + "__export_swap"
            renamed.append((o, o.name, holder, wanted))
            o.name = wanted
        for o in previous_selection:
            o.select_set(False, view_layer=layer)
        for o in objs:
            o.select_set(True, view_layer=layer)
        layer.objects.active = objs[0]
        with bpy.context.temp_override(window=win, scene=scene, view_layer=layer):
            bpy.ops.export_scene.fbx(
                filepath=path, use_selection=True, object_types={"MESH"},
                axis_forward="-Z", axis_up="Y", bake_space_transform=True,
                apply_scale_options="FBX_SCALE_ALL", mesh_smooth_type="FACE",
                colors_type="SRGB", use_mesh_modifiers=True,
                add_leaf_bones=False, bake_anim=False, path_mode="STRIP")
    finally:
        for o, old_name, holder, wanted in reversed(renamed):
            o.name = old_name
            if holder is not None:
                holder.name = wanted
        for o in objs:
            o.select_set(False, view_layer=layer)
        for o in previous_selection:
            o.select_set(True, view_layer=layer)
        layer.objects.active = previous_active
        win.scene = previous_scene
    return len(objs)


bpy.app.driver_namespace["full_preview"] = dict(build=build, show=show,
                                                 orbit=BF.MAP.orbit, look=BF.MAP.look,
                                                 export_interior_fbx=export_interior_fbx)
