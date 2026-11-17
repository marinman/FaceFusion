"""Per-face source mapping: give each face in the target its own photo.

The UI stores a plain dict of {face slot -> source image path} in state. At
process time we re-detect the faces in the reference frame, index them the same
way the picker does, and hand each target face the source face mapped to the
reference face it matches.
"""

from typing import Dict, List, Optional

from facefusion import state_manager
from facefusion.common_helper import get_first, get_middle
from facefusion.face_creator import get_static_faces
from facefusion.face_selector import calculate_face_distance, sort_and_filter_faces, sort_faces_by_order
from facefusion.face_tracker import track_faces
from facefusion.types import Face, VisionFrame
from facefusion.filesystem import is_image, is_video
from facefusion.vision import read_static_image, read_static_video_frame

FaceMapPaths = Dict[int, str]


def get_face_map_paths() -> FaceMapPaths:
	face_map_paths = state_manager.get_item('face_map_paths') or {}
	return { int(index) : path for index, path in face_map_paths.items() if path }


def has_face_map() -> bool:
	return bool(get_face_map_paths())


def set_face_map_path(index : int, source_path : Optional[str]) -> None:
	face_map_paths = dict(get_face_map_paths())

	if source_path:
		face_map_paths[int(index)] = source_path
	else:
		face_map_paths.pop(int(index), None)
	state_manager.set_item('face_map_paths', face_map_paths)


def clear_face_map() -> None:
	state_manager.set_item('face_map_paths', {})


def select_all_faces(target_vision_frames : List[VisionFrame]) -> List[Face]:
	"""Every face in the frame, regardless of the single-face selector mode."""
	if state_manager.get_item('face_tracker_score') > 0:
		target_faces = track_faces(target_vision_frames, state_manager.get_item('face_tracker_score'))
	else:
		target_faces = get_static_faces([ get_middle(target_vision_frames) ])
	return sort_and_filter_faces([], target_faces)


def read_reference_frame() -> Optional[VisionFrame]:
	"""The frame the face slots were numbered against.

	The workflow only hands the processor a reference frame when a source image
	is set, which a face-map run does not need, so fall back to reading it.
	"""
	target_path = state_manager.get_item('target_path')

	if is_image(target_path):
		return read_static_image(target_path)
	if is_video(target_path):
		return read_static_video_frame(target_path, state_manager.get_item('reference_frame_number') or 0)
	return None


def index_reference_faces(reference_vision_frame : Optional[VisionFrame]) -> List[Face]:
	if reference_vision_frame is None:
		reference_vision_frame = read_reference_frame()
	if reference_vision_frame is None:
		return []
	return sort_and_filter_faces([], get_static_faces([ reference_vision_frame ]))


def resolve_source_face(source_path : str) -> Optional[Face]:
	source_vision_frame = read_static_image(source_path)

	if source_vision_frame is None:
		return None
	source_faces = sort_faces_by_order(get_static_faces([ source_vision_frame ]), 'large-small')
	return get_first(source_faces)


def resolve_source_frame(source_path : str) -> Optional[VisionFrame]:
	return read_static_image(source_path)


def match_face_slot(target_face : Face, reference_faces : List[Face], face_distance : float) -> Optional[int]:
	"""Which mapped slot does this target face belong to, if any.

	`face_distance` is the UI's 0..1 strictness; raw embedding distance is 0..2.
	"""
	match_index = None
	match_distance = face_distance * 2

	for index, reference_face in enumerate(reference_faces):
		distance = calculate_face_distance(target_face, reference_face)

		if distance < match_distance:
			match_distance = distance
			match_index = index

	return match_index
