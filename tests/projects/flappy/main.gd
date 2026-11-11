extends Node2D
## Floppy Bird: tap / click / Space to flap through the pipes. Tap after game over to restart.

const PipePair := preload("res://pipe_pair.tscn")

var score := 0
var game_over := false
var started := false
var pipes_spawned := 0
var input_events := 0

@onready var bird: CharacterBody2D = $Bird
@onready var score_label: Label = $UI/Score
@onready var message: Label = $UI/Message


func _ready() -> void:
	bird.died.connect(_on_bird_died)
	$PipeTimer.timeout.connect(_spawn_pipes)
	message.text = "Tap to flap"
	_update_state()


func _unhandled_input(event: InputEvent) -> void:
	var tap := false
	if event is InputEventScreenTouch and event.pressed:
		tap = true
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and event.device != InputEvent.DEVICE_ID_EMULATION:
		# Real mouse clicks; clicks emulated from touches are already handled as touches.
		tap = true
	elif event.is_action_pressed("flap"):
		tap = true
	if not tap:
		return
	input_events += 1
	get_viewport().set_input_as_handled()
	if game_over:
		GameState.restarts += 1
		get_tree().reload_current_scene()
		return
	if not started:
		started = true
		message.text = ""
		$PipeTimer.start()
		_spawn_pipes()
	bird.flap()


func _physics_process(_delta: float) -> void:
	if Engine.get_meta("floppy_request_quit", false):
		# Used by the test: a game that quits by itself (closes the game window).
		Engine.set_meta("floppy_request_quit", false)
		get_tree().quit(3)
		return
	if not started:
		# Hover until the first tap.
		bird.velocity.y = 0.0
		bird.position.y = 300.0 + sin(Time.get_ticks_msec() / 200.0) * 8.0
	_update_state()


func _spawn_pipes() -> void:
	if game_over:
		return
	var p := PipePair.instantiate()
	p.gap_y = randf_range(220.0, 500.0)
	p.position.x = 560.0
	p.scored.connect(_on_scored)
	p.hit.connect(bird.die)
	$Pipes.add_child(p)
	pipes_spawned += 1


func _on_scored() -> void:
	score += 1
	score_label.text = str(score)


func _on_bird_died() -> void:
	game_over = true
	$PipeTimer.stop()
	GameState.report_score(score)
	message.text = "Game over! Score %d, best %d\nTap to restart" % [score, GameState.best_score]


func next_gap_y() -> float:
	var best := 360.0
	var best_x := INF
	for p in $Pipes.get_children():
		# The pipe the bird has to pass next (its right edge is still ahead of the bird).
		if p.position.x + 40.0 > bird.position.x - 20.0 and p.position.x < best_x:
			best_x = p.position.x
			best = p.gap_y
	return best


func _update_state() -> void:
	# Shared with the editor-side test (same process); a regular game doesn't need this.
	Engine.set_meta("floppy_state", {
		"started": started,
		"game_over": game_over,
		"score": score,
		"bird_y": bird.position.y,
		"bird_velocity": bird.velocity.y,
		"flaps": bird.flaps,
		"gap_y": next_gap_y(),
		"pipes_spawned": pipes_spawned,
		"input_events": input_events,
		"best_score": GameState.best_score,
		"restarts": GameState.restarts,
		"editor_hint": Engine.is_editor_hint(),
		"viewport_size": get_viewport().get_visible_rect().size,
		"frame": Engine.get_physics_frames(),
	})
