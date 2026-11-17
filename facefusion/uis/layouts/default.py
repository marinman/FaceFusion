import gradio

from facefusion import state_manager
from facefusion.uis.components import about, age_modifier_options, background_remover_options, deep_swapper_options, download, execution, execution_thread_count, expression_restorer_options, face_debugger_options, face_detector, face_editor_options, face_enhancer_options, face_landmarker, face_mapper, face_masker, face_selector, face_swapper_options, face_tracker, frame_colorizer_options, frame_enhancer_options, instant_runner, job_manager, job_runner, lip_syncer_options, memory, output, output_options, preview, preview_options, processors, source, target, temp_frame, terminal, trim_frame, ui_workflow, voice_extractor, workflow


def pre_check() -> bool:
	return True


def render() -> gradio.Blocks:
	with gradio.Blocks() as layout:
		with gradio.Row():
			with gradio.Column(scale = 4):
				with gradio.Blocks():
					about.render()
				with gradio.Blocks():
					processors.render()
				with gradio.Blocks():
					face_swapper_options.render()
				with gradio.Blocks():
					face_enhancer_options.render()
				with gradio.Accordion('Other effect settings', open = False):
					age_modifier_options.render()
					background_remover_options.render()
					deep_swapper_options.render()
					expression_restorer_options.render()
					face_debugger_options.render()
					face_editor_options.render()
					frame_colorizer_options.render()
					frame_enhancer_options.render()
					lip_syncer_options.render()
					voice_extractor.render()
				with gradio.Accordion('Performance & system', open = False):
					workflow.render()
					execution.render()
					execution_thread_count.render()
					download.render()
					memory.render()
					temp_frame.render()
				with gradio.Accordion('Output file settings', open = False):
					output_options.render()
			with gradio.Column(scale = 4):
				with gradio.Blocks():
					source.render()
				with gradio.Blocks():
					target.render()
				with gradio.Blocks():
					output.render()
				with gradio.Blocks():
					terminal.render()
				with gradio.Blocks():
					ui_workflow.render()
					instant_runner.render()
					job_runner.render()
					job_manager.render()
			with gradio.Column(scale = 7):
				with gradio.Blocks():
					preview.render()
					preview_options.render()
				with gradio.Blocks():
					face_selector.render()
				with gradio.Accordion('Swap multiple faces (one photo per face)', open = False):
					face_mapper.render()
				with gradio.Blocks():
					trim_frame.render()
				with gradio.Accordion('Advanced face detection', open = False):
					face_tracker.render()
					face_masker.render()
					face_detector.render()
					face_landmarker.render()
	return layout


def listen() -> None:
	processors.listen()
	age_modifier_options.listen()
	background_remover_options.listen()
	deep_swapper_options.listen()
	expression_restorer_options.listen()
	face_debugger_options.listen()
	face_editor_options.listen()
	face_enhancer_options.listen()
	face_swapper_options.listen()
	frame_colorizer_options.listen()
	frame_enhancer_options.listen()
	lip_syncer_options.listen()
	execution.listen()
	execution_thread_count.listen()
	download.listen()
	memory.listen()
	temp_frame.listen()
	output_options.listen()
	source.listen()
	target.listen()
	output.listen()
	instant_runner.listen()
	job_runner.listen()
	job_manager.listen()
	terminal.listen()
	preview.listen()
	preview_options.listen()
	trim_frame.listen()
	face_selector.listen()
	face_mapper.listen()
	face_tracker.listen()
	face_masker.listen()
	face_detector.listen()
	face_landmarker.listen()
	voice_extractor.listen()
	workflow.listen()


def run(ui : gradio.Blocks) -> None:
	ui.launch(favicon_path = 'facefusion.ico', inbrowser = state_manager.get_item('open_browser'))
