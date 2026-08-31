#!/usr/bin/env python3
"""Report authored geometry and render state using igb-blender's parser."""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
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
    image_convert_module = __import__(
        f"{package_name}.utils.image_convert",
        fromlist=["convert_image_to_rgba"],
    )
    return (
        reader_module,
        classes_module,
        geometry_module,
        materials_module,
        lights_module,
        image_convert_module,
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


def fnv1a64(data: bytes) -> str:
    value = 0xCBF29CE484222325
    for byte in data:
        value ^= byte
        value = (value * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return f"{value:016x}"


def ps2_csm1_upload_clut(clut_data: bytes) -> bytes:
    """Arrange linear RGBA32 entries for a 16x16 CSM1 host upload."""
    entries = len(clut_data) // 4
    if entries != 256:
        return b""

    upload = bytearray(len(clut_data))
    for logical_index in range(entries):
        upload_index = (
            (logical_index & ~0x18)
            | ((logical_index & 0x08) << 1)
            | ((logical_index & 0x10) >> 1)
        )
        source = logical_index * 4
        destination = upload_index * 4
        upload[destination : destination + 4] = clut_data[source : source + 4]
    return bytes(upload)


def ps2_gs_csm1_upload_clut(clut_data: bytes) -> bytes:
    """Convert IGB alpha to GS alpha, then arrange a CSM1 host upload."""
    gs_clut = bytearray(clut_data)
    for alpha in range(3, len(gs_clut), 4):
        gs_clut[alpha] = (gs_clut[alpha] + 1) // 2
    return ps2_csm1_upload_clut(bytes(gs_clut))


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
    parser.add_argument(
        "--light-graph",
        action="store_true",
        help="Report raw light-set, light-state, and light-attribute relationships",
    )
    parser.add_argument(
        "--summary",
        action="store_true",
        help="Report aggregate geometry, vertex-color, lighting, and texture state",
    )
    parser.add_argument(
        "--texture-details",
        action="store_true",
        help="Report hashes and index usage for unique matching textures",
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
        image_convert,
    ) = load_plugin(args.plugin_root.resolve())

    reader = reader_module.IGBReader(str(args.igb.resolve()))
    reader.read()
    graph = classes_module.SceneGraph(reader)
    if not graph.build():
        raise RuntimeError("igb-blender could not find an Alchemy scene root")

    collector = GeometryCollector()
    graph.walk(collector)
    matcher = re.compile(args.filter, re.IGNORECASE) if args.filter else None

    if args.light_graph:
        object_types = {
            b"igLightAttr",
            b"igLightList",
            b"igLightSet",
            b"igLightStateAttr",
            b"igLightStateAttrList",
            b"igLightStateSet",
        }
        graph_rows = []
        for obj in reader.objects:
            if not hasattr(obj, "type_name") or obj.type_name not in object_types:
                continue
            fields = []
            for slot, value, field in obj._raw_fields:
                field_name = field.short_name.decode("ascii", errors="replace")
                field_row = {
                    "slot": slot,
                    "field": field_name,
                    "value": value,
                }
                if field_name == "ObjectRef" and value != -1:
                    target = reader.resolve_ref(value)
                    if hasattr(target, "type_name"):
                        field_row["target_index"] = target.index
                        field_row["target_type"] = target.type_name.decode(
                            "ascii", errors="replace"
                        )
                        target_name = object_name(target)
                        if target_name:
                            field_row["target_name"] = target_name
                fields.append(field_row)

            row = {
                "index": obj.index,
                "type": obj.type_name.decode("ascii", errors="replace"),
                "fields": fields,
            }
            name = object_name(obj)
            if name:
                row["name"] = name
            if obj.type_name in (b"igLightList", b"igLightStateAttrList"):
                row["items"] = [
                    {
                        "index": item.index,
                        "type": item.type_name.decode("ascii", errors="replace"),
                    }
                    for item in reader.resolve_object_list(obj)
                    if hasattr(item, "type_name")
                ]
            graph_rows.append(row)

        json.dump(graph_rows, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0

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
    texture_details = {}

    for attr, transform, parent, state in collector.instances:
        geometry = geometry_module.extract_geometry(reader, attr)
        material = materials.extract_material(reader, state["material"])
        textures = []
        for unit, texture_obj in sorted(state["textures"].items()):
            texture = materials.extract_texture_bind(reader, texture_obj)
            if texture is None or texture.image is None:
                continue
            image = texture.image
            textures.append(
                {
                    "unit": unit,
                    "name": image.name,
                    "image_object_index": image.source_obj.index,
                    "width": image.width,
                    "height": image.height,
                    "pixel_format": image.pixel_format,
                    "clut_entries": image.clut_num_entries,
                }
            )
            if args.texture_details and image.source_obj.index not in texture_details:
                pixel_data = image.pixel_data or b""
                clut_data = image.clut_data or b""
                csm1_upload_clut = ps2_csm1_upload_clut(clut_data)
                gs_csm1_upload_clut = ps2_gs_csm1_upload_clut(clut_data)
                decoded = image_convert.convert_image_to_rgba(image) or b""
                indices = Counter(pixel_data[: image.width * image.height])
                texture_details[image.source_obj.index] = {
                    "image_object_index": image.source_obj.index,
                    "name": image.name,
                    "width": image.width,
                    "height": image.height,
                    "pixel_format": image.pixel_format,
                    "pixel_bytes": len(pixel_data),
                    "pixel_fnv1a64": fnv1a64(pixel_data),
                    "pixel_sha256": hashlib.sha256(pixel_data).hexdigest(),
                    "clut_entries": image.clut_num_entries,
                    "clut_bytes": len(clut_data),
                    "clut_fnv1a64": fnv1a64(clut_data),
                    "clut_sha256": hashlib.sha256(clut_data).hexdigest(),
                    "csm1_upload_clut_bytes": len(csm1_upload_clut),
                    "csm1_upload_clut_fnv1a64": fnv1a64(csm1_upload_clut),
                    "csm1_upload_clut_sha256": hashlib.sha256(
                        csm1_upload_clut
                    ).hexdigest(),
                    "gs_csm1_upload_clut_bytes": len(gs_csm1_upload_clut),
                    "gs_csm1_upload_clut_fnv1a64": fnv1a64(gs_csm1_upload_clut),
                    "gs_csm1_upload_clut_sha256": hashlib.sha256(
                        gs_csm1_upload_clut
                    ).hexdigest(),
                    "decoded_rgba_bytes": len(decoded),
                    "decoded_rgba_fnv1a64": fnv1a64(decoded),
                    "decoded_rgba_sha256": hashlib.sha256(decoded).hexdigest(),
                    "unique_indices": len(indices),
                    "most_common_indices": indices.most_common(16),
                }

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
        if geometry is not None and geometry.colors:
            color_count = len(geometry.colors)
            row["vertex_color_min"] = [
                min(color[lane] for color in geometry.colors) for lane in range(4)
            ]
            row["vertex_color_mean"] = [
                sum(color[lane] for color in geometry.colors) / color_count
                for lane in range(4)
            ]
            row["vertex_color_max"] = [
                max(color[lane] for color in geometry.colors) for lane in range(4)
            ]
        searchable = "\n".join(
            [row["name"]] + [texture["name"] for texture in textures]
        )
        if matcher is None or matcher.search(searchable):
            rows.append(row)

    if args.texture_details:
        filtered_details = []
        matching_image_indices = {
            texture["image_object_index"]
            for row in rows
            for texture in row["textures"]
        }
        for image_index in sorted(matching_image_indices):
            detail = texture_details.get(image_index)
            if detail is not None:
                filtered_details.append(detail)
        json.dump(filtered_details, sys.stdout, indent=2, sort_keys=True)
    elif args.summary:
        color_rows = [row for row in rows if row["has_vertex_colors"]]
        color_vertex_count = sum(row["vertex_count"] for row in color_rows)
        weighted_color_mean = [0.0, 0.0, 0.0, 0.0]
        if color_vertex_count:
            for lane in range(4):
                weighted_color_mean[lane] = sum(
                    row["vertex_color_mean"][lane] * row["vertex_count"]
                    for row in color_rows
                ) / color_vertex_count

        lighting_counts = Counter(
            "inherited" if row["lighting"] is None else
            "enabled" if row["lighting"]["enabled"] else "disabled"
            for row in rows
        )
        texture_counts = Counter(
            (
                texture["pixel_format"],
                texture["clut_entries"],
            )
            for row in rows
            for texture in row["textures"]
        )
        summary = {
            "instances": len(rows),
            "unique_geometry": len({row["geometry_index"] for row in rows}),
            "vertices": sum(row["vertex_count"] for row in rows),
            "instances_with_vertex_colors": len(color_rows),
            "vertices_with_vertex_colors": color_vertex_count,
            "vertex_color_min": [
                min(row["vertex_color_min"][lane] for row in color_rows)
                if color_rows else None
                for lane in range(4)
            ],
            "vertex_color_mean": weighted_color_mean,
            "vertex_color_max": [
                max(row["vertex_color_max"][lane] for row in color_rows)
                if color_rows else None
                for lane in range(4)
            ],
            "lighting_state_instances": dict(sorted(lighting_counts.items())),
            "texture_bindings": [
                {
                    "pixel_format": pixel_format,
                    "clut_entries": clut_entries,
                    "count": count,
                }
                for (pixel_format, clut_entries), count in sorted(texture_counts.items())
            ],
        }
        json.dump(summary, sys.stdout, indent=2, sort_keys=True)
    else:
        json.dump(rows, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
