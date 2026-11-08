import bpy, sys, math, mathutils
from bpy_extras.object_utils import world_to_camera_view
args = sys.argv[sys.argv.index("--") + 1:]
path, which, out = args[0], args[1], args[2]
W, H = (2400, 2000) if which == "monitor" else (2400, 1600)

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=path)
scene = bpy.context.scene
keep = {"monitor": ["Object_17", "Object_18", "Object_19", "Object_21"],
        "c64": ["Object_4", "Object_5", "Object_6"]}[which]
for o in bpy.data.objects:
    if o.type == 'MESH':
        o.hide_render = o.name not in keep
        o.hide_viewport = o.hide_render

# Bounds of what's kept.
mn = mathutils.Vector((1e9,)*3); mx = mathutils.Vector((-1e9,)*3)
for name in keep:
    o = bpy.data.objects[name]
    for c in o.bound_box:
        w = o.matrix_world @ mathutils.Vector(c)
        mn = mathutils.Vector(map(min, mn, w)); mx = mathutils.Vector(map(max, mx, w))
center = (mn + mx) / 2
size = mx - mn
print("BOUNDS", tuple(round(v, 3) for v in mn), tuple(round(v, 3) for v in mx))

# Camera: straight on from the front (-Y), a long lens, the monitor at eye height;
# the C64 from a little above, like a photo on a desk.
cam_data = bpy.data.cameras.new("cam"); cam_data.lens = 85; cam_data.sensor_width = 36
cam = bpy.data.objects.new("cam", cam_data); scene.collection.objects.link(cam); scene.camera = cam
elev = math.radians(2 if which == "monitor" else 22)
fill = 0.64 if which == "monitor" else 0.82      # share of the frame width the object takes
dist = (size.x / fill) / (2 * math.tan(math.atan(cam_data.sensor_width / (2 * cam_data.lens))))
target = mathutils.Vector((center.x, center.y, center.z + (0 if which == "monitor" else 0)))
cam.location = target + mathutils.Vector((0, -dist * math.cos(elev), dist * math.sin(elev)))
cam.rotation_euler = (math.radians(90) - elev, 0, 0)

# Light: a big soft key from the front top left, a fill from the right, a gray world.
def light(name, kind, loc, energy, size_=None, color=(1, 1, 1)):
    d = bpy.data.lights.new(name, kind); d.energy = energy; d.color = color
    if size_: d.size = size_
    o = bpy.data.objects.new(name, d); scene.collection.objects.link(o); o.location = loc
    direction = target - o.location
    o.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()
    return o
light("key", 'AREA', target + mathutils.Vector((-4, -7, 6)), 1500, 6)
light("fill", 'AREA', target + mathutils.Vector((6, -6, 2)), 500, 6)
light("rim", 'AREA', target + mathutils.Vector((0, 5, 6)), 300, 4)
world = bpy.data.worlds.new("w"); scene.world = world; world.use_nodes = True
bg = world.node_tree.nodes["Background"]; bg.inputs[0].default_value = (0.6, 0.6, 0.62, 1); bg.inputs[1].default_value = 0.5

scene.render.engine = 'CYCLES'
prefs = bpy.context.preferences.addons['cycles'].preferences
prefs.compute_device_type = 'METAL'
prefs.get_devices()
for dev in prefs.devices: dev.use = True
scene.cycles.device = 'GPU'
scene.cycles.samples = 96
scene.cycles.use_denoising = True
scene.render.film_transparent = True
scene.render.resolution_x = W; scene.render.resolution_y = H; scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = 'PNG'; scene.render.image_settings.color_mode = 'RGBA'
scene.view_settings.view_transform = 'Standard'
scene.render.filepath = out
bpy.context.view_layer.update()
render = len(args) < 4 or args[3] != "norender"

if which == "monitor":
    # The screen mesh's corners in the image, for the shader.
    s = bpy.data.objects["Object_19"]
    pts = [s.matrix_world @ mathutils.Vector(c) for c in s.bound_box]
    # The front face: the points with the smallest y (toward the camera).
    ymin = min(p.y for p in pts)
    front = [p for p in pts if abs(p.y - ymin) < 0.02]
    for p in sorted(front, key=lambda p: (-p.z, p.x)):
        v = world_to_camera_view(scene, cam, p)
        print("SCREEN", round(p.x, 3), round(p.y, 3), round(p.z, 3), "->", round(v.x * W), round((1 - v.y) * H))
    v0 = world_to_camera_view(scene, cam, mn); v1 = world_to_camera_view(scene, cam, mx)
# The kept objects' extent in the image.
corners = []
for name in keep:
    o = bpy.data.objects[name]
    for c in o.bound_box:
        v = world_to_camera_view(scene, cam, o.matrix_world @ mathutils.Vector(c))
        corners.append((v.x * W, (1 - v.y) * H))
print("EXTENT x", round(min(c[0] for c in corners)), round(max(c[0] for c in corners)), "y", round(min(c[1] for c in corners)), round(max(c[1] for c in corners)))
if render:
    bpy.ops.render.render(write_still=True)
    print("DONE", out)
