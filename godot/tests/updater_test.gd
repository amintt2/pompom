extends Node
## Test de la comparaison de versions de l'Updater.
func _ready() -> void:
	var cases := [
		["0.2.0", "0.1.0-beta", 1], ["0.1.0", "0.1.0-beta", 1], ["0.1.0-beta", "0.1.0-beta", 0],
		["0.1.0-beta.2", "0.1.0-beta", 1], ["0.1.0-rc", "0.1.0-beta", 1], ["v1.0.0", "0.9.9", 1],
		["0.1.0-alpha", "0.1.0-beta", -1], ["0.10.0", "0.9.0", 1],
	]
	var fails := 0
	for c in cases:
		var got := Updater.compare(c[0], c[1])
		if signi(got) != c[2]:
			fails += 1
			print("FAIL ", c, " got ", got)
	print("UPDATER TEST: %d/%d ok" % [cases.size() - fails, cases.size()])
	get_tree().quit(1 if fails > 0 else 0)
