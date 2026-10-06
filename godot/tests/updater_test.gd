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
	var total := cases.size()
	# versions candidates pour la sonde directe
	var nc := Updater.next_candidates("0.2.2-beta")
	total += 1
	if not (nc.size() > 2 and nc[0] == "0.2.2" and nc[1] == "0.2.3-beta" and nc.has("0.3.0-beta") and nc.has("1.0.0")):
		fails += 1
		print("FAIL next_candidates ", nc)
	# sonde reelle sur GitHub (option --live) : depuis 0.2.1-beta, la 0.2.2-beta publiee doit etre trouvee
	if OS.get_cmdline_user_args().has("--live"):
		ProjectSettings.set_setting("application/config/version", "0.2.1-beta")
		var up := Updater.new()
		add_child(up)
		var t0 := Time.get_ticks_msec()
		var found: bool = await up.probe()
		total += 1
		print("LIVE probe found=%s latest=%s (%d ms)" % [found, up.latest, Time.get_ticks_msec() - t0])
		if not found or Updater.compare(up.latest.get("version", "0"), "0.2.2-beta") < 0:
			fails += 1
			print("FAIL live probe")
	print("UPDATER TEST: %d/%d ok" % [total - fails, total])
	get_tree().quit(1 if fails > 0 else 0)
