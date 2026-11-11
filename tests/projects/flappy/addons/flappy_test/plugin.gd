@tool
extends EditorPlugin
## Plays Floppy Bird in the game window next to the editor, the way a person would: taps the
## window to flap (through the editor's regular input path), edits the scene in the editor while
## the game runs, crashes into a pipe, restarts, stops the game from the editor, and lets the game
## quit by itself. Results: res://.test_results/flappy.json. Only runs when
## res://.test_results/PODOT_FLAPPY exists.

const RESULTS := "res://.test_results"

var checks := {}
var log_lines: Array[String] = []


func _enter_tree() -> void:
	if FileAccess.file_exists(RESULTS.path_join("PODOT_FLAPPY")):
		_run.call_deferred()


func check(name: String, ok: bool, detail: Variant = "") -> void:
	checks[name] = { "ok": ok, "detail": str(detail) }
	print("[flappy] %s: %s %s" % [name, "PASS" if ok else "FAIL", detail])


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _state() -> Dictionary:
	return Engine.get_meta("floppy_state", {})


func _find_by_class(node: Node, cls: String) -> Node:
	if node.get_class() == cls:
		return node
	for c in node.get_children(true):
		var found := _find_by_class(c, cls)
		if found:
			return found
	return null


func _view_center(view: Control) -> Vector2:
	# Event positions are relative to the editor's main window; the game window is embedded in it.
	var win := view.get_window()
	var origin := Vector2(win.position) if win.is_embedded() else Vector2()
	return origin + view.get_global_rect().get_center()


func _tap(view: Control) -> void:
	var t := InputEventScreenTouch.new()
	t.index = 0
	t.position = _view_center(view)
	t.pressed = true
	Input.parse_input_event(t)
	var r := t.duplicate()
	r.pressed = false
	Input.parse_input_event(r)


func _write_results(done: bool) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(RESULTS))
	var f := FileAccess.open(RESULTS.path_join("flappy.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({ "done": done, "checks": checks, "renderer": RenderingServer.get_current_rendering_method(), "display": DisplayServer.get_name(), "os": OS.get_name() }, "\t"))
	f.close()


func _run() -> void:
	await _wait(3.0)
	EditorInterface.open_scene_from_path("res://main.tscn")
	await _wait(1.0)
	var edited := EditorInterface.get_edited_scene_root()
	check("scene_opened", edited != null and edited.name == "Main", edited)

	# --- Play: the game opens in a window next to the editor ---
	EditorInterface.play_main_scene()
	await _wait(1.5)
	var win := _find_by_class(EditorInterface.get_base_control(), "InProcessGameWindow") as Window
	check("game_window_inside_editor", win != null and win.is_embedded(), "embedded" if win and win.is_embedded() else "separate OS window")
	var view := _find_by_class(EditorInterface.get_base_control(), "InProcessGameView") as Control
	check("game_window_shown", win != null and win.visible, win.get_size() if win else null)
	check("editor_stays_open", EditorInterface.is_playing_scene() and EditorInterface.get_edited_scene_root() == edited)
	var s := _state()
	check("game_running", not s.is_empty() and s.frame > 0, s)
	check("game_not_editor_hint", not s.is_empty() and s.editor_hint == false)
	check("game_viewport_is_window_size", not s.is_empty() and s.viewport_size.x > 0, s.get("viewport_size"))
	if win == null or view == null or s.is_empty():
		_write_results(true)
		get_tree().quit()
		return

	# --- First tap starts the game (touch through the editor's input path) ---
	var view_events := [0]
	view.gui_input.connect(func(_e): view_events[0] += 1)
	print("[flappy] window pos %s size %s, view rect %s, screen pos %s, tap at %s" % [win.position, win.size, view.get_global_rect(), view.get_screen_position(), _view_center(view)])
	_tap(view)
	await _wait(0.4)
	s = _state()
	check("tap_starts_game", s.started and s.flaps >= 1, "view got %d events; %s" % [view_events[0], s])

	# --- Fly: tap when the bird drops below the next gap; edit the scene in the editor meanwhile ---
	var edited_in_editor := false
	var editor_frames := Engine.get_process_frames()
	var t0 := Time.get_ticks_msec()
	var next_tap := 0
	while Time.get_ticks_msec() - t0 < 45000:
		await get_tree().process_frame
		s = _state()
		if s.game_over or s.score >= 4:
			break
		var now := Time.get_ticks_msec()
		if s.bird_y > s.gap_y + 18.0 and s.bird_velocity > -150.0 and now >= next_tap:
			_tap(view)
			next_tap = now + 170
		if not edited_in_editor and now - t0 > 2000:
			edited_in_editor = true
			var sky := edited.get_node("Sky") as ColorRect
			var ur := get_undo_redo()
			var before := sky.color
			ur.create_action("Test: change sky color while the game runs")
			ur.add_do_property(sky, "color", Color(1, 0, 0))
			ur.add_undo_property(sky, "color", before)
			ur.commit_action()
			var changed := sky.color == Color(1, 0, 0)
			ur.get_history_undo_redo(ur.get_object_history_id(sky)).undo()
			check("editor_usable_while_game_runs", changed and sky.color == before, "edit + undo on the edited scene")
	check("editor_kept_running", Engine.get_process_frames() - editor_frames > 30, Engine.get_process_frames() - editor_frames)
	check("bird_flies_through_pipes", s.score >= 3, "score %d, flaps %d, pipes %d" % [s.score, s.flaps, s.pipes_spawned])
	check("pipes_spawned_by_timer", s.pipes_spawned >= 3, s.pipes_spawned)

	if DisplayServer.get_name() != "headless":
		var img := get_tree().root.get_texture().get_image()
		if img:
			img.save_png(ProjectSettings.globalize_path(RESULTS.path_join("editor_with_game.png")))
			var c := img.get_pixelv(Vector2i(_view_center(view)) + Vector2i(0, -int(view.size.y * 0.3)))
			check("game_rendered_in_window", c.b > 0.6 and c.r < 0.8, c)

	# --- Stop flapping: the bird crashes; game over ---
	t0 = Time.get_ticks_msec()
	while not s.game_over and Time.get_ticks_msec() - t0 < 8000:
		await get_tree().process_frame
		s = _state()
	check("game_over_on_crash", s.game_over, s.score)
	var score_before := int(s.score)

	# --- Tap to restart (reload_current_scene in the game's tree; autoload keeps the best score) ---
	await _wait(0.5)
	_tap(view)
	await _wait(0.6)
	s = _state()
	check("restart_reloads_scene", s.restarts >= 1 and not s.game_over and s.score == 0 and not s.started, s)
	check("autoload_keeps_best_score", s.best_score >= score_before, s.best_score)
	check("edited_scene_untouched", EditorInterface.get_edited_scene_root() == edited and edited.get_node("Bird").position == Vector2(140, 300))

	# --- Keyboard: Space (the "flap" action) once the game window has focus ---
	var key := InputEventKey.new()
	key.keycode = KEY_SPACE
	key.physical_keycode = KEY_SPACE
	key.unicode = 32
	key.pressed = true
	Input.parse_input_event(key)
	var key_up := key.duplicate()
	key_up.pressed = false
	Input.parse_input_event(key_up)
	await _wait(0.3)
	s = _state()
	check("keyboard_flap", s.started and s.flaps >= 1, s)

	# --- Stop from the editor ---
	EditorInterface.stop_playing_scene()
	await _wait(0.5)
	check("stop_closes_game_window", not win.visible and not EditorInterface.is_playing_scene())
	check("editor_alive_after_stop", EditorInterface.get_edited_scene_root() == edited)

	# --- Play again; the game quits by itself (get_tree().quit()) ---
	EditorInterface.play_main_scene()
	await _wait(1.0)
	check("play_again", win.visible and EditorInterface.is_playing_scene())
	Engine.set_meta("floppy_request_quit", true)
	await _wait(1.0)
	check("game_quit_closes_window", not win.visible and not EditorInterface.is_playing_scene())

	_write_results(true)
	print("[flappy] done")
	get_tree().quit()
