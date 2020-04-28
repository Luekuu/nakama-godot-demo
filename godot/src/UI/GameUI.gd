# Main game ui control that acts as a go-between with the various in-game ui
# controls that the world can react to.
extends Control

signal color_changed(color)
signal text_sent(text)
signal chat_edit_started
signal chat_edit_ended
signal logged_out

onready var color_editor := $CharacterColorEditor
onready var chat_box := $ChatBox
onready var notifications_ui := $NotificationsUI


func setup(_color: Color) -> void:
	color_editor.color = _color


func add_chat_reply(text: String, sender: String, text_color: Color) -> void:
	chat_box.add_reply(text, sender, text_color)


func add_notification(username: String, text_color: Color, disconnected := false) -> void:
	notifications_ui.add_notification(username, text_color, disconnected)


func _on_ChangeColorButton_pressed() -> void:
	color_editor.show()


func _on_ChatBox_text_sent(text: String) -> void:
	emit_signal("text_sent", text)


func _on_CharacterColorEditor_color_changed(_color: Color) -> void:
	emit_signal("color_changed", _color)
	setup(_color)


func _on_LogoutButton_pressed() -> void:
	emit_signal("logged_out")


func _on_ChatBox_edit_started() -> void:
	emit_signal("chat_edit_started")


func _on_ChatBox_edit_ended() -> void:
	emit_signal("chat_edit_ended")
