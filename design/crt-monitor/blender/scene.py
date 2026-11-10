# The desk for the live 3D monitor: dark_igorek's "Commodore 64 || Computer
# (Full Pack)" (CC BY 4.0, served by c64ready.com as commodore_64.glb) with the
# parts the app moves or lights given names of their own:
#
#   screen        the 1702's glass, with a second UV map "crt" that is a flat
#                 projection of its front (u left to right, v bottom to top), for
#                 the tube's picture; the first map keeps the model's glass texture
#   power_button  the brown POWER rocker, cut out of the case
#   power_led     the power light on the badge strip, cut out of the case
#   knob_<NAME>   the seven front controls, with their origins on their shafts
#   drive_door    the 1541's hinged disk catch, separated from its faceplate
#   key_<NAME>    each of the 66 keycaps, its origin at the cap's top center, so
#                 pressing a key is moving its node down
#   sticker       a plane on the bezel where the app icon sticker goes
#
# Run (the GLB is for design/crt-monitor/mockup-3d.html, the USDZ is the
# app's apple/Resonance/Scenes/Desk.usdz):
#   /Applications/Blender.app/Contents/MacOS/Blender -b --python design/crt-monitor/blender/scene.py -- commodore_64.glb design/crt-monitor/model/desk.glb apple/Resonance/Scenes/Desk.usdz
#
# Blender is Z up; the exports are Y up, so Blender's (x, y, z) is (x, z, -y)
# in three.js and SceneKit. The front of the machines faces Blender's -Y,
# which is +Z after export: toward a camera on the +Z axis.

import bpy, bmesh, sys, mathutils, math

args = sys.argv[sys.argv.index("--") + 1:]
src, out_glb = args[0], args[1]
out_usd = args[2] if len(args) > 2 else None

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)

# Flatten the hierarchy: every mesh in world space, no parents, no empties.
meshes = [o for o in bpy.data.objects if o.type == 'MESH']
for o in meshes:
    mw = o.matrix_world.copy()
    o.parent = None
    o.matrix_world = mw
for o in [o for o in bpy.data.objects if o.type == 'EMPTY']:
    bpy.data.objects.remove(o)
bpy.ops.object.select_all(action='DESELECT')
for o in meshes:
    o.select_set(True)
bpy.context.view_layer.objects.active = meshes[0]
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

names = {"Object_4": "c64_details", "Object_5": "keyboard", "Object_6": "c64_body",
         "Object_8": "power_supply", "Object_10": "joystick", "Object_12": "drive_1541",
         "Object_14": "cables", "Object_15": "connectors", "Object_17": "monitor_black",
         "Object_18": "monitor_white", "Object_19": "screen", "Object_21": "monitor_cap",
         "Object_23": "monitor_plug"}
for old, new in names.items():
    bpy.data.objects[old].name = new


def islands(obj):
    """Connected pieces of a mesh: (vertex indices, world min, world max)."""
    bm = bmesh.new(); bm.from_mesh(obj.data); bm.verts.ensure_lookup_table()
    seen, out = set(), []
    for v in bm.verts:
        if v.index in seen:
            continue
        stack, comp = [v], []
        seen.add(v.index)
        while stack:
            a = stack.pop(); comp.append(a.index)
            for e in a.link_edges:
                b = e.other_vert(a)
                if b.index not in seen:
                    seen.add(b.index); stack.append(b)
        ws = [obj.matrix_world @ bm.verts[i].co for i in comp]
        mn = mathutils.Vector([min(w[i] for w in ws) for i in range(3)])
        mx = mathutils.Vector([max(w[i] for w in ws) for i in range(3)])
        out.append((comp, mn, mx))
    bm.free()
    return out


def boxed(obj, boxes, max_width=math.inf):
    """Moves the pieces of obj whose centers lie in each named box into an
    object of that name. Vertex indices change with every separate, so the
    pieces are found again each time."""
    made = {}
    for name, (lo, hi) in boxes.items():
        verts = [i for comp, a, b in islands(obj)
                 if b.x - a.x <= max_width
                 and all(lo[k] <= (a[k] + b[k]) / 2 <= hi[k] for k in range(3)) for i in comp]
        assert verts, name
        bpy.ops.object.select_all(action='DESELECT')
        obj.select_set(True); bpy.context.view_layer.objects.active = obj
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.select_all(action='DESELECT')
        bpy.ops.object.mode_set(mode='OBJECT')
        for i in verts:
            obj.data.vertices[i].select = True
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.separate(type='SELECTED')
        bpy.ops.object.mode_set(mode='OBJECT')
        piece = [o for o in bpy.context.selected_objects if o is not obj][0]
        piece.name = name
        made[name] = piece
    return made


boxed(bpy.data.objects["drive_1541"], {
    "drive_door": ((-4.60, -0.72, 0.511), (-4.25, -0.45, 0.553)),
}, max_width=0.54)


# --- The keys --------------------------------------------------------------
# The keyboard mesh is 729 pieces, eleven to a key (the cap, its top, the walls
# of its well) and three for the space bar. Each cap body is a piece about
# 0.18 tall; the rows run along x at four y's, the function keys in a column.
ROWS = [
    ["LEFT_ARROW", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "PLUS", "MINUS", "POUND", "CLR_HOME", "INST_DEL", "F1"],
    ["CTRL", "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "AT", "ASTERISK", "UP_ARROW", "RESTORE", "F3"],
    ["RUN_STOP", "SHIFT_LOCK", "A", "S", "D", "F", "G", "H", "J", "K", "L", "COLON", "SEMICOLON", "EQUALS", "RETURN", "F5"],
    ["COMMODORE", "LEFT_SHIFT", "Z", "X", "C", "V", "B", "N", "M", "COMMA", "PERIOD", "SLASH", "RIGHT_SHIFT", "CRSR_UD", "CRSR_LR", "F7"],
]
kb = bpy.data.objects["keyboard"]
pieces = islands(kb)
caps = [(mn, mx) for comp, mn, mx in pieces if mx.z - mn.z > 0.14 and len(comp) == 105]
space = [(mn, mx) for comp, mn, mx in pieces if mx.x - mn.x > 1.5][0]
caps.sort(key=lambda c: -(c[0].y + c[1].y) / 2)
assert len(caps) == 65, len(caps)
rows, row = [], []
for c in caps:
    if row and abs((c[0].y + c[1].y) / 2 - (row[0][0].y + row[0][1].y) / 2) > 0.08:
        rows.append(row); row = []
    row.append(c)
rows.append(row)
# Rows are ordered by y; within a row, by x. The top row is the one furthest back (largest y).
key_boxes, key_tops = {}, {}
for names_row, caps_row in zip(ROWS, rows):
    caps_row.sort(key=lambda c: c[0].x)
    assert len(names_row) == len(caps_row), (names_row, len(caps_row))
    for name, (mn, mx) in zip(names_row, caps_row):
        key_boxes["key_" + name] = (mathutils.Vector((mn.x, mn.y, 0.3)), mathutils.Vector((mx.x, mx.y, 2)))
key_boxes["key_SPACE"] = (mathutils.Vector((space[0].x - 0.02, space[0].y - 0.06, 0.3)), mathutils.Vector((space[1].x + 0.02, space[1].y + 0.06, 2)))
keys = boxed(kb, key_boxes)
for name, obj in keys.items():
    # Origin at the top center of the cap.
    pts = [obj.matrix_world @ v.co for v in obj.data.vertices]
    top = mathutils.Vector(((min(p.x for p in pts) + max(p.x for p in pts)) / 2,
                            (min(p.y for p in pts) + max(p.y for p in pts)) / 2,
                            max(p.z for p in pts)))
    bpy.context.scene.cursor.location = top
    bpy.ops.object.select_all(action='DESELECT'); obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.origin_set(type='ORIGIN_CURSOR')
print("KEYS", len(keys))

# --- The power rocker and the light ------------------------------------------
# Found by casting rays through the still render (render.py's camera): the
# rocker's corners hit the case at (1.72, 0.12, 0.69) and (1.85, 0.04, 0.57),
# the light at (0.42, 0.04, 0.67).
case = bpy.data.objects["monitor_white"]
parts = boxed(case, {
    "power_button": (mathutils.Vector((1.70, -0.03, 0.58)), mathutils.Vector((1.88, 0.17, 0.70))),
    "power_led": (mathutils.Vector((0.38, 0.035, 0.645)), mathutils.Vector((0.47, 0.08, 0.68))),
})
for obj in parts.values():
    bpy.ops.object.select_all(action='DESELECT'); obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.origin_set(type='ORIGIN_GEOMETRY', center='BOUNDS')
led = parts["power_led"]
led_mat = bpy.data.materials.new("power_led"); led_mat.use_nodes = True
bsdf = led_mat.node_tree.nodes["Principled BSDF"]
bsdf.inputs["Base Color"].default_value = (0.05, 0.12, 0.07, 1)
bsdf.inputs["Roughness"].default_value = 0.35
led.data.materials.clear(); led.data.materials.append(led_mat)
button = parts["power_button"]
pts = [button.matrix_world @ v.co for v in button.data.vertices]
print("BUTTON", [round(min(p[i] for p in pts), 3) for i in range(3)], [round(max(p[i] for p in pts), 3) for i in range(3)])

# Three narrow pieces per knob make up the moving shaft and cap. The wider
# rings around the shafts belong to the fixed panel.
knob_centers = dict(zip(
    ("knob_tint", "knob_color", "knob_brightness", "knob_contrast", "knob_horizontal", "knob_vertical", "knob_volume"),
    (-1.15414, -0.93061, -0.70707, -0.48354, -0.01560, 0.20723, 0.43007),
))
knobs = boxed(case, {
    name: (mathutils.Vector((x - 0.04, 0.12, 0.34)), mathutils.Vector((x + 0.04, 0.25, 0.38)))
    for name, x in knob_centers.items()
}, max_width=0.065)
for name, knob in knobs.items():
    bpy.ops.object.select_all(action='DESELECT')
    knob.select_set(True)
    bpy.context.view_layer.objects.active = knob
    bpy.context.scene.cursor.location = (knob_centers[name], 0.20, 0.361195)
    bpy.ops.object.origin_set(type='ORIGIN_CURSOR')

# --- The screen ----------------------------------------------------------------
screen = bpy.data.objects["screen"]
me = screen.data
while len(me.uv_layers) > 1:
    me.uv_layers.remove(me.uv_layers[-1])
crt = me.uv_layers.new(name="crt")
xs = [v.co.x for v in me.vertices]; zs = [v.co.z for v in me.vertices]
x0, x1, z0, z1 = min(xs), max(xs), min(zs), max(zs)
for poly in me.polygons:
    for li in poly.loop_indices:
        co = me.vertices[me.loops[li].vertex_index].co
        crt.data[li].uv = ((co.x - x0) / (x1 - x0), (co.z - z0) / (z1 - z0))
print("SCREEN", round(x0, 4), round(x1, 4), round(z0, 4), round(z1, 4))

# --- The sticker ---------------------------------------------------------------
# Top left on the bezel, a little larger than the 2D one (0.6 units): its top
# left lies on the flat black band (y 0.052 there, only 0.1 to 0.17 wide), the
# rest bridges the recess, 0.2 deep, with its lifting corner over the glass.
bpy.ops.mesh.primitive_plane_add(size=0.6, location=(-1.61, 0.026, 3.47))
sticker = bpy.context.active_object
sticker.name = "sticker"
sticker.rotation_euler = (math.radians(90), math.radians(-8), 0)  # facing -Y, turned 8° clockwise as seen
sticker_mat = bpy.data.materials.new("sticker"); sticker_mat.use_nodes = True
sticker.data.materials.append(sticker_mat)
bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)

bpy.ops.object.select_all(action='SELECT')
bpy.ops.export_scene.gltf(filepath=out_glb, export_format='GLB', export_yup=True, export_apply=True,
                          export_materials="EXPORT")
print("WROTE", out_glb)
if out_usd:
    # The app's copy: a USDC with its textures beside it, every PNG turned
    # into a JPEG (quality 88, which takes the model from 16 MB to under 10),
    # then packed into a USDZ with macOS's usdzip. Y up, as SceneKit wants;
    # the UV maps keep their names (st, crt).
    import os, subprocess, tempfile
    from pxr import Usd, Sdf, UsdShade
    tmp = tempfile.mkdtemp()
    usdc = os.path.join(tmp, "Desk.usdc")
    bpy.ops.wm.usd_export(filepath=usdc, selected_objects_only=False, export_materials=True,
                          generate_preview_surface=True, export_uvmaps=True, rename_uvmaps=True,
                          convert_orientation=True, export_global_up_selection='Y', export_textures_mode='NEW')
    textures = os.path.join(tmp, "textures")
    for name in os.listdir(textures):
        if name.endswith(".png"):
            src_png = os.path.join(textures, name)
            subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "88", src_png,
                            "--out", src_png[:-4] + ".jpg"], check=True, capture_output=True)
            os.remove(src_png)
    stage = Usd.Stage.Open(usdc)
    for prim in stage.Traverse():
        for attr in prim.GetAttributes():
            value = attr.Get()
            if isinstance(value, Sdf.AssetPath) and value.path.endswith(".png"):
                attr.Set(Sdf.AssetPath(value.path[:-4] + ".jpg"))
    stage.GetRootLayer().Save()
    if os.path.exists(out_usd):
        os.remove(out_usd)
    files = ["Desk.usdc"] + ["textures/" + n for n in sorted(os.listdir(textures))]
    subprocess.run(["usdzip", os.path.abspath(out_usd)] + files, cwd=tmp, check=True)
    print("WROTE", out_usd)
