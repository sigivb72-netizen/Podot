extends Node
## Autoload: survives scene reloads (restarts), keeps the best score.

var best_score := 0
var games_played := 0
var restarts := 0


func report_score(score: int) -> void:
	games_played += 1
	best_score = max(best_score, score)
