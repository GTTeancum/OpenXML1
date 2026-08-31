#!/usr/bin/env python3
"""Report authored geometry and render state using igb-blender's parser."""

from __future__ import annotations

import argparse
import json
import re
import sys
import types
from pathlib import Path


def load_plugin(plugin_root: Path):
    """Load pure parser modules without importing Blender's bpy entry point."""
    package_name = "igb_scene_inspector_plugin"
    package = types.ModuleType(package_name)
    package.__path__ = [str(plugin_root)]
    sys.modules[package_name] = package

    reader_module = __import__(
        f"{package_name}.igb_format.igb_reader",
        fromlist=["IGBReader"],
    )
    classes_module = __import__(
        f"{package_name}.scene_graph.sg_classes",
        fromlist=["SceneGraph"],
    )
    geometry_module = __import__(
        f"{package_name}.scene_graph.sg_geometry",
        fromlist=["extract_geometry"],
    )
    materials_module = __import__(
        f"{package_name}.scene_graph.sg_materials",
        fromlist=[
            "extract_alpha_function",
            "extract_alpha_state",
            "extract_blend_function",
            "extract_blend_state",
            "extract_color_attr",
            "extract_lighting_state",
            "extract_material",
            "extract_texture_bind",
        ],
    )
    lights_module = __import__(
        f"{package_name}.scene_graph.sg_lights",
        fromlist=["extract_lights_from_light_set"],
    )
    return (
        reader_module,
        classes_module,
        geometry_module,
        materials_module,
        lights_module,
    )


def object_name(obj) -> str:
    if obj is None:
        return ""
    for slot, value, field in obj._raw_fields:
        if slot == 2 and field.short_name == b"String":
            if isinstance(value, bytes):
                return value.decode("utf-8", errors="replace")
            return value if isinstance(value, str) else ""
    return ""


class GeometryCollector:
    """Mirror igb-blender's inherited AttrSet state without importing bpy."""

    STATE_KEYS = (
        "material",
        "textures",
        "blend_state",
        "blend_function",
        "alpha_state",
        "alpha_function",
        "color",
        "lighting",
    )

    def __init__(self):
        self.state = {key: None for key in self.STATE_KEYS}
        self.state["textures"] = {}
        self.stack = []
        self.instances = []
        self.light_sets = []

    def push_state(self):
        saved = dict(self.state)
        saved["textures"] = dict(self.state["textures"])
        self.stack.append(saved)

    def pop_state(self):
        self.state = self.stack.pop()

    def visit_material_attr(self, attr, _parent):
        self.state["material"] = attr

    def visit_texture_bind_attr(self, attr, _parent):
        unit = 0
        for _slot, value, field in attr._raw_fields:
            if field.short_name == b"Int":
                unit = value
                break
        self.state["textures"][unit] = attr

    def visit_blend_state_attr(self, attr, _parent):
        self.state["blend_state"] = attr

    def visit_blend_function_attr(self, attr, _parent):
        self.state["blend_function"] = attr

    def visit_alpha_state_attr(self, attr, _parent):
        self.state["alpha_state"] = attr

    def visit_alpha_function_attr(self, attr, _parent):
        self.state["alpha_function"] = attr

    def visit_color_attr(self, attr, _parent):
        self.state["color"] = attr

    def visit_lighting_state_attr(self, attr, _parent):
        self.state["lighting"] = attr

    def visit_geometry_attr(self, attr, transform, parent):
        snapshot = dict(self.state)
        snapshot["textures"] = dict(self.state["textures"])
        self.instances.append((attr, transform, parent, snapshot))

    def visit_light_set(self, light_set, transform):
        self.light_sets.append((light_set, transform))


def parse_args():
    github_root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("igb", type=Path)
    parser.add_argument(
        "--plugin-root",
        type=Path,
        default=github_root / "igb-blender",
        help="Path to the igb-blender checkout",
    )
    parser.add_argument(
        "--filter",
        default="",
        help="Case-insensitive regular expression matched against names and textures",
    )
    parser.add_argument(
        "--lights-only",
        action="store_true",
        help="Report authored igLightSet values instead of geometry state",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    (
        reader_module,
        classes_module,
        geometry_module,
        materials,
        lights,
    ) = load_plugin(args.plugin_root.resolve())

    reader = reader_module.IGBReader(str(args.igb.resolve()))
    reader.read()
    graph = classes_module.SceneGraph(reader)
    if not graph.build():
        raise RuntimeError("igb-blender could not find an Alchemy scene root")

    collector = GeometryCollector()
    graph.walk(collector)
    matcher = re.compile(args.filter, re.IGNORECASE) if args.filter else None

    if args.lights_only:
        light_rows = []
        for light_set, transform in collector.light_sets:
            for light in lights.extract_lights_from_light_set(reader, light_set):
                row = {
                    "name": light.node_name,
                    "type": light.blender_type,
                    "light_id": light.light_id,
                    "position": list(light.position),
                    "ambient": list(light.ambient),
                    "diffuse": list(light.diffuse),
                    "specular": list(light.specular),
                    "direction": list(light.direction),
                    "falloff": light.falloff,
                    "cutoff": light.cutoff,
                    "attenuation": list(light.attenuation),
                    "shininess": light.shininess,
                    "cast_shadow": light.cast_shadow,
                    "translation": list(transform[12:15]) if transform is not None else None,
                }
                if matcher is None or matcher.search(row["name"]):
                    light_rows.append(row)
        json.dump(light_rows, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0

    rows = []

    for attr, transform, parent, state in collector.instances:
        geometry = geometry_module.extract_geometry(reader, attr)
        material = materials.extract_material(reader, state["material"])
        textures = []
        for unit, texture_obj in sorted(state["textures"].items()):
            texture = materials.extract_texture_bind(reader, texture_obj)
            if texture is None or texture.image is None:
                continue
            textures.append(
                {
                    "unit": unit,
                    "name": texture.image.name,
                    "width": texture.image.width,
                    "height": texture.image.height,
                    "pixel_format": texture.image.pixel_format,
                    "clut_entries": texture.image.clut_num_entries,
                }
            )

        row = {
            "geometry_index": attr.index,
            "attr_set_index": parent.index if parent is not None else None,
            "name": object_name(parent),
            "translation": list(transform[12:15]) if transform is not None else None,
            "vertex_count": geometry.num_verts if geometry is not None else 0,
            "triangle_index_count": len(geometry.indices) if geometry is not None else 0,
            "has_normals": geometry.has_normals if geometry is not None else False,
            "has_vertex_colors": geometry.has_colors if geometry is not None else False,
            "material_index": state["material"].index if state["material"] is not None else None,
            "diffuse": list(material.diffuse) if material is not None else None,
            "ambient": list(material.ambient) if material is not None else None,
            "specular": list(material.specular) if material is not None else None,
            "emission": list(material.emission) if material is not None else None,
            "textures": textures,
            "blend_state": materials.extract_blend_state(reader, state["blend_state"]),
            "blend_function": materials.extract_blend_function(reader, state["blend_function"]),
            "alpha_state": materials.extract_alpha_state(reader, state["alpha_state"]),
            "alpha_function": materials.extract_alpha_function(reader, state["alpha_function"]),
            "color": materials.extract_color_attr(reader, state["color"]),
            "lighting": materials.extract_lighting_state(reader, state["lighting"]),
        }
        searchable = "\n".join(
            [row["name"]] + [texture["name"] for texture in textures]
        )
        if matcher is None or matcher.search(searchable):
            rows.append(row)

    json.dump(rows, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
