# Autoloaded class that manages in and out bound messages from the game client to Nakama server.
#
# Anything that has to do with communicating with the server is first sent here, then this class
# delegates work to sub-classes. See [Authenticator], [ExceptionHandler], and [StorageWorker].
#
# As in Nakama, asynchronous methods are named `*_async` and you must use yield to get their return value.
#
# For example:
#
# var return_code: int = yield(Connection.login_async(email, password), "completed")
# if return_code == OK:
# 	print("Authenticated")
#
# /!\ About Storage
#
# The value being stored **must** be a JSON dictionary. Trying to store anything else
# will return an empty value when read from storage later.
#
# Being aware of what comes out of `JSON.print` is important; `Color`, for instance,
# comes out as a single string with numbers, not a `Dictionary` with RGBA keys.
#
# Packet layout
#
# Messages sent in and out of the server are described in /docs/packets.md
extends Node

# Custom operational codes for state messages. Nakama built-in codes are values lower or equal to `0`.
enum OpCodes {
	UPDATE_POSITION = 1,
	UPDATE_INPUT,
	UPDATE_STATE,
	UPDATE_JUMP,
	DO_SPAWN,
	UPDATE_COLOR,
	INITIAL_STATE
}

# Server key. Must be unique and match the server it will try to connect to.
const KEY := "wondrous_hippos"

# Emitted when the `presences` Dictionary has changed by joining or leaving clients
signal presences_changed

# Emitted when the server has sent an updated game state. 10 times per second.
signal state_updated(positions, inputs)

# Emitted when the server has been informed of a change in color by another client
signal color_updated(id, color)

# Emitted when the server has received a new chat message into the world channel
signal chat_message_received(sender_id, message)

# Emitted when the server has received the game state dump for all connected characters
signal initial_state_received(positions, inputs, colors, names)

# Emitted when the server has been informed of a new character having been selected and is ready to spawn in
signal character_spawned(id, color, name)

# String that contains the error message whenever any of the functions that yield return != OK
var error_message := "" setget _no_set, _get_error_message

# Dictionary with user_id for keys and NakamaPresence for values.
var presences := {} setget _no_set

# Nakama client through which sessions are created, sockets connected, and storage accessed.
# For development purposes, it's set to the default localhost, as listed in the /nakama/docker-compose.yml
var _client := Nakama.create_client(KEY, "127.0.0.1", 7350, "http") setget _no_set

# Nakama socket through which the live game world is interacted with.
var _socket: NakamaSocket setget _no_set

# The ID of the match the game world is associated with
var _world_id: String setget _no_set

# The ID of the world chat channel
var _channel_id: String setget _no_set

var _exception_handler := ExceptionHandler.new()
var _authenticator := Authenticator.new(_client, _exception_handler)
var _storage_worker: StorageWorker


# Asynchronous coroutine. Authenticates a new session via email and password, and
# creates a new account when it did not previously exist, then initializes _session.
# Returns OK or a nakama error code. Stores error messages in `Connection.error_message`
func register_async(email: String, password: String) -> int:
	var result: int = yield(_authenticator.register_async(email, password), "completed")
	if result == OK:
		_storage_worker = StorageWorker.new(_authenticator.session, _client, _exception_handler)
	return result


# Asynchronous coroutine. Authenticates a new session via email and password, but will
# not try to create a new account when it did not previously exist, then
# initializes _session. If a session previously existed in `AUTH`, will try to
# recover it without needing the authentication server. 
# Returns OK or a nakama error code. Stores error messages in `Connection.error_message`
func login_async(email: String, password: String) -> int:
	var result: int = yield(_authenticator.login_async(email, password), "completed")
	if result == OK:
		_storage_worker = StorageWorker.new(_authenticator.session, _client, _exception_handler)
	return result


# Asynchronous coroutine. Connects the socket to the live server.
# Returns OK or a nakama error number. Error messages are stored in `Connection.error_message`
func connect_to_server_async() -> int:
	_socket = Nakama.create_socket_from(_client)

	var result: NakamaAsyncResult = yield(
		_socket.connect_async(_authenticator.session), "completed"
	)
	var parsed_result := _exception_handler.parse_exception(result)

	if parsed_result == OK:
		#warning-ignore: return_value_discarded
		_socket.connect("connected", self, "_on_socket_connected")
		#warning-ignore: return_value_discarded
		_socket.connect("closed", self, "_on_socket_closed")
		#warning-ignore: return_value_discarded
		_socket.connect("received_error", self, "_on_socket_error")
		#warning-ignore: return_value_discarded
		_socket.connect("received_match_presence", self, "_on_new_match_presence")
		#warning-ignore: return_value_discarded
		_socket.connect("received_match_state", self, "_on_Received_Match_State")
		#warning-ignore: return_value_discarded
		_socket.connect("received_channel_message", self, "_on_Received_Channel_message")

	return parsed_result


# Asynchronous coroutine. Leaves chat and disconnects from the live server.
# Returns OK or a nakama error number and puts the error message in `Connection.error_message`
func disconnect_from_server_async() -> int:
	var result: NakamaAsyncResult = yield(_socket.leave_chat_async(_channel_id), "completed")
	var parsed_result := _exception_handler.parse_exception(result)
	if parsed_result == OK:
		result = yield(_socket.leave_match_async(_world_id), "completed")
		parsed_result = _exception_handler.parse_exception(result)
		if parsed_result == OK:
			_cleanup()
			_authenticator.cleanup()
			return OK
	
	return parsed_result


# Saves the email in the config file.
func save_email(email: String) -> void:
	EmailConfigWorker.save_email(email)


# Gets the last email from the config file, or a blank string if missing.
func get_last_email() -> String:
	return EmailConfigWorker.get_last_email()


# Removes the last email from the config file
func clear_last_email() -> void:
	EmailConfigWorker.clear_last_email()


func get_user_id() -> String:
	if _authenticator.session:
		return _authenticator.session.user_id
	return ""


# Asynchronous coroutine. Joins the match representing the world and the global chat
# room. Will get the match ID from the server through a remote procedure (see world_rpc.lua).
# Returns OK, a nakama error number, or ERR_UNAVAILABLE if the socket is not connected.
# Stores any error message in `Connection.error_message`
func join_world_async() -> int:
	if not _socket:
		error_message = "Server not connected."
		return ERR_UNAVAILABLE

	# Get match ID from server using a remote procedure
	if not _world_id:
		var world: NakamaAPI.ApiRpc = yield(
			_client.rpc_async(_authenticator.session, "get_world_id", ""), "completed"
		)

		var parsed_result := _exception_handler.parse_exception(world)
		if not parsed_result == OK:
			return parsed_result

		_world_id = world.payload

	# Join world
	var match_join_result: NakamaRTAPI.Match = yield(
		_socket.join_match_async(_world_id), "completed"
	)
	var parsed_result := _exception_handler.parse_exception(match_join_result)

	if parsed_result == OK:
		for presence in match_join_result.presences:
			presences[presence.user_id] = presence

		# Join chat
		var chat_join_result: NakamaRTAPI.Channel = yield(
			_socket.join_chat_async("world", NakamaSocket.ChannelType.Room, false, false),
			"completed"
		)
		parsed_result = _exception_handler.parse_exception(chat_join_result)

		_channel_id = chat_join_result.id

	return parsed_result


# Asynchronous coroutine. Gets the list of characters belonging to the user out of
# server storage.
# Returns an Array of {name: String, color: Color} dictionaries.
# Returns an empty array if there is a failure or if no characters are found.
func get_player_characters_async() -> Array:
	var characters: Array = yield(_storage_worker.get_player_characters_async(), "completed")
	return characters


# Creates a new character on the player's account. Will ask the server if the name
# is available beforehand, then will register the name and create the character into
# storage if so.
# Returns OK when successful, a nakama error code, or ERR_UNAVAILABLE if the name
# is already taken.
func create_player_character_async(color: Color, name: String) -> int:
	var result: int = yield(_storage_worker.create_player_character_async(color, name), "completed")
	return result


# Update the character's color in storage with the repalcement color.
# Returns OK, or a nakama error code.
func update_player_character_async(color: Color, name: String) -> int:
	var result: int = yield(_storage_worker.update_player_character_async(color, name), "completed")
	return result


# Asynchronous coroutine. Delete the character at the specified index in the array from
# player storage. Returns OK, a nakama error code, or ERR_PARAMETER_RANGE_ERROR 
# if the index is too large or is invalid.
func delete_player_character_async(idx: int) -> int:
	var result: int = yield(_storage_worker.delete_player_character_async(idx), "completed")
	return result


# Asynchronous coroutine. Get the last logged in character from the server, if any.
# Returns a {name: String, color: Color} dictionary, or an empty dictionary if no
# character is found, or something goes wrong.
func get_last_player_character_async() -> Dictionary:
	var character: Dictionary = yield(
		_storage_worker.get_last_player_character_async(), "completed"
	)
	return character


# Asynchronous coroutine. Put the last logged in character into player storage on the server.
# Returns OK, or a nakama error code.
func store_last_player_character_async(name: String, color: Color) -> int:
	var result: int = yield(
		_storage_worker.store_last_player_character_async(name, color), "completed"
	)
	return result


# Sends a message to the server stating a change in color for the client.
func send_player_color_update(color: Color) -> void:
	if _socket:
		var payload := {id = get_user_id(), color = color}
		_socket.send_match_state_async(_world_id, OpCodes.UPDATE_COLOR, JSON.print(payload))


# Sends a message to the server stating a change in position for the client.
func send_position_update(position: Vector2) -> void:
	if _socket:
		var payload := {id = get_user_id(), pos = {x = position.x, y = position.y}}
		_socket.send_match_state_async(_world_id, OpCodes.UPDATE_POSITION, JSON.print(payload))


# Sends a message to the server stating a change in horizontal input for the client.
func send_direction_update(input: float) -> void:
	if _socket:
		var payload := {id = get_user_id(), inp = input}
		_socket.send_match_state_async(_world_id, OpCodes.UPDATE_INPUT, JSON.print(payload))


# Sends a message to the server stating a jump from the client.
func send_jump() -> void:
	if _socket:
		var payload := {id = get_user_id()}
		_socket.send_match_state_async(_world_id, OpCodes.UPDATE_JUMP, JSON.print(payload))


# Sends a message to the server stating the client is spawning in after character selection.
func send_spawn(color: Color, name: String) -> void:
	if _socket:
		var payload := {id = get_user_id(), col = JSON.print(color), nm = name}
		_socket.send_match_state_async(_world_id, OpCodes.DO_SPAWN, JSON.print(payload))


# Sends a chat message to the server to be broadcast to others in the channel.
# Returns OK, a nakama error message, or ERR_UNAVAILABLE if the socket is not connected.
func send_text_async(text: String) -> int:
	if not _socket:
		return ERR_UNAVAILABLE

	var data := {"msg": text}

	var message_response: NakamaRTAPI.ChannelMessageAck = yield(
		_socket.write_chat_message_async(_channel_id, data), "completed"
	)

	var parsed_result := _exception_handler.parse_exception(message_response)
	if parsed_result != OK:
		emit_signal(
			"chat_message_received",
			"",
			"SYSTEM",
			"Error code %s: %s" % [parsed_result, error_message]
		)

	return parsed_result


func _no_set(_value) -> void:
	pass


func _get_error_message() -> String:
	return _exception_handler.error_message


# Raised when the socket is closed.
func _on_socket_closed() -> void:
	_clean_up_socket()


# Raised when the socket reports something's gone wrong.
func _on_socket_error(error: String) -> void:
	error_message = error
	_clean_up_socket()


# Helper function to disconnect socket signals.
func _clean_up_socket() -> void:
	#warning-ignore: return_value_discarded
	_socket.disconnect("connected", self, "_on_socket_connected")
	#warning-ignore: return_value_discarded
	_socket.disconnect("closed", self, "_on_socket_closed")
	#warning-ignore: return_value_discarded
	_socket.disconnect("received_error", self, "_on_socket_error")
	#warning-ignore: return_value_discarded
	_socket.disconnect("received_match_presence", self, "_on_new_match_presence")
	#warning-ignore: return_value_discarded
	_socket.disconnect("received_match_state", self, "_on_Received_Match_State")
	#warning-ignore: return_value_discarded
	_socket.disconnect("received_channel_message", self, "_on_Received_Channel_message")

	_socket = null


func _cleanup() -> void:
	_clean_up_socket()
	_world_id = ""
	_channel_id = ""
	presences.clear()


# Raised when the server reports presences have changed.
func _on_new_match_presence(new_presences: NakamaRTAPI.MatchPresenceEvent) -> void:
	for leave in new_presences.leaves:
		#warning-ignore: return_value_discarded
		presences.erase(leave.user_id)

	for join in new_presences.joins:
		if not join.user_id == get_user_id():
			presences[join.user_id] = join

	emit_signal("presences_changed")


# Raised when the server receives a custom message from the server.
func _on_Received_Match_State(match_state: NakamaRTAPI.MatchData) -> void:
	var code := match_state.op_code
	var raw := match_state.data

	match code:
		OpCodes.UPDATE_STATE:
			var decoded: Dictionary = JSON.parse(raw).result

			var positions: Dictionary = decoded.pos
			var inputs: Dictionary = decoded.inp

			emit_signal("state_updated", positions, inputs)

		OpCodes.UPDATE_COLOR:
			var decoded: Dictionary = JSON.parse(raw).result

			var id: String = decoded.id
			var color := Converter.color_string_to_color(decoded.color)

			emit_signal("color_updated", id, color)

		OpCodes.INITIAL_STATE:
			var decoded: Dictionary = JSON.parse(raw).result

			var positions: Dictionary = decoded.pos
			var inputs: Dictionary = decoded.inp
			var colors: Dictionary = decoded.col
			var names: Dictionary = decoded.nms

			for k in colors.keys():
				colors[k] = Converter.color_string_to_color(colors[k])

			emit_signal("initial_state_received", positions, inputs, colors, names)

		OpCodes.DO_SPAWN:
			var decoded: Dictionary = JSON.parse(raw).result

			var id: String = decoded.id
			var color := Converter.color_string_to_color(decoded.col)
			var name: String = decoded.nm

			emit_signal("character_spawned", id, color, name)


# Raised when the server receives a new chat message.
func _on_Received_Channel_message(message: NakamaAPI.ApiChannelMessage) -> void:
	if message.code == 0:
		var sender_id: String = message.sender_id
		var content: Dictionary = JSON.parse(message.content).result

		emit_signal("chat_message_received", sender_id, content.msg)


# Helper class to manage functions that relate to local files that have to do with
# authentication or login parameters, such as remembering email.
class EmailConfigWorker:
	const CONFIG := "user://config.ini"

	# Saves the email to the config file.
	static func save_email(email: String) -> void:
		var file := ConfigFile.new()
		#warning-ignore: return_value_discarded
		file.load(CONFIG)
		file.set_value("connection", "last_email", email)
		#warning-ignore: return_value_discarded
		file.save(CONFIG)

	# Gets the last email from the config file, or a blank string.
	static func get_last_email() -> String:
		var file := ConfigFile.new()
		#warning-ignore: return_value_discarded
		file.load(CONFIG)

		if file.has_section_key("connection", "last_email"):
			return file.get_value("connection", "last_email")
		else:
			return ""

	# Removes the last email from the config file.
	static func clear_last_email() -> void:
		var file := ConfigFile.new()
		#warning-ignore: return_value_discarded
		file.load(CONFIG)
		file.set_value("connection", "last_email", "")
		#warning-ignore: return_value_discarded
		file.save(CONFIG)


# Helper class to convert values from the server into Godot values.
class Converter:
	# Turns a string in the format `"r,g,b,a"` to a Color. Alpha is skipped.
	static func color_string_to_color(color_string: String) -> Color:
		var color_values := color_string.replace('"', '').split(",")
		return Color(float(color_values[0]), float(color_values[1]), float(color_values[2]))
