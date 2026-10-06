extends Node
func _ready():
	var files := []
	_scan("res://scripts", files)
	for f in files:
		var s = load(f)
		print("OK " if s and s.can_instantiate() else "FAIL ", f)
	for sh in DirAccess.get_files_at("res://shaders"):
		if sh.ends_with(".gdshader"):
			var shader: Shader = load("res://shaders/" + sh)
			print("shader ", sh, " params=", shader.get_shader_uniform_list().size())
	get_tree().quit()
func _scan(d, out):
	for f in DirAccess.get_files_at(d):
		if f.ends_with(".gd"): out.append(d + "/" + f)
	for sub in DirAccess.get_directories_at(d):
		_scan(d + "/" + sub, out)
