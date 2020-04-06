extends Node2D

export var PlayerScene: PackedScene
export var CharacterScene: PackedScene

var player: Node
var characters := {}

onready var world := $World
onready var game_ui := $CanvasLayer/GameUI


func _ready() -> void:
	#warning-ignore: return_value_discarded
	game_ui.connect("color_changed", self, "_on_Color_changed")
	#warning-ignore: return_value_discarded
	game_ui.connect("text_sent", self, "_on_Text_Sent")


func join_world(
	username: String,
	player_color: Color,
	state_positions: Dictionary,
	state_inputs: Dictionary,
	state_colors: Dictionary
) -> void:
	assert(state_positions.has(Connection.session.user_id), "Server did not return valid state")

	var player_position: Dictionary = state_positions[Connection.session.user_id]
	_setup_player(username, player_color, Vector2(player_position.x, player_position.y))

	var presences := Connection.presences
	for p in presences.keys():
		var character_position := Vector2(state_positions[p].x, state_positions[p].y)
		var color: Color = state_colors[p]
		_setup_character(
			p, presences[p].username, character_position, state_inputs[p].dir, color, true
		)

	#warning-ignore: return_value_discarded
	Connection.connect("presences_changed", self, "_on_Presences_changed")
	#warning-ignore: return_value_discarded
	Connection.connect("state_updated", self, "_on_State_updated")
	#warning-ignore: return_value_discarded
	Connection.connect("color_updated", self, "_on_Color_updated")
	#warning-ignore: return_value_discarded
	Connection.connect("chat_message_received", self, "_on_Chat_Message_received")
	#warning-ignore: return_value_discarded
	Connection.connect("character_spawned", self, "_on_Character_spawned")


func do_hide() -> void:
	hide()
	world.do_hide()
	game_ui.hide()


func do_show() -> void:
	show()
	world.do_show()
	game_ui.show()


func _setup_player(username: String, player_color: Color, player_position: Vector2) -> void:
	player = PlayerScene.instance()
	player.color = player_color
	game_ui.setup(player_color)

	world.add_child(player)
	player.username = username

	player.global_position = player_position
	player.spawn()
	Connection.send_spawn(player_color)


func _setup_character(
	id: String,
	username: String,
	character_position: Vector2,
	character_input: float,
	color: Color,
	spawn: bool
) -> void:
	var character := CharacterScene.instance()
	character.position = character_position
	character.direction.x = character_input
	character.color = color

	#warning-ignore: return_value_discarded
	world.add_child(character)
	character.username = username
	characters[id] = character
	if spawn:
		character.spawn()
	else:
		character.do_hide()


func _on_Presences_changed() -> void:
	var presences := Connection.presences
	for p in presences.keys():
		if not characters.has(p):
			_setup_character(p, presences[p].username, Vector2.ZERO, 0, Color.white, false)
	var despawns := []
	for c in characters.keys():
		if not presences.has(c):
			despawns.append(c)
	for d in despawns:
		characters[d].despawn()
		var username: String = characters[d].username
		var color: Color = characters[d].color
		game_ui.add_notification(username, color, true)
		#warning-ignore: return_value_discarded
		characters.erase(d)


func _on_State_updated(positions: Dictionary, inputs: Dictionary) -> void:
	var update := false
	for c in characters.keys():
		update = false
		if positions.has(c):
			var next_position: Dictionary = positions[c]
			characters[c].next_position = Vector2(next_position.x, next_position.y)
			update = true
		if inputs.has(c):
			characters[c].next_input = inputs[c].dir
			characters[c].next_jump = inputs[c].jmp == 1
			update = true
		if update:
			characters[c].update_state()


func _on_Color_changed(color: Color) -> void:
	player.color = color
	game_ui.setup(color)
	Connection.send_player_color_update(color)
	Connection.update_player_character(color, player.username)


func _on_Color_updated(id: String, color: Color) -> void:
	if characters.has(id):
		characters[id].color = color


func _on_Chat_Message_received(sender_id: String, sender_name: String, message: String) -> void:
	var color := Color.gray
	if characters.has(sender_id):
		color = characters[sender_id].color
	elif sender_id == Connection.session.user_id:
		color = player.color
	game_ui.add_text(message, sender_name, color)


func _on_Text_Sent(text: String) -> void:
	Connection.send_text(text)


func _on_Character_spawned(id: String, color: Color) -> void:
	if characters.has(id):
		characters[id].color = color
		characters[id].spawn()
		characters[id].do_show()
		game_ui.add_notification(characters[id].username, color)