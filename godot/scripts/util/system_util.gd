class_name SystemUtil
## Petites fonctions systeme (Windows).


## Ajoute / retire un raccourci dans le dossier Demarrage de Windows.
static func set_autostart(enabled: bool) -> void:
	if OS.get_name() != "Windows":
		return
	var lnk := OS.get_environment("APPDATA").path_join("Microsoft/Windows/Start Menu/Programs/Startup/Pompom.lnk")
	if not enabled:
		if FileAccess.file_exists(lnk):
			DirAccess.remove_absolute(lnk)
		return
	var exe := OS.get_executable_path()
	var args := ""
	if not OS.has_feature("template"):
		# lance depuis l'executable Godot : il faut lui donner le chemin du projet
		args = "--path \"%s\"" % ProjectSettings.globalize_path("res://").trim_suffix("/")
	var ps: String = "$s=(New-Object -ComObject WScript.Shell).CreateShortcut('%s');$s.TargetPath='%s';$s.Arguments='%s';$s.WorkingDirectory='%s';$s.Save()" % [
		lnk.replace("'", "''"), exe.replace("'", "''"), args.replace("'", "''"), exe.get_base_dir().replace("'", "''")]
	OS.create_process("powershell.exe", ["-NoProfile", "-WindowStyle", "Hidden", "-Command", ps])
