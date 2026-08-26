"""Build the preview mannequin in Blender and write it out as glTF.

    blender --background --python scripts/make_mannequin.py

The asset is generated rather than committed as a .blend so that what the
repository carries is the recipe. The result is a 42 KB glb with 22 bones and
about 330 triangles.

Why build one at all: every humanoid within reach was wrong in some way. The
Godot demo characters are either 24 MB or missing hands and shoulders, the
GDQuest mannequin (which Godot's own ragdoll demo also ships) has an authored
rest with folded legs and only two spine bones, and the Khronos test figures
have no clavicles and synthetic bone names. This one is dimensioned from the
SMPL-X rest that kimodo.cpp emits, so it maps 22 of 22 at a scale of exactly
1.0, and it stands on the floor already, so no import-time rest fixing is
needed.

Bones carry SkeletonProfileHumanoid names, which is what lets Godot resolve
them without a BoneMap. Left limbs are warm and right limbs cold, with a nose
on the facing side, because telling a mirrored clip from a correct one is still
an open question and a grey figure cannot answer it.
"""

import os

import bpy
from mathutils import Vector

OUTPUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "project", "addons", "kimodo", "samples", "kimodo_mannequin.glb")

# (profile bone, parent index, parent-local offset in Y-up metres, half width).
#
# The offsets are the SMPL-X 22 rest from src/smplx22.cpp, mirrored into
# symmetry. That table was calibrated from a captured fixture and carries its
# asymmetry: the head joint sits 25 mm to the left of the neck, the left elbow
# is 19 mm nearer the shoulder than the right. Motion has to be decoded against
# the numbers as published, which is why the C++ keeps them, but a figure whose
# neck leans sideways at rest is a figure that cannot be trusted to show a
# left-right problem in the motion. So the pairs are averaged and the spine is
# put on the centre line.
JOINTS = [
    ("Hips",           -1, ( 0.000000,  0.000000,  0.000000), 0.115),
    ("LeftUpperLeg",    0, ( 0.054746, -0.100242, -0.024913), 0.082),
    ("RightUpperLeg",   0, (-0.054746, -0.100242, -0.024913), 0.082),
    ("Spine",           0, ( 0.000000,  0.112930, -0.024981), 0.102),
    ("LeftLowerLeg",    1, ( 0.053471, -0.407001, -0.010309), 0.058),
    ("RightLowerLeg",   2, (-0.053471, -0.407001, -0.010309), 0.058),
    ("Chest",           3, ( 0.000000,  0.145636, -0.006859), 0.126),
    ("LeftFoot",        4, (-0.028114, -0.442219, -0.023771), 0.046),
    ("RightFoot",       5, ( 0.028114, -0.442219, -0.023771), 0.046),
    ("UpperChest",      6, ( 0.000000,  0.056082,  0.021116), 0.134),
    ("LeftToes",        7, ( 0.044935, -0.065283,  0.126668), 0.036),
    ("RightToes",       8, (-0.044935, -0.065283,  0.126668), 0.036),
    ("Neck",            9, ( 0.000000,  0.171365, -0.028827), 0.046),
    ("LeftShoulder",    9, ( 0.047181,  0.087128, -0.011620), 0.052),
    ("RightShoulder",   9, (-0.047181,  0.087128, -0.011620), 0.052),
    ("Head",           12, ( 0.000000,  0.175391,  0.024463), 0.042),
    ("LeftUpperArm",   13, ( 0.117814,  0.055677, -0.011502), 0.050),
    ("RightUpperArm",  14, (-0.117814,  0.055677, -0.011502), 0.050),
    ("LeftLowerArm",   16, ( 0.282468, -0.052647, -0.031830), 0.040),
    ("RightLowerArm",  17, (-0.282468, -0.052647, -0.031830), 0.040),
    ("LeftHand",       18, ( 0.274026,  0.008210, -0.009462), 0.034),
    ("RightHand",      19, (-0.274026,  0.008210, -0.009462), 0.034),
]

# How much of a segment to actually draw. The neck joint to the head joint is
# 175 mm because the head joint sits inside the skull, so a box over the whole
# span is a neck half a head long.
FRACTION = {"Head": 0.42}

# The torso is wider than it is deep; a limb is close to round.
TORSO = {"Hips", "Spine", "Chest", "UpperChest", "Neck"}

# Joints that splay left and right off a single parent joint. Drawing a box
# from the parent to each of them lays two diagonal wedges across the chest and
# the pelvis in an X. The blocks spanning the pair cover the same ground and
# read as a body.
SPLAYED = {"LeftUpperLeg", "RightUpperLeg", "LeftShoulder", "RightShoulder"}
FORWARD = (0.0, -1.0, 0.0)   # Blender -Y is the character's front

LEFT = {"LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "LeftToes",
        "LeftShoulder", "LeftUpperArm", "LeftLowerArm", "LeftHand"}
RIGHT = {name.replace("Left", "Right") for name in LEFT}
CENTRE, WARM, COLD, FACE = 0, 1, 2, 3

MATERIALS = (
    ("MannequinBody", (0.72, 0.72, 0.76, 1.0), 0.65),
    ("MannequinLeft", (0.90, 0.36, 0.30, 1.0), 0.65),
    ("MannequinRight", (0.30, 0.55, 0.92, 1.0), 0.65),
    ("MannequinFace", (0.95, 0.80, 0.25, 1.0), 0.50),
)


def to_blender(point):
    """Y-up, the space kimodo emits, into Blender's Z-up."""
    return Vector((point.x, -point.z, point.y))


def rest_positions():
    """Global rest positions, standing with the lowest joint on the floor."""
    world = []
    for _name, parent, offset, _radius in JOINTS:
        base = Vector((0.0, 0.0, 0.0)) if parent < 0 else world[parent]
        world.append(base + Vector(offset))
    lift = -min(point.y for point in world)
    return [point + Vector((0.0, lift, 0.0)) for point in world]


def build_armature(collection, world):
    armature_data = bpy.data.armatures.new("MannequinArmature")
    armature = bpy.data.objects.new("Mannequin", armature_data)
    collection.objects.link(armature)
    bpy.context.view_layer.objects.active = armature
    bpy.ops.object.mode_set(mode="EDIT")

    children = {index: [] for index in range(len(JOINTS))}
    for index, (_n, parent, _o, _r) in enumerate(JOINTS):
        if parent >= 0:
            children[parent].append(index)

    edit_bones = []
    for index, (name, parent, _offset, _radius) in enumerate(JOINTS):
        bone = armature_data.edit_bones.new(name)
        head = to_blender(world[index])
        if children[index]:
            tail = to_blender(world[children[index][0]])
            if (tail - head).length < 0.02:
                tail = head + Vector((0.0, 0.0, 0.05))
        else:
            along = head - to_blender(world[parent]) if parent >= 0 else Vector((0.0, 0.0, 0.1))
            tail = head + (along.normalized() * 0.09 if along.length > 1e-6 else Vector((0.0, 0.0, 0.09)))
        bone.head, bone.tail = head, tail
        edit_bones.append(bone)

    for index, (_name, parent, _o, _r) in enumerate(JOINTS):
        if parent >= 0:
            edit_bones[index].parent = edit_bones[parent]

    bpy.ops.object.mode_set(mode="OBJECT")
    return armature


class Body:
    """One mesh of boxes, each box owned outright by a single bone.

    Rigid weights rather than automatic ones: the shape is a stand-in, and a
    box that belongs to exactly one bone cannot deform in a way that hides a
    retargeting mistake.
    """

    def __init__(self):
        self.vertices, self.faces, self.face_material, self.groups = [], [], [], {}

    def box(self, bone, start, end, start_width, end_width, material, depth_ratio=0.88):
        direction = end - start
        length = direction.length
        if length < 1e-5:
            return
        direction = direction / length

        # Always twist the box against the same world axis. Choosing the
        # reference per bone, by whichever axis that bone leant away from,
        # spun neighbouring torso boxes ninety degrees apart and the seams
        # showed as a stack of misaligned blocks.
        reference = Vector(FORWARD)
        if abs(direction.dot(reference)) > 0.95:
            reference = Vector((0.0, 0.0, 1.0))
        right = reference.cross(direction).normalized()
        up = direction.cross(right).normalized()

        base = len(self.vertices)
        for point, width in ((start, start_width), (end, end_width)):
            for sr, su in ((1, 1), (1, -1), (-1, -1), (-1, 1)):
                self.vertices.append(point
                                     + right * (width * sr)
                                     + up * (width * depth_ratio * su))
        for quad in ((0, 1, 2, 3), (7, 6, 5, 4), (0, 4, 5, 1),
                     (1, 5, 6, 2), (2, 6, 7, 3), (3, 7, 4, 0)):
            self.faces.append(tuple(base + i for i in quad))
            self.face_material.append(material)
        self.groups.setdefault(bone, []).extend(range(base, base + 8))


def side_of(name):
    return WARM if name in LEFT else COLD if name in RIGHT else CENTRE


def build_body(collection, armature):
    bones = armature.data.bones
    radius = {name: r for name, _p, _o, r in JOINTS}
    body = Body()

    # A segment belongs to the bone that spans it, and takes the colour of the
    # joint it ends at.
    for bone in bones:
        for child in bone.children:
            if child.name in SPLAYED:
                continue
            depth = 0.76 if child.name in TORSO else 0.88
            fraction = FRACTION.get(child.name, 1.0)
            end = bone.head_local.lerp(child.head_local, fraction)
            body.box(bone.name, bone.head_local, end,
                     radius.get(bone.name, 0.05),
                     radius.get(child.name, 0.05) if fraction == 1.0 else radius.get(bone.name, 0.05),
                     side_of(child.name), depth)

    # A block across the hip joints, and another across the collars. Without
    # them the pelvis is two diagonal stubs with a hole between, and the
    # shoulders are a wedge laid over the chest.
    body.box("Hips", bones["LeftUpperLeg"].head_local, bones["RightUpperLeg"].head_local,
             0.098, 0.098, CENTRE, 0.78)
    body.box("UpperChest", bones["LeftShoulder"].head_local, bones["RightShoulder"].head_local,
             0.078, 0.078, CENTRE, 0.78)

    head = bones["Head"]
    up = Vector((0.0, 0.0, 1.0))
    forward = Vector(FORWARD)
    # The skull straddles its joint rather than sitting on top of it, which is
    # what closes the gap left by the shortened neck.
    body.box("Head", head.head_local - up * 0.085, head.head_local + up * 0.105,
             0.070, 0.064, CENTRE, 1.10)
    body.box("Head", head.head_local + up * 0.005 + forward * 0.068,
             head.head_local + up * 0.005 + forward * 0.125, 0.020, 0.016, FACE, 1.0)
    for name in ("LeftHand", "RightHand", "LeftToes", "RightToes"):
        bone = bones[name]
        body.box(name, bone.head_local, bone.tail_local,
                 radius[name], radius[name] * 0.8, side_of(name), 1.0)

    mesh = bpy.data.meshes.new("MannequinBody")
    mesh.from_pydata([tuple(v) for v in body.vertices], [], body.faces)
    mesh.validate()
    for name, colour, roughness in MATERIALS:
        material = bpy.data.materials.get(name) or bpy.data.materials.new(name)
        material.use_nodes = True
        shader = material.node_tree.nodes["Principled BSDF"]
        shader.inputs["Base Color"].default_value = colour
        shader.inputs["Roughness"].default_value = roughness
        mesh.materials.append(material)
    for polygon, index in zip(mesh.polygons, body.face_material):
        polygon.material_index = index
    mesh.update()

    obj = bpy.data.objects.new("MannequinBody", mesh)
    collection.objects.link(obj)
    for name, indices in body.groups.items():
        obj.vertex_groups.new(name=name).add(indices, 1.0, "REPLACE")
    obj.parent = armature
    obj.modifiers.new("Armature", "ARMATURE").object = armature
    return obj


def clear():
    """Drop anything a previous run left behind, so this can be re-run."""
    for name in ("MannequinBody", "Mannequin"):
        obj = bpy.data.objects.get(name)
        if obj is None:
            continue
        data = obj.data
        bpy.data.objects.remove(obj, do_unlink=True)
        if isinstance(data, bpy.types.Mesh):
            bpy.data.meshes.remove(data)
        elif isinstance(data, bpy.types.Armature):
            bpy.data.armatures.remove(data)


def main():
    clear()
    collection = bpy.data.collections.get("KimodoMannequin")
    if collection is None:
        collection = bpy.data.collections.new("KimodoMannequin")
        bpy.context.scene.collection.children.link(collection)

    armature = build_armature(collection, rest_positions())
    body = build_body(collection, armature)

    for obj in bpy.context.view_layer.objects:
        obj.select_set(False)
    armature.select_set(True)
    body.select_set(True)
    bpy.context.view_layer.objects.active = armature

    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=OUTPUT, export_format="GLB", use_selection=True, export_yup=True,
        export_skins=True, export_animations=False, export_materials="EXPORT",
        export_apply=False)
    print("wrote %s (%d bytes)" % (OUTPUT, os.path.getsize(OUTPUT)))


if __name__ == "__main__":
    main()
