from typing import List, Optional, Tuple

import cv2
import gradio
from gradio_rangeslider import RangeSlider

import facefusion.choices
from facefusion import state_manager, translator
from facefusion.common_helper import calculate_float_step, calculate_int_step
from facefusion.face_creator import get_many_faces
from facefusion.face_selector import sort_and_filter_faces
from facefusion.face_store import clear_faces
from facefusion.filesystem import filter_image_paths, is_image, is_video
from facefusion.types import FaceSelectorGender, FaceSelectorMode, FaceSelectorOrder, FaceSelectorRace, VisionFrame
from facefusion.uis.core import get_ui_component, get_ui_components, register_ui_component
from facefusion.uis.types import ComponentOptions
from facefusion.uis.ui_helper import convert_str_none
from facefusion.vision import fit_cover_frame, read_static_image, read_static_images, read_video_frame

FACE_SELECTOR_MODE_DROPDOWN : Optional[gradio.Dropdown] = None
FACE_SELECTOR_ORDER_DROPDOWN : Optional[gradio.Dropdown] = None
FACE_SELECTOR_GENDER_DROPDOWN : Optional[gradio.Dropdown] = None
FACE_SELECTOR_RACE_DROPDOWN : Optional[gradio.Dropdown] = None
FACE_SELECTOR_AGE_RANGE_SLIDER : Optional[RangeSlider] = None
REFERENCE_FACE_POSITION_GALLERY : Optional[gradio.Gallery] = None
REFERENCE_FACE_DISTANCE_SLIDER : Optional[gradio.Slider] = None
FACE_MAP_IMAGE : Optional[gradio.Image] = None
FACE_SELECTOR_HINT : Optional[gradio.Markdown] = None

SELECTED_COLOR = (80, 220, 60)
OTHER_COLOR = (170, 170, 170)
HINT_TEXT = '### 🎯 Pick the face to replace\nClick a face below. It turns **green** in the frame map; that person gets your new face. Gray faces are left alone.'


def render() -> None:
	global FACE_SELECTOR_MODE_DROPDOWN
	global FACE_SELECTOR_ORDER_DROPDOWN
	global FACE_SELECTOR_GENDER_DROPDOWN
	global FACE_SELECTOR_RACE_DROPDOWN
	global FACE_SELECTOR_AGE_RANGE_SLIDER
	global REFERENCE_FACE_POSITION_GALLERY
	global REFERENCE_FACE_DISTANCE_SLIDER
	global FACE_MAP_IMAGE
	global FACE_SELECTOR_HINT

	reference_face_gallery_options : ComponentOptions =\
	{
		'label': 'Faces in this frame (click one)',
		'columns': 6,
		'height': 'auto',
		'object_fit': 'cover',
		'allow_preview': False,
		'elem_classes': 'box-face-selector',
		'visible': 'reference' in state_manager.get_item('face_selector_mode')
	}
	source_vision_frames = read_static_images(filter_image_paths(state_manager.get_item('source_paths')))

	if is_image(state_manager.get_item('target_path')):
		target_vision_frame = read_static_image(state_manager.get_item('target_path'))
		reference_face_gallery_options['value'] = extract_gallery_frames(source_vision_frames, target_vision_frame)
	if is_video(state_manager.get_item('target_path')):
		target_vision_frame = read_video_frame(state_manager.get_item('target_path'), state_manager.get_item('reference_frame_number'))
		reference_face_gallery_options['value'] = extract_gallery_frames(source_vision_frames, target_vision_frame)
	FACE_SELECTOR_MODE_DROPDOWN = gradio.Dropdown(
		label = translator.get('uis.face_selector_mode_dropdown'),
		choices = facefusion.choices.face_selector_modes,
		value = state_manager.get_item('face_selector_mode')
	)
	is_reference = 'reference' in state_manager.get_item('face_selector_mode')
	FACE_SELECTOR_HINT = gradio.Markdown(HINT_TEXT, visible = is_reference)
	REFERENCE_FACE_POSITION_GALLERY = gradio.Gallery(**reference_face_gallery_options)
	FACE_MAP_IMAGE = gradio.Image(
		label = 'Frame map: green = will be replaced',
		value = build_face_map(),
		interactive = False,
		show_download_button = False,
		visible = is_reference
	)
	with gradio.Group():
		with gradio.Row():
			FACE_SELECTOR_ORDER_DROPDOWN = gradio.Dropdown(
				label = translator.get('uis.face_selector_order_dropdown'),
				choices = facefusion.choices.face_selector_orders,
				value = state_manager.get_item('face_selector_order')
			)
			FACE_SELECTOR_GENDER_DROPDOWN = gradio.Dropdown(
				label = translator.get('uis.face_selector_gender_dropdown'),
				choices = [ 'none' ] + facefusion.choices.face_selector_genders,
				value = state_manager.get_item('face_selector_gender') or 'none'
			)
			FACE_SELECTOR_RACE_DROPDOWN = gradio.Dropdown(
				label = translator.get('uis.face_selector_race_dropdown'),
				choices = [ 'none' ] + facefusion.choices.face_selector_races,
				value = state_manager.get_item('face_selector_race') or 'none'
			)
		with gradio.Row():
			face_selector_age_start = state_manager.get_item('face_selector_age_start') or facefusion.choices.face_selector_age_range[0]
			face_selector_age_end = state_manager.get_item('face_selector_age_end') or facefusion.choices.face_selector_age_range[-1]
			FACE_SELECTOR_AGE_RANGE_SLIDER = RangeSlider(
				label = translator.get('uis.face_selector_age_range_slider'),
				minimum = facefusion.choices.face_selector_age_range[0],
				maximum = facefusion.choices.face_selector_age_range[-1],
				value = (face_selector_age_start, face_selector_age_end),
				step = calculate_int_step(facefusion.choices.face_selector_age_range)
			)
	REFERENCE_FACE_DISTANCE_SLIDER = gradio.Slider(
		label = translator.get('uis.reference_face_distance_slider'),
		value = state_manager.get_item('reference_face_distance'),
		step = calculate_float_step(facefusion.choices.reference_face_distance_range),
		minimum = facefusion.choices.reference_face_distance_range[0],
		maximum = facefusion.choices.reference_face_distance_range[-1],
		visible = 'reference' in state_manager.get_item('face_selector_mode')
	)
	register_ui_component('face_selector_mode_dropdown', FACE_SELECTOR_MODE_DROPDOWN)
	register_ui_component('face_selector_order_dropdown', FACE_SELECTOR_ORDER_DROPDOWN)
	register_ui_component('face_selector_gender_dropdown', FACE_SELECTOR_GENDER_DROPDOWN)
	register_ui_component('face_selector_race_dropdown', FACE_SELECTOR_RACE_DROPDOWN)
	register_ui_component('face_selector_age_range_slider', FACE_SELECTOR_AGE_RANGE_SLIDER)
	register_ui_component('reference_face_position_gallery', REFERENCE_FACE_POSITION_GALLERY)
	register_ui_component('reference_face_distance_slider', REFERENCE_FACE_DISTANCE_SLIDER)


def listen() -> None:
	FACE_SELECTOR_MODE_DROPDOWN.change(update_face_selector_mode, inputs = FACE_SELECTOR_MODE_DROPDOWN, outputs = [ REFERENCE_FACE_POSITION_GALLERY, REFERENCE_FACE_DISTANCE_SLIDER, FACE_MAP_IMAGE, FACE_SELECTOR_HINT ])
	FACE_SELECTOR_ORDER_DROPDOWN.change(update_face_selector_order, inputs = FACE_SELECTOR_ORDER_DROPDOWN, outputs = REFERENCE_FACE_POSITION_GALLERY)
	FACE_SELECTOR_GENDER_DROPDOWN.change(update_face_selector_gender, inputs = FACE_SELECTOR_GENDER_DROPDOWN, outputs = REFERENCE_FACE_POSITION_GALLERY)
	FACE_SELECTOR_RACE_DROPDOWN.change(update_face_selector_race, inputs = FACE_SELECTOR_RACE_DROPDOWN, outputs = REFERENCE_FACE_POSITION_GALLERY)
	FACE_SELECTOR_AGE_RANGE_SLIDER.release(update_face_selector_age_range, inputs = FACE_SELECTOR_AGE_RANGE_SLIDER, outputs = REFERENCE_FACE_POSITION_GALLERY)
	REFERENCE_FACE_DISTANCE_SLIDER.release(update_reference_face_distance, inputs = REFERENCE_FACE_DISTANCE_SLIDER)

	preview_frame_slider = get_ui_component('preview_frame_slider')
	if preview_frame_slider:
		REFERENCE_FACE_POSITION_GALLERY.select(update_reference_frame_number, inputs = preview_frame_slider)
		REFERENCE_FACE_POSITION_GALLERY.select(update_reference_face_position)
		REFERENCE_FACE_POSITION_GALLERY.select(select_face_and_update_map, inputs = preview_frame_slider, outputs = FACE_MAP_IMAGE)
		for method in [ 'change', 'release' ]:
			getattr(preview_frame_slider, method)(update_face_map_for_frame, inputs = preview_frame_slider, outputs = FACE_MAP_IMAGE, show_progress = 'hidden')
	else:
		REFERENCE_FACE_POSITION_GALLERY.select(select_face_and_update_map, outputs = FACE_MAP_IMAGE)

	for ui_component in get_ui_components(
	[
		'target_image',
		'target_video'
	]):
		for method in [ 'change', 'clear' ]:
			getattr(ui_component, method)(clear_reference_frame_number)
			getattr(ui_component, method)(clear_reference_face_position)
			getattr(ui_component, method)(update_reference_position_gallery, outputs = REFERENCE_FACE_POSITION_GALLERY)
			getattr(ui_component, method)(update_face_map_for_frame, outputs = FACE_MAP_IMAGE)

	for ui_component in get_ui_components([ 'source_image' ]):
		for method in [ 'change', 'clear' ]:
			getattr(ui_component, method)(update_face_map_for_frame, outputs = FACE_MAP_IMAGE)

	for ui_component in get_ui_components(
	[
		'face_detector_model_dropdown',
		'face_detector_size_dropdown',
		'face_detector_angles_checkbox_group'
	]):
		ui_component.change(clear_and_update_reference_position_gallery, outputs = REFERENCE_FACE_POSITION_GALLERY)

	face_detector_score_slider = get_ui_component('face_detector_score_slider')
	if face_detector_score_slider:
		face_detector_score_slider.release(update_reference_position_gallery, outputs = REFERENCE_FACE_POSITION_GALLERY)

	preview_frame_slider = get_ui_component('preview_frame_slider')
	if preview_frame_slider:
		for method in [ 'change', 'release' ]:
			getattr(preview_frame_slider, method)(update_reference_position_gallery, inputs = preview_frame_slider, outputs = REFERENCE_FACE_POSITION_GALLERY, show_progress = 'hidden')


def update_face_selector_mode(face_selector_mode : FaceSelectorMode) -> Tuple[gradio.Gallery, gradio.Slider, gradio.Image, gradio.Markdown]:
	state_manager.set_item('face_selector_mode', face_selector_mode)
	is_reference = face_selector_mode == 'reference'
	return gradio.Gallery(visible = is_reference), gradio.Slider(visible = is_reference), gradio.Image(value = build_face_map() if is_reference else None, visible = is_reference), gradio.Markdown(visible = is_reference)


def select_face_and_update_map(event : gradio.SelectData, frame_number : Optional[int] = None) -> gradio.Image:
	state_manager.set_item('reference_face_position', event.index)
	if frame_number is not None:
		state_manager.set_item('reference_frame_number', frame_number)
	return gradio.Image(value = build_face_map(frame_number))


def update_face_map_for_frame(frame_number : Optional[int] = None) -> gradio.Image:
	return gradio.Image(value = build_face_map(frame_number))


def build_face_map(frame_number : Optional[int] = None) -> Optional[VisionFrame]:
	target_path = state_manager.get_item('target_path')
	if is_image(target_path):
		frame = read_static_image(target_path)
	elif is_video(target_path):
		if frame_number is None:
			frame_number = state_manager.get_item('reference_frame_number') or 0
		frame = read_video_frame(target_path, frame_number)
	else:
		return None
	if frame is None:
		return None
	source_faces = get_many_faces(read_static_images(filter_image_paths(state_manager.get_item('source_paths'))))
	faces = sort_and_filter_faces(source_faces, get_many_faces([ frame ]))
	selected = state_manager.get_item('reference_face_position') or 0
	canvas = frame.copy()
	thickness = max(2, frame.shape[1] // 300)
	scale = max(0.6, frame.shape[1] / 900)
	for index, face in enumerate(faces):
		start_x, start_y, end_x, end_y = map(int, face.bounding_box)
		color = SELECTED_COLOR if index == selected else OTHER_COLOR
		color = (color[2], color[1], color[0])
		cv2.rectangle(canvas, (start_x, start_y), (end_x, end_y), color, thickness * (2 if index == selected else 1))
		label = f'{index + 1}  REPLACE' if index == selected else str(index + 1)
		(text_w, text_h), _ = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, scale, thickness)
		label_y = max(text_h + 8, start_y - 6)
		cv2.rectangle(canvas, (start_x, label_y - text_h - 8), (start_x + text_w + 10, label_y + 4), color, -1)
		cv2.putText(canvas, label, (start_x + 5, label_y - 2), cv2.FONT_HERSHEY_SIMPLEX, scale, (0, 0, 0), thickness, cv2.LINE_AA)
	return cv2.cvtColor(canvas, cv2.COLOR_BGR2RGB)


def update_face_selector_order(face_analyser_order : FaceSelectorOrder) -> gradio.Gallery:
	state_manager.set_item('face_selector_order', convert_str_none(face_analyser_order))
	return update_reference_position_gallery()


def update_face_selector_gender(face_selector_gender : FaceSelectorGender) -> gradio.Gallery:
	state_manager.set_item('face_selector_gender', convert_str_none(face_selector_gender))
	return update_reference_position_gallery()


def update_face_selector_race(face_selector_race : FaceSelectorRace) -> gradio.Gallery:
	state_manager.set_item('face_selector_race', convert_str_none(face_selector_race))
	return update_reference_position_gallery()


def update_face_selector_age_range(face_selector_age_range : Tuple[float, float]) -> gradio.Gallery:
	face_selector_age_start, face_selector_age_end = face_selector_age_range
	state_manager.set_item('face_selector_age_start', int(face_selector_age_start))
	state_manager.set_item('face_selector_age_end', int(face_selector_age_end))
	return update_reference_position_gallery()


def update_reference_face_position(event : gradio.SelectData) -> None:
	state_manager.set_item('reference_face_position', event.index)


def clear_reference_face_position() -> None:
	state_manager.set_item('reference_face_position', 0)


def update_reference_face_distance(reference_face_distance : float) -> None:
	state_manager.set_item('reference_face_distance', reference_face_distance)


def update_reference_frame_number(reference_frame_number : int = 0) -> None:
	state_manager.set_item('reference_frame_number', reference_frame_number)


def clear_reference_frame_number() -> None:
	state_manager.set_item('reference_frame_number', 0)


def clear_and_update_reference_position_gallery() -> gradio.Gallery:
	clear_faces()
	return update_reference_position_gallery()


def update_reference_position_gallery(frame_number : int = 0) -> gradio.Gallery:
	gallery_vision_frames = []
	source_vision_frames = read_static_images(filter_image_paths(state_manager.get_item('source_paths')))

	if is_image(state_manager.get_item('target_path')):
		target_vision_frame = read_static_image(state_manager.get_item('target_path'))
		gallery_vision_frames = extract_gallery_frames(source_vision_frames, target_vision_frame)
	if is_video(state_manager.get_item('target_path')):
		target_vision_frame = read_video_frame(state_manager.get_item('target_path'), frame_number)
		gallery_vision_frames = extract_gallery_frames(source_vision_frames, target_vision_frame)
	if gallery_vision_frames:
		return gradio.Gallery(value = gallery_vision_frames)
	return gradio.Gallery(value = None)


def extract_gallery_frames(source_vision_frames : List[VisionFrame], target_vision_frame : VisionFrame) -> List[VisionFrame]:
	gallery_vision_frames = []
	source_faces = get_many_faces(source_vision_frames)
	target_faces = get_many_faces([ target_vision_frame ])
	target_faces = sort_and_filter_faces(source_faces, target_faces)

	for index, target_face in enumerate(target_faces):
		start_x, start_y, end_x, end_y = map(int, target_face.bounding_box)
		padding_x = int((end_x - start_x) * 0.25)
		padding_y = int((end_y - start_y) * 0.25)
		start_x = max(0, start_x - padding_x)
		start_y = max(0, start_y - padding_y)
		end_x = max(0, end_x + padding_x)
		end_y = max(0, end_y + padding_y)
		crop_vision_frame = target_vision_frame[start_y:end_y, start_x:end_x]
		crop_vision_frame = fit_cover_frame(crop_vision_frame, (128, 128))
		crop_vision_frame = cv2.cvtColor(crop_vision_frame, cv2.COLOR_BGR2RGB)
		gallery_vision_frames.append((crop_vision_frame, f'Face {index + 1}'))

	return gallery_vision_frames
