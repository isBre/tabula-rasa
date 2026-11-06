extends "res://scripts/main.gd"
## Loads the autosave (read-only) and takes a 4-view inspection of every object,
## to review what the agents built. Output: res://tests/worldphotos_*.jpg

func _ready() -> void:
	offline = true
	super._ready()
	if relaunching:
		return
	team.autonomy = false
	team.set_follow(false)
	player.set_process_unhandled_input(false)
	await get_tree().create_timer(1.5).timeout
	var i := 0
	for id in World.entities.keys():
		var n = World._get_entity(id)
		if n == null:
			continue
		var sheet: Image = await team.photographer.contact_sheet(World.world_aabb(n), World.agents.values() + [player.avatar])
		sheet.save_jpg(ProjectSettings.globalize_path("res://tests/worldphotos_%s.jpg" % id))
		i += 1
	relaunching = true
	get_tree().quit()
