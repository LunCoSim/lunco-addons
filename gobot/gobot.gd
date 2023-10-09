@icon("res://entities/character_entity.svg")
@tool
class_name Player
extends LCCharacterBody

enum ANIMATIONS {JUMP_UP, JUMP_DOWN, STRAFE, WALK}

const DIRECTION_INTERPOLATE_SPEED = 1
const MOTION_INTERPOLATE_SPEED = 10
const ROTATION_INTERPOLATE_SPEED = 10

const MIN_AIRBORNE_TIME = 0.1
const JUMP_SPEED = 5

var airborne_time = 100

var orientation = Transform3D()
var root_motion = Transform3D()
var motion = Vector2()

@onready var gravity = ProjectSettings.get_setting("physics/3d/default_gravity") * ProjectSettings.get_setting("physics/3d/default_gravity_vector")

@onready var animation_tree = $AnimationTree
@onready var player_model = $PlayerModel
@onready var shoot_from = player_model.get_node("Robot_Skeleton/Skeleton3D/GunBone/ShootFrom")
@onready var crosshair = $Crosshair
@onready var fire_cooldown = $FireCooldown

@onready var sound_effects = $SoundEffects
@onready var sound_effect_jump = sound_effects.get_node("Jump")
@onready var sound_effect_land = sound_effects.get_node("Land")
@onready var sound_effect_shoot = sound_effects.get_node("Shoot")

#-------------------------------------

@export var current_animation := ANIMATIONS.WALK

#-------------------------------------

var aim_rotation
var input_motion: = Vector2.ZERO
var camera_rotation_bases: Basis = Basis.IDENTITY
var camera_base_quaternion: Quaternion = Quaternion.IDENTITY

var jumping: bool = false
var shooting: bool = false
var aiming: bool = false
var shoot_target: = Vector3.ZERO

#-------------------------------------
		

func _ready():
	
	# Pre-initialize orientation transform.
	orientation = player_model.global_transform
	orientation.origin = Vector3()
	if not multiplayer.is_server():
		set_process(false)



func _physics_process(delta: float):	
	if is_multiplayer_authority():
		apply_input(delta)
	else:
		animate(current_animation, delta)

# ------------
func animate(anim: int, delta:=0.0):
	current_animation = anim

	if anim == ANIMATIONS.JUMP_UP:
		animation_tree["parameters/state/transition_request"] = "jump_up"

	elif anim == ANIMATIONS.JUMP_DOWN:
		animation_tree["parameters/state/transition_request"] = "jump_down"

	elif anim == ANIMATIONS.STRAFE:
		animation_tree["parameters/state/transition_request"] = "strafe"
		# Change aim according to camera rotation.
		animation_tree["parameters/aim/add_amount"] = aim_rotation
		# The animation's forward/backward axis is reversed.
		animation_tree["parameters/strafe/blend_position"] = Vector2(motion.x, -motion.y)

	elif anim == ANIMATIONS.WALK:
		# Aim to zero (no aiming while walking).
		animation_tree["parameters/aim/add_amount"] = 0
		# Change state to walk.
		animation_tree["parameters/state/transition_request"] = "walk"
		# Blend position for walk speed based checked motion.
		animation_tree["parameters/walk/blend_position"] = Vector2(motion.length(), 0)


func apply_input(delta: float):
	motion = motion.lerp(input_motion, MOTION_INTERPOLATE_SPEED * delta)

	var camera_basis : Basis = camera_rotation_bases
	
	var camera_z := camera_basis.z
	var camera_x := camera_basis.x

	camera_z.y = 0
	camera_z = camera_z.normalized()
	camera_x.y = 0
	camera_x = camera_x.normalized()

	# Jump/in-air logic.
	airborne_time += delta
	if is_on_floor():
		if airborne_time > 0.5:
			land.rpc()
		airborne_time = 0

	var on_air = airborne_time > MIN_AIRBORNE_TIME

	if not on_air and jumping:
		velocity.y = JUMP_SPEED
		on_air = true
		# Increase airborne time so next frame on_air is still true
		airborne_time = MIN_AIRBORNE_TIME
		jump.rpc()

	jumping = false

	if on_air:
		if (velocity.y > 0):
			animate(ANIMATIONS.JUMP_UP, delta)
		else:
			animate(ANIMATIONS.JUMP_DOWN, delta)
	elif aiming:
		# Convert orientation to quaternions for interpolating rotation.
		var q_from = orientation.basis.get_rotation_quaternion()
		var q_to = camera_base_quaternion
		# Interpolate current rotation with desired one.
		orientation.basis = Basis(q_from.slerp(q_to, delta * ROTATION_INTERPOLATE_SPEED))

		# Change state to strafe.
		animate(ANIMATIONS.STRAFE, delta)

		root_motion = Transform3D(animation_tree.get_root_motion_rotation(), animation_tree.get_root_motion_position())

		if shooting and fire_cooldown.time_left == 0:
			var shoot_origin = shoot_from.global_transform.origin
			var shoot_dir = (shoot_target - shoot_origin).normalized()

			var bullet = preload("res://content/gobot/bullet/bullet.tscn").instantiate()
			get_parent().add_child(bullet, true)
			bullet.global_transform.origin = shoot_origin
			# If we don't rotate the bullets there is no useful way to control the particles ..
			bullet.look_at(shoot_origin + shoot_dir, Vector3.UP)
			bullet.add_collision_exception_with(self)
			shoot.rpc()

	else: # Not in air or aiming, idle.
		# Convert orientation to quaternions for interpolating rotation.
		var target = camera_x * motion.x + camera_z * motion.y
		if target.length() > 0.001:
			var q_from = orientation.basis.get_rotation_quaternion()
			var q_to = Transform3D().looking_at(target, Vector3.UP).basis.get_rotation_quaternion()
			# Interpolate current rotation with desired one.
			orientation.basis = Basis(q_from.slerp(q_to, delta * ROTATION_INTERPOLATE_SPEED))

		animate(ANIMATIONS.WALK, delta)

		root_motion = Transform3D(animation_tree.get_root_motion_rotation(), animation_tree.get_root_motion_position())

	# Apply root motion to orientation.
	orientation *= root_motion #????? What's happening here?
	do_move(delta)
	orient_player_model()

func orient_player_model():
	orientation.origin = Vector3() # Clear accumulated root motion displacement (was applied to speed).
	orientation = orientation.orthonormalized() # Orthonormalize orientation.

	player_model.global_transform.basis = orientation.basis

func do_move(delta):
	var h_velocity = orientation.origin / delta
	velocity.x = h_velocity.x
	velocity.z = h_velocity.z
	velocity += gravity * delta
	set_velocity(velocity)
	set_up_direction(Vector3.UP)
	move_and_slide()

@rpc("call_local")
func jump():
	animate(ANIMATIONS.JUMP_UP)
	sound_effect_jump.play()


@rpc("call_local")
func land():
	animate(ANIMATIONS.JUMP_DOWN)
	sound_effect_land.play()


@rpc("call_local")
func shoot():
	var shoot_particle = $PlayerModel/Robot_Skeleton/Skeleton3D/GunBone/ShootFrom/ShootParticle
	shoot_particle.restart()
	shoot_particle.emitting = true
	var muzzle_particle = $PlayerModel/Robot_Skeleton/Skeleton3D/GunBone/ShootFrom/MuzzleFlash
	muzzle_particle.restart()
	muzzle_particle.emitting = true
	fire_cooldown.start()
	sound_effect_shoot.play()
	add_camera_shake_trauma(0.35)


@rpc("call_local")
func hit():
	add_camera_shake_trauma(.75)


@rpc("call_local")
func add_camera_shake_trauma(amount):
	pass
#	player_input.camera_camera.add_trauma(amount)
