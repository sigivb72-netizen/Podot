extends CharacterBody2D
## The bird: falls with gravity, flaps up, dies when it hits a pipe or the ground.

signal died

const GRAVITY := 1400.0
const FLAP_SPEED := -430.0
const MAX_FALL := 700.0

var alive := true
var flaps := 0


func flap() -> void:
	if not alive:
		return
	velocity.y = FLAP_SPEED
	flaps += 1


func _physics_process(delta: float) -> void:
	if not alive:
		velocity.y = min(velocity.y + GRAVITY * delta, MAX_FALL)
		position.y = min(position.y + velocity.y * delta, 690.0)
		return
	velocity.y = min(velocity.y + GRAVITY * delta, MAX_FALL)
	velocity.x = 0.0
	move_and_slide()
	rotation = clamp(velocity.y / 900.0, -0.5, 1.2)
	if position.y > 660.0 or position.y < -40.0:
		die()


func die() -> void:
	if alive:
		alive = false
		died.emit()
