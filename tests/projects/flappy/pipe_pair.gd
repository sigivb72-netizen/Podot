extends Node2D
## Two pipes with a gap; scrolls left. Hitting a pipe kills the bird; passing the gap scores.

signal scored
signal hit

const SPEED := 160.0
const GAP := 210.0

var gap_y := 360.0


func _ready() -> void:
	$Top.position.y = gap_y - GAP / 2.0
	$Bottom.position.y = gap_y + GAP / 2.0
	$Gap.position.y = gap_y
	$Top.body_entered.connect(_on_pipe_body_entered)
	$Bottom.body_entered.connect(_on_pipe_body_entered)
	$Gap.body_exited.connect(_on_gap_body_exited)


func _physics_process(delta: float) -> void:
	position.x -= SPEED * delta
	if position.x < -100.0:
		queue_free()


func _on_pipe_body_entered(body: Node) -> void:
	if body.has_method("die"):
		hit.emit()


func _on_gap_body_exited(body: Node) -> void:
	if body.has_method("flap") and body.alive:
		scored.emit()
