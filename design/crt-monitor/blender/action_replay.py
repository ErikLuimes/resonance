"""Model the red Action Replay Mk VI for the About desk.

Blender -b --python action_replay.py -- ActionReplay.usdz
The label faces up. The connector points forward (+Z after USD export).
Reference: Datel's Action Replay VI manual, cover and sections 1.1–1.3.
https://www.commodorecheetah.co.uk/Cheats/Files/AR6_Manual.pdf
"""

import math
import sys

import bpy


def material(name, color, roughness, metalness=0.0):
    result = bpy.data.materials.new(name)
    result.diffuse_color = (*color, 1.0)
    result.use_nodes = True
    surface = result.node_tree.nodes.get("Principled BSDF")
    surface.inputs["Base Color"].default_value = result.diffuse_color
    surface.inputs["Roughness"].default_value = roughness
    surface.inputs["Metallic"].default_value = metalness
    return result


def box(name, dimensions, position, radius, finish):
    bpy.ops.mesh.primitive_cube_add(size=1, location=position)
    obj = bpy.context.object
    obj.name = name
    obj.dimensions = dimensions
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    bevel = obj.modifiers.new("Rounded edges", "BEVEL")
    bevel.width = radius
    bevel.segments = 4
    obj.modifiers.new("Corner normals", "WEIGHTED_NORMAL")
    obj.data.materials.append(finish)
    return obj


def cylinder(name, radius, depth, position, finish):
    bpy.ops.mesh.primitive_cylinder_add(
        vertices=32, radius=radius, depth=depth, location=position,
        rotation=(math.pi / 2, 0, 0),
    )
    obj = bpy.context.object
    obj.name = name
    bevel = obj.modifiers.new("Rounded edges", "BEVEL")
    bevel.width = 0.008
    bevel.segments = 3
    obj.modifiers.new("Corner normals", "WEIGHTED_NORMAL")
    obj.data.materials.append(finish)
    return obj


def lettering(name, body, size, position, finish):
    bpy.ops.object.text_add(location=position)
    obj = bpy.context.object
    obj.name = name
    obj.data.body = body
    obj.data.align_x = "CENTER"
    obj.data.align_y = "CENTER"
    obj.data.size = size
    obj.data.materials.append(finish)
    bpy.ops.object.convert(target="MESH")


output = sys.argv[sys.argv.index("--") + 1]
bpy.ops.wm.read_factory_settings(use_empty=True)

red = material("Red ABS", (0.31, 0.018, 0.014), 0.38)
lower = material("Red ABS underside", (0.22, 0.012, 0.010), 0.43)
seam = material("Shell seam", (0.15, 0.008, 0.006), 0.55)
black = material("Black cap", (0.025, 0.024, 0.022), 0.4)
metal = material("Switch collar", (0.58, 0.55, 0.50), 0.30, 0.82)
paper = material("Satin label", (0.06, 0.018, 0.012), 0.66)
ink = material("Cream ink", (0.88, 0.84, 0.71), 0.68)
accent = material("Gold ink", (0.79, 0.44, 0.11), 0.68)
board = material("Circuit board", (0.034, 0.13, 0.044), 0.75)
gold = material("Edge contacts", (0.60, 0.32, 0.075), 0.30, 0.62)

box("upper_shell", (1.12, 0.90, 0.133), (0, 0, 0.071), 0.034, red)
box("lower_shell", (1.12, 0.90, 0.106), (0, 0, -0.058), 0.030, lower)
box("case_joint", (1.108, 0.888, 0.021), (0, 0, 0), 0.008, seam)
box("connector_shroud", (0.92, 0.15, 0.164), (0, -0.485, -0.017), 0.018, lower)
box("edge_connector", (0.83, 0.10, 0.025), (0, -0.58, -0.027), 0.005, board)
for index in range(22):
    x = (index - 10.5) * 0.0345
    box(f"contact_{index:02}", (0.019, 0.065, 0.002), (x, -0.592, -0.014), 0, gold)

box("label", (0.90, 0.57, 0.006), (0, -0.055, 0.139), 0.002, paper)
for y in (-0.301, 0.191):
    box("label_rule", (0.81, 0.007, 0.001), (0, y, 0.1425), 0, accent)
lettering("action_replay_title", "ACTION REPLAY", 0.127, (0, -0.01, 0.143), ink)
lettering("mk_vi", "MK VI  PROFESSIONAL", 0.066, (0, -0.142, 0.143), accent)
lettering("datel", "DATEL ELECTRONICS", 0.045, (0, -0.242, 0.143), ink)

# The rear controls sit near the upper edge so their caps can be seen from
# the desk's front camera. The inner button is Freeze.
for name, x, finish in [("freeze", 0.23, black), ("reset", 0.43, lower)]:
    cylinder(f"{name}_collar", 0.072, 0.090, (x, 0.483, 0.082), metal)
    cylinder(f"{name}_button", 0.060, 0.092, (x, 0.572, 0.082), finish)
    lettering(f"{name}_legend", name.upper(), 0.047, (x, 0.365, 0.138), ink)

bpy.ops.wm.usd_export(
    filepath=output, export_materials=True, generate_preview_surface=True,
    convert_orientation=True, export_global_up_selection="Y",
)
