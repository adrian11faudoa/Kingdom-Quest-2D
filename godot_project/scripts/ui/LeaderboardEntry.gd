## LeaderboardEntry.gd
## Sets data on a leaderboard row; highlights the local player's row.
extends HBoxContainer

@onready var rank_label:     Label = $RankLabel
@onready var username_label: Label = $UsernameLabel
@onready var score_label:    Label = $ScoreLabel

func set_data(rank: int, username: String, score: String, is_self: bool) -> void:
	rank_label.text     = "#%d" % rank
	username_label.text = username
	score_label.text    = score
	if is_self:
		add_theme_color_override("font_color", Color(0.9, 0.85, 0.2))
		rank_label.add_theme_color_override("font_color",     Color(0.9, 0.85, 0.2))
		username_label.add_theme_color_override("font_color", Color(0.9, 0.85, 0.2))
		score_label.add_theme_color_override("font_color",    Color(0.9, 0.85, 0.2))
