extends Node
## Measures every model in res://assets/ and writes res://assets/catalog.json.
## Run this scene once after adding new model packs.

func _ready() -> void:
	await get_tree().process_frame
	var n := Assets.rebuild_catalog()
	var f := FileAccess.open("res://tools/build_catalog_output.txt", FileAccess.WRITE)
	f.store_string("catalog: %d models" % n)
	f.close()
	get_tree().quit()
