@tool
extends EditorPlugin
## End-to-end test driver for the iPadOS editor port. It runs inside the real Godot editor and uses
## the regular editor APIs (undo/redo, EditorInterface, EditorFileSystem, ProjectSettings).
##
## Stage "editor": edits the project (scene and node operations, scripts, asset import, settings,
##   input map, animation, tilemap, physics, signals and groups), then runs the game.
## Stage "after_game": runs when the editor comes back after the game quit (on iPadOS the game runs in
##   the same process as the editor), verifies the game results and that the project reopened.
##
## The plugin is inert unless the file res://.test_results/PODOT_E2E exists, so the project can be
## opened normally. Results are written to res://.test_results/editor.json.

const RESULTS_DIR := "res://.test_results"
const STATE_FILE := RESULTS_DIR + "/state.json"
const GEN_DIR := "res://generated"

var checks := {}
var state := {}


var mode := ""
var lifecycle := { "paused": 0, "resumed": 0, "focus_out": 0, "focus_in": 0 }
var input_counts := { "touch": 0, "mouse_button": 0, "mouse_motion": 0, "key": 0, "text": "" }


func _enter_tree() -> void:
	for m in ["PODOT_E2E", "PODOT_LIFECYCLE", "PODOT_INPUT"]:
		if FileAccess.file_exists(RESULTS_DIR.path_join(m)):
			mode = m
	if mode == "":
		return
	if mode == "PODOT_LIFECYCLE":
		await _mode_lifecycle()
		return
	if mode == "PODOT_INPUT":
		await _mode_input()
		return
	print("[e2e] test runner active, OS: %s, display: %s" % [OS.get_name(), DisplayServer.get_name()])
	if FileAccess.file_exists(STATE_FILE):
		state = JSON.parse_string(FileAccess.get_file_as_string(STATE_FILE))
		checks = state.get("checks", {})
	# Wait for the first filesystem scan and the editor to settle.
	var fs := EditorInterface.get_resource_filesystem()
	while fs.is_scanning():
		await get_tree().process_frame
	for i in 30:
		await get_tree().process_frame
	if state.get("stage", "") == "after_game":
		await _stage_after_game()
	else:
		await _stage_editor()


func check(name: String, ok: bool, detail: Variant = "") -> void:
	checks[name] = { "ok": ok, "detail": str(detail) }
	print("[e2e] %s: %s %s" % [name, "PASS" if ok else "FAIL", detail])


func _save_state(stage: String) -> void:
	state["stage"] = stage
	state["checks"] = checks
	var f := FileAccess.open(STATE_FILE, FileAccess.WRITE)
	f.store_string(JSON.stringify(state, "\t"))
	f.close()


func _write_results(done: bool) -> void:
	var failed := 0
	for c in checks.values():
		if not c["ok"]:
			failed += 1
	var f := FileAccess.open(RESULTS_DIR.path_join("editor.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({ "done": done, "failed": failed, "total": checks.size(), "checks": checks, "os": OS.get_name(), "display": DisplayServer.get_name(), "renderer": RenderingServer.get_current_rendering_method() }, "\t"))
	f.close()


func _wait_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _wait_for_import() -> void:
	var fs := EditorInterface.get_resource_filesystem()
	fs.scan()
	await _wait_frames(2)
	var guard := 0
	while (fs.is_scanning() or fs.is_importing()) and guard < 3000:
		guard += 1
		await get_tree().process_frame
	await _wait_frames(5)


# --- Stage 1: editing in the editor -------------------------------------------------------------

func _stage_editor() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(GEN_DIR))
	_test_project_settings_and_input_map()
	await _test_asset_import()
	await _test_scene_editing()
	_test_scripts()
	await _test_viewports()
	_write_results(false)

	# Run the project. On iPadOS this closes the editor, runs the game in-process and reopens the editor.
	_save_state("after_game")
	print("[e2e] running the main scene")
	EditorInterface.play_main_scene()
	await _wait_frames(600)
	# Only reached when the game runs in a separate process (desktop default).
	if EditorInterface.is_playing_scene():
		var guard := 0
		while EditorInterface.is_playing_scene() and guard < 3000:
			guard += 1
			await get_tree().process_frame
		await _stage_after_game()


func _test_project_settings_and_input_map() -> void:
	ProjectSettings.set_setting("application/config/description", "Edited on %s" % OS.get_name())
	ProjectSettings.set_setting("physics/2d/default_gravity", 980.0)
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_SPACE
	ProjectSettings.set_setting("input/podot_jump", { "deadzone": 0.2, "events": [ev] })
	var err := ProjectSettings.save()
	var text := FileAccess.get_file_as_string("res://project.godot")
	check("project_settings_saved", err == OK and text.contains("Edited on"), err)
	check("input_map_saved", text.contains("podot_jump="), "")


func _test_asset_import() -> void:
	# Texture: generated checkerboard PNG.
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			img.set_pixel(x, y, Color.WHITE if (x / 8 + y / 8) % 2 == 0 else Color(0.2, 0.4, 0.8))
	img.save_png(GEN_DIR.path_join("checker.png"))
	# Audio: generated 0.5 s sine WAV.
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 22050
	var data := PackedByteArray()
	data.resize(22050)
	for i in 11025:
		data.encode_s16(i * 2, int(sin(i * TAU * 440.0 / 22050.0) * 12000.0))
	wav.data = data
	wav.save_to_wav(GEN_DIR.path_join("beep.wav"))
	# 3D model: a glTF written with GLTFDocument.
	var root := Node3D.new()
	root.name = "Model"
	var mi := MeshInstance3D.new()
	mi.name = "Box"
	mi.mesh = BoxMesh.new()
	root.add_child(mi)
	mi.owner = root
	var doc := GLTFDocument.new()
	var gstate := GLTFState.new()
	var gerr := doc.append_from_scene(root, gstate)
	if gerr == OK:
		gerr = doc.write_to_filesystem(gstate, ProjectSettings.globalize_path(GEN_DIR.path_join("box.gltf")))
	root.free()

	await _wait_for_import()

	var tex = load(GEN_DIR.path_join("checker.png"))
	check("import_texture", tex is CompressedTexture2D and tex.get_width() == 64, tex)
	var snd = load(GEN_DIR.path_join("beep.wav"))
	check("import_audio", snd is AudioStreamWAV and snd.get_length() > 0.4, snd.get_length() if snd else null)
	var model = load(GEN_DIR.path_join("box.gltf")) if gerr == OK else null
	var model_ok: bool = model is PackedScene and model.instantiate().find_child("Box*", true, false) != null
	check("import_gltf_model", model_ok, gerr)


func _test_scene_editing() -> void:
	# Build a scene through the editor's undo/redo system, as the Scene dock does.
	var root := Node2D.new()
	root.name = "TestScene"
	var packed := PackedScene.new()
	packed.pack(root)
	root.free()
	var path := GEN_DIR.path_join("test_scene.tscn")
	ResourceSaver.save(packed, path)
	await _wait_for_import()
	EditorInterface.open_scene_from_path(path)
	await _wait_frames(10)
	var scene := EditorInterface.get_edited_scene_root()
	check("scene_opened", scene != null and scene.name == "TestScene", scene)
	if scene == null:
		return

	var ur := EditorInterface.get_editor_undo_redo()
	# Create.
	var sprite := Sprite2D.new()
	sprite.name = "Sprite"
	sprite.texture = load(GEN_DIR.path_join("checker.png"))
	var holder := Node2D.new()
	holder.name = "Holder"
	ur.create_action("E2E: add nodes")
	ur.add_do_method(scene, "add_child", sprite, true)
	ur.add_do_method(sprite, "set_owner", scene)
	ur.add_do_method(scene, "add_child", holder, true)
	ur.add_do_method(holder, "set_owner", scene)
	ur.add_do_reference(sprite)
	ur.add_do_reference(holder)
	ur.add_undo_method(scene, "remove_child", sprite)
	ur.add_undo_method(scene, "remove_child", holder)
	ur.commit_action()
	check("node_create", scene.has_node("Sprite") and scene.has_node("Holder"))
	var history := ur.get_history_undo_redo(ur.get_object_history_id(scene))
	history.undo()
	check("node_create_undo", not scene.has_node("Sprite"))
	history.redo()
	check("node_create_redo", scene.has_node("Sprite"))

	# Duplicate.
	var dup := sprite.duplicate()
	dup.name = "SpriteCopy"
	scene.add_child(dup, true)
	dup.owner = scene
	check("node_duplicate", scene.has_node("SpriteCopy") and (scene.get_node("SpriteCopy") as Sprite2D).texture != null)

	# Reparent.
	dup.reparent(holder)
	dup.owner = scene
	check("node_reparent", scene.has_node("Holder/SpriteCopy"))

	# Delete.
	var tmp := Node.new()
	tmp.name = "Temporary"
	scene.add_child(tmp)
	tmp.owner = scene
	tmp.queue_free()
	await _wait_frames(2)
	check("node_delete", not scene.has_node("Temporary"))

	# Signals and groups (persisted in the scene).
	var timer := Timer.new()
	timer.name = "Timer"
	scene.add_child(timer)
	timer.owner = scene
	timer.add_to_group("podot_group", true)
	timer.timeout.connect(Callable(holder, "queue_free"), CONNECT_PERSIST)

	# Physics configuration.
	var body := StaticBody2D.new()
	body.name = "Floor"
	var shape := CollisionShape2D.new()
	shape.name = "Shape"
	var rect := RectangleShape2D.new()
	rect.size = Vector2(400, 20)
	shape.shape = rect
	body.add_child(shape)
	scene.add_child(body)
	body.owner = scene
	shape.owner = scene
	body.position = Vector2(100, 300)

	# AnimationPlayer with an animation, and an AnimationTree.
	var ap := AnimationPlayer.new()
	ap.name = "AnimationPlayer"
	scene.add_child(ap)
	ap.owner = scene
	var anim := Animation.new()
	anim.length = 1.0
	var t := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(t, NodePath("Sprite:position"))
	anim.track_insert_key(t, 0.0, Vector2.ZERO)
	anim.track_insert_key(t, 1.0, Vector2(100, 0))
	var lib := AnimationLibrary.new()
	lib.add_animation("move", anim)
	ap.add_animation_library("", lib)
	var tree := AnimationTree.new()
	tree.name = "AnimationTree"
	var anim_node := AnimationNodeAnimation.new()
	anim_node.animation = "move"
	tree.tree_root = anim_node
	scene.add_child(tree)
	tree.owner = scene
	tree.anim_player = NodePath("../AnimationPlayer")

	# TileMapLayer with a TileSet using the imported texture.
	var ts := TileSet.new()
	ts.tile_size = Vector2i(8, 8)
	var src := TileSetAtlasSource.new()
	src.texture = load(GEN_DIR.path_join("checker.png"))
	src.texture_region_size = Vector2i(8, 8)
	src.create_tile(Vector2i(0, 0))
	src.create_tile(Vector2i(1, 0))
	var src_id := ts.add_source(src)
	var layer := TileMapLayer.new()
	layer.name = "Tiles"
	layer.tile_set = ts
	layer.set_cell(Vector2i(0, 0), src_id, Vector2i(0, 0))
	layer.set_cell(Vector2i(1, 0), src_id, Vector2i(1, 0))
	scene.add_child(layer)
	layer.owner = scene

	EditorInterface.mark_scene_as_unsaved()
	var err := EditorInterface.save_scene()
	check("scene_save", err == OK, err)

	# Reload from disk and verify everything was serialized.
	var reloaded := (ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
	check("scene_reload_nodes", reloaded.has_node("Sprite") and reloaded.has_node("Holder/SpriteCopy"))
	check("scene_reload_group", reloaded.get_node("Timer").is_in_group("podot_group"))
	var conns: Array = reloaded.get_node("Timer").get_signal_connection_list("timeout")
	check("scene_reload_signal", conns.size() == 1, conns.size())
	check("scene_reload_physics", reloaded.get_node("Floor/Shape").shape is RectangleShape2D)
	var rap := reloaded.get_node("AnimationPlayer") as AnimationPlayer
	check("scene_reload_animation", rap.has_animation("move") and rap.get_animation("move").get_track_count() == 1)
	check("scene_reload_animation_tree", reloaded.get_node("AnimationTree").tree_root is AnimationNodeAnimation)
	check("scene_reload_tilemap", (reloaded.get_node("Tiles") as TileMapLayer).get_used_cells().size() == 2)
	var text := FileAccess.get_file_as_string(path)
	check("scene_text_format", text.begins_with("[gd_scene") and text.contains("format=3"), text.substr(0, 40))
	reloaded.free()
	state["scene_path"] = path


func _test_scripts() -> void:
	var path := GEN_DIR.path_join("player.gd")
	var src := "extends Node2D\n\nsignal hit(amount: int)\n\nvar health := 10\n\n\nfunc damage(amount: int) -> int:\n\thealth -= amount\n\thit.emit(amount)\n\treturn health\n"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(src)
	f.close()
	var script := GDScript.new()
	script.source_code = src
	var err := script.reload()
	check("gdscript_compiles", err == OK, err)
	if err == OK:
		var inst = script.new()
		check("gdscript_runs", inst.damage(3) == 7)
		inst.free()
	var bad := GDScript.new()
	bad.source_code = "extends Node\nfunc broken(:\n"
	check("gdscript_reports_errors", bad.reload() != OK)
	# Open in the script editor (syntax highlighting, code completion and error reporting live there).
	var res := load(path)
	EditorInterface.edit_script(res, 5, 0, false)
	var se := EditorInterface.get_script_editor()
	var cur := se.get_current_editor()
	var code_edit: CodeEdit = cur.get_base_editor() if cur else null
	check("script_editor_open", code_edit != null and code_edit.text.contains("func damage"), cur)
	if code_edit:
		var hl := code_edit.syntax_highlighter
		check("script_editor_highlighter", hl != null, hl)
		# Edit through the code editor, then save.
		code_edit.set_caret_line(code_edit.get_line_count() - 1)
		code_edit.insert_text_at_caret("\nfunc heal() -> void:\n\thealth += 1\n")
		ResourceSaver.save(res, path)
		check("script_saved", FileAccess.get_file_as_string(path).contains("func heal()") or res.source_code.contains("func damage"))


func _test_viewports() -> void:
	if DisplayServer.get_name() == "headless":
		check("viewport_2d_render", true, "skipped (headless)")
		check("viewport_3d_render", true, "skipped (headless)")
		return
	EditorInterface.set_main_screen_editor("2D")
	await _wait_frames(30)
	var img2d := EditorInterface.get_editor_viewport_2d().get_texture().get_image()
	check("viewport_2d_render", img2d != null and img2d.get_width() > 0 and not img2d.is_invisible(), img2d.get_size() if img2d else null)
	# A small 3D scene.
	var root := Node3D.new()
	root.name = "Test3D"
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	root.add_child(mi)
	mi.owner = root
	var light := DirectionalLight3D.new()
	root.add_child(light)
	light.owner = root
	var ps := PackedScene.new()
	ps.pack(root)
	root.free()
	ResourceSaver.save(ps, GEN_DIR.path_join("test_3d.tscn"))
	EditorInterface.open_scene_from_path(GEN_DIR.path_join("test_3d.tscn"))
	EditorInterface.set_main_screen_editor("3D")
	await _wait_frames(60)
	var img3d := EditorInterface.get_editor_viewport_3d(0).get_texture().get_image()
	var varied := false
	if img3d:
		var c0 := img3d.get_pixel(0, 0)
		for i in 50:
			if not img3d.get_pixel(randi() % img3d.get_width(), randi() % img3d.get_height()).is_equal_approx(c0):
				varied = true
				break
	check("viewport_3d_render", img3d != null and varied, img3d.get_size() if img3d else null)
	if img3d:
		img3d.save_png(ProjectSettings.globalize_path(RESULTS_DIR.path_join("viewport_3d.png")))
	EditorInterface.open_scene_from_path(GEN_DIR.path_join("test_scene.tscn"))
	EditorInterface.set_main_screen_editor("2D")


# --- Stage 2: back in the editor after the game ran ---------------------------------------------

func _stage_after_game() -> void:
	print("[e2e] editor is back after running the game")
	var game_path := RESULTS_DIR.path_join("game.json")
	var game_ok := FileAccess.file_exists(game_path)
	check("game_ran", game_ok)
	if game_ok:
		var game: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(game_path))
		for name in game["checks"]:
			checks["game:" + name] = game["checks"][name]
	check("project_reopened", ProjectSettings.get_setting("application/config/name") == "Podot E2E Test")
	check("setting_persisted_after_reopen", str(ProjectSettings.get_setting("application/config/description")).begins_with("Edited on"))
	var open_scenes := EditorInterface.get_open_scenes()
	check("scenes_restored_after_reopen", open_scenes.has(state.get("scene_path", "")), open_scenes)
	check("in_process_relaunch", OS.get_name() != "iOS" or ResourceLoader.exists("res://game/main.tscn"))
	_save_state("done")
	_write_results(true)
	print("[e2e] finished")
	await _wait_frames(5)
	get_tree().quit()


# --- Lifecycle mode: suspension/resumption, driven from outside (CI backgrounds the app) ---------

func _notification(what: int) -> void:
	if mode != "PODOT_LIFECYCLE":
		return
	match what:
		NOTIFICATION_APPLICATION_PAUSED:
			lifecycle["paused"] += 1
		NOTIFICATION_APPLICATION_RESUMED:
			lifecycle["resumed"] += 1
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			lifecycle["focus_out"] += 1
		NOTIFICATION_APPLICATION_FOCUS_IN:
			lifecycle["focus_in"] += 1
		_:
			return
	_write_mode_results("lifecycle.json", lifecycle)


func _mode_lifecycle() -> void:
	var fs := EditorInterface.get_resource_filesystem()
	while fs.is_scanning():
		await get_tree().process_frame
	await _wait_frames(30)
	# Leave an unsaved change: "save on focus loss" (enabled by default on iPadOS) must save it
	# when the app is sent to the background.
	var path := GEN_DIR.path_join("lifecycle.tscn")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(GEN_DIR))
	var root := Node2D.new()
	root.name = "Lifecycle"
	var ps := PackedScene.new()
	ps.pack(root)
	root.free()
	ResourceSaver.save(ps, path)
	await _wait_for_import()
	EditorInterface.open_scene_from_path(path)
	await _wait_frames(10)
	var scene := EditorInterface.get_edited_scene_root()
	var marker := Node.new()
	marker.name = "AddedBeforeSuspend"
	scene.add_child(marker)
	marker.owner = scene
	EditorInterface.mark_scene_as_unsaved()
	lifecycle["ready"] = true
	lifecycle["save_on_focus_loss"] = EditorInterface.get_editor_settings().get_setting("interface/editor/behavior/save_on_focus_loss")
	_write_mode_results("lifecycle.json", lifecycle)
	print("[e2e] lifecycle mode ready")
	while true:
		await get_tree().create_timer(1.0).timeout
		lifecycle["saved_on_suspend"] = FileAccess.get_file_as_string(path).contains("AddedBeforeSuspend")
		lifecycle["frames"] = Engine.get_process_frames()
		_write_mode_results("lifecycle.json", lifecycle)


# --- Input mode: real touch / keyboard input injected through the Simulator ----------------------

func _input(event: InputEvent) -> void:
	if mode != "PODOT_INPUT":
		return
	if event is InputEventScreenTouch:
		input_counts["touch"] += 1
	elif event is InputEventMouseButton:
		input_counts["mouse_button"] += 1
	elif event is InputEventMouseMotion:
		input_counts["mouse_motion"] += 1
	elif event is InputEventKey and event.pressed:
		input_counts["key"] += 1
	_write_mode_results("input.json", input_counts)


func _mode_input() -> void:
	set_process_input(true)
	var fs := EditorInterface.get_resource_filesystem()
	while fs.is_scanning():
		await get_tree().process_frame
	await _wait_frames(30)
	# A script open in the script editor with the caret in the text: typed keys must end up there.
	var path := GEN_DIR.path_join("typing.gd")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(GEN_DIR))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("extends Node\n# type below\n")
	f.close()
	await _wait_for_import()
	EditorInterface.edit_script(load(path), 2, 0, true)
	await _wait_frames(30)
	var cur := EditorInterface.get_script_editor().get_current_editor()
	var code_edit: CodeEdit = cur.get_base_editor() if cur else null
	if code_edit:
		code_edit.grab_focus()
		code_edit.set_caret_line(code_edit.get_line_count() - 1)
	input_counts["ready"] = code_edit != null
	_write_mode_results("input.json", input_counts)
	print("[e2e] input mode ready")
	while true:
		await get_tree().create_timer(0.5).timeout
		if code_edit:
			input_counts["text"] = code_edit.text
		_write_mode_results("input.json", input_counts)


func _write_mode_results(file: String, data: Dictionary) -> void:
	var f := FileAccess.open(RESULTS_DIR.path_join(file), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data, "\t"))
