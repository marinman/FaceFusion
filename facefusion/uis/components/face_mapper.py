"""Give each face in the video its own replacement photo.

One row per face found in the current frame: the face on the left, an upload box
on the right. Faces left empty are not touched.
"""

from typing import List, Optional

import cv2
import gradio

from facefusion import face_map, state_manager
from facefusion.face_creator import get_many_faces
from facefusion.face_selector import sort_and_filter_faces
from facefusion.filesystem import is_image, is_video
from facefusion.types import VisionFrame
from facefusion.uis.core import get_ui_component, get_ui_components, register_ui_component
from facefusion.vision import fit_cover_frame, read_static_image, read_video_frame

MAX_SLOTS = 8
FACE_MAPPER_GROUP : Optional[gradio.Group] = None
FACE_MAPPER_HINT : Optional[gradio.Markdown] = None
FACE_MAPPER_ROWS : List[gradio.Row] = []
FACE_MAPPER_THUMBS : List[gradio.Image] = []
FACE_MAPPER_SOURCES : List[gradio.Image] = []
FACE_MAPPER_CLEAR_BUTTON : Optional[gradio.Button] = None

HINT_TEXT = '### 👥 Swap several faces at once\nEach face found in this frame gets its own box. Drop a photo next to a face to replace it; leave a box empty to leave that person alone. This overrides the single face picker above.'


def render() -> None:
	global FACE_MAPPER_GROUP
	global FACE_MAPPER_HINT
	global FACE_MAPPER_CLEAR_BUTTON

	face_map.clear_face_map()
	thumbs = extract_face_thumbs()
	FACE_MAPPER_HINT = gradio.Markdown(HINT_TEXT)

	with gradio.Group() as FACE_MAPPER_GROUP:
		for index in range(MAX_SLOTS):
			with gradio.Row(visible = index < len(thumbs)) as row:
				thumb = gradio.Image(
					value = thumbs[index] if index < len(thumbs) else None,
					label = f'Face {index + 1}',
					interactive = False,
					show_download_button = False,
					height = 140
				)
				source = gradio.Image(
					label = f'Replace face {index + 1} with…',
					sources = [ 'upload' ],
					type = 'filepath',
					height = 140
				)
			FACE_MAPPER_ROWS.append(row)
			FACE_MAPPER_THUMBS.append(thumb)
			FACE_MAPPER_SOURCES.append(source)
		FACE_MAPPER_CLEAR_BUTTON = gradio.Button('Clear all face assignments', size = 'sm')

	register_ui_component('face_mapper_group', FACE_MAPPER_GROUP)


def listen() -> None:
	for index, source in enumerate(FACE_MAPPER_SOURCES):
		source.change(update_face_map_slot(index), inputs = source)
		source.clear(update_face_map_slot(index), inputs = source)
	FACE_MAPPER_CLEAR_BUTTON.click(clear_all_slots, outputs = FACE_MAPPER_SOURCES)

	for ui_component in get_ui_components([ 'target_image', 'target_video' ]):
		for method in [ 'change', 'clear' ]:
			getattr(ui_component, method)(reset_and_refresh, outputs = FACE_MAPPER_ROWS + FACE_MAPPER_THUMBS + FACE_MAPPER_SOURCES)

	preview_frame_slider = get_ui_component('preview_frame_slider')
	if preview_frame_slider:
		for method in [ 'change', 'release' ]:
			getattr(preview_frame_slider, method)(refresh_rows, inputs = preview_frame_slider, outputs = FACE_MAPPER_ROWS + FACE_MAPPER_THUMBS, show_progress = 'hidden')


def update_face_map_slot(index : int):
	def apply(source_path : Optional[str]) -> None:
		face_map.set_face_map_path(index, source_path)
	return apply


def clear_all_slots() -> List[gradio.Image]:
	face_map.clear_face_map()
	return [ gradio.Image(value = None) for _ in FACE_MAPPER_SOURCES ]


def reset_and_refresh(frame_number : Optional[int] = None) -> List:
	face_map.clear_face_map()
	rows_and_thumbs = refresh_rows(frame_number)
	return rows_and_thumbs + [ gradio.Image(value = None) for _ in FACE_MAPPER_SOURCES ]


def refresh_rows(frame_number : Optional[int] = None) -> List:
	thumbs = extract_face_thumbs(frame_number)
	rows = [ gradio.Row(visible = index < len(thumbs)) for index in range(MAX_SLOTS) ]
	images = [ gradio.Image(value = thumbs[index] if index < len(thumbs) else None) for index in range(MAX_SLOTS) ]
	return rows + images


def read_reference_frame(frame_number : Optional[int] = None) -> Optional[VisionFrame]:
	target_path = state_manager.get_item('target_path')

	if is_image(target_path):
		return read_static_image(target_path)
	if is_video(target_path):
		if frame_number is None:
			frame_number = state_manager.get_item('reference_frame_number') or 0
		return read_video_frame(target_path, frame_number)
	return None


def extract_face_thumbs(frame_number : Optional[int] = None) -> List[VisionFrame]:
	vision_frame = read_reference_frame(frame_number)

	if vision_frame is None:
		return []
	faces = sort_and_filter_faces([], get_many_faces([ vision_frame ]))
	thumbs = []

	for face in faces[:MAX_SLOTS]:
		start_x, start_y, end_x, end_y = map(int, face.bounding_box)
		padding_x = int((end_x - start_x) * 0.25)
		padding_y = int((end_y - start_y) * 0.25)
		crop_vision_frame = vision_frame[max(0, start_y - padding_y):end_y + padding_y, max(0, start_x - padding_x):end_x + padding_x]

		if crop_vision_frame.size:
			crop_vision_frame = fit_cover_frame(crop_vision_frame, (160, 160))
			thumbs.append(cv2.cvtColor(crop_vision_frame, cv2.COLOR_BGR2RGB))

	return thumbs
