#!/usr/bin/env python
"""Helper for the native FaceFusion app.

    ff_helper.py faces   --target <path> [--frame N] [--out <dir>]
    ff_helper.py preview --target <path> [--frame N] --out <file.png>
    ff_helper.py info    --target <path>

Prints one JSON object on stdout. Everything the app needs that is cheaper to
answer in Python than to re-implement in Swift.
"""

import argparse
import json
import os
import sys

import cv2

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from facefusion import state_manager  # noqa: E402
from facefusion.args import apply_args  # noqa: E402
from facefusion.program import create_program  # noqa: E402


def init_state(target_path):
	program = create_program()
	args = vars(program.parse_args([ 'headless-run', '-t', target_path, '-o', '/tmp/ff-helper-out.mp4', '--processors', 'face_swapper' ]))
	apply_args(args, state_manager.init_item)


def read_frame(target_path, frame_number):
	from facefusion.filesystem import is_image, is_video
	from facefusion.vision import read_static_image, read_static_video_frame

	if is_image(target_path):
		return read_static_image(target_path)
	if is_video(target_path):
		return read_static_video_frame(target_path, frame_number)
	return None


def cmd_info(args):
	from facefusion.filesystem import is_video
	from facefusion.vision import count_video_frame_total, detect_video_fps

	payload = { 'isVideo': bool(is_video(args.target)), 'frameCount': 0, 'fps': 0.0 }

	if payload['isVideo']:
		payload['frameCount'] = int(count_video_frame_total(args.target) or 0)
		payload['fps'] = float(detect_video_fps(args.target) or 0)
	frame = read_frame(args.target, 0)

	if frame is not None:
		payload['width'], payload['height'] = int(frame.shape[1]), int(frame.shape[0])
	return payload


def cmd_faces(args):
	from facefusion import face_map
	from facefusion.vision import fit_cover_frame

	frame = read_frame(args.target, args.frame)

	if frame is None:
		return { 'faces': [] }
	faces = face_map.index_reference_faces(frame)
	out_dir = args.out or '/tmp/ff-faces'
	os.makedirs(out_dir, exist_ok=True)
	payload = []

	for index, face in enumerate(faces):
		start_x, start_y, end_x, end_y = map(int, face.bounding_box)
		pad_x, pad_y = int((end_x - start_x) * 0.3), int((end_y - start_y) * 0.3)
		crop = frame[max(0, start_y - pad_y):end_y + pad_y, max(0, start_x - pad_x):end_x + pad_x]

		if not crop.size:
			continue
		thumb_path = os.path.join(out_dir, 'face_%d.png' % index)
		cv2.imwrite(thumb_path, fit_cover_frame(crop, (256, 256)))
		payload.append({
			'slot': index + 1,
			'thumb': thumb_path,
			'box': [ start_x, start_y, end_x, end_y ]
		})
	return { 'faces': payload, 'frameWidth': int(frame.shape[1]), 'frameHeight': int(frame.shape[0]) }


def cmd_preview(args):
	frame = read_frame(args.target, args.frame)

	if frame is None:
		return { 'ok': False }
	cv2.imwrite(args.out, frame)
	return { 'ok': True, 'path': args.out, 'width': int(frame.shape[1]), 'height': int(frame.shape[0]) }


def main():
	parser = argparse.ArgumentParser(description = __doc__)
	parser.add_argument('command', choices = [ 'faces', 'preview', 'info' ])
	parser.add_argument('--target', required = True)
	parser.add_argument('--frame', type = int, default = 0)
	parser.add_argument('--out')
	args = parser.parse_args()

	init_state(args.target)
	handler = { 'faces': cmd_faces, 'preview': cmd_preview, 'info': cmd_info }[args.command]
	sys.stdout.write(json.dumps(handler(args)))


if __name__ == '__main__':
	main()
