extends RefCounted
## The game used to be in Italian. These tables translate the old Italian names that can
## still turn up in saves, in user://settings.cfg, in logs/usage.csv and in scripts the
## agents wrote back then, so old worlds keep loading after the switch to English.

const AGENTS := {
	"Architetto": "Architect", "Paesaggista": "Landscaper", "Decoratore": "Decorator",
	"Ingegnere": "Engineer", "Scultore": "Sculptor", "Critico": "Critic",
}

const PALETTE := {
	"pietra": "stone", "roccia": "rock", "mattoni": "brick", "intonaco": "plaster", "tetto": "roof_tiles",
	"tegole_blu": "blue_slate", "legno": "wood", "legno_chiaro": "light_wood", "corteccia_betulla": "birch_bark",
	"erba": "grass", "foglie": "leaves", "foglie_scure": "dark_leaves", "foglie_chiare": "light_leaves",
	"foglie_autunno": "autumn_leaves", "terra": "dirt", "sabbia": "sand", "neve": "snow", "acqua": "water",
	"vetro": "glass", "metallo": "metal", "ferro_scuro": "dark_iron", "oro": "gold", "rame": "copper",
	"tessuto_rosso": "red_fabric", "tessuto_blu": "blue_fabric", "tessuto_verde": "green_fabric", "crema": "cream",
	"bianco_caldo": "warm_white", "ceramica": "ceramic", "nero": "black", "luce_calda": "warm_light",
}

const GROUNDS := {"griglia": "grid", "prato": "grass", "sabbia": "sand", "neve": "snow", "pietra": "stone", "terra": "dirt"}

const HAIR_STYLES := {"corti": "short", "lunghi": "long", "cresta": "mohawk", "calvo": "bald"}

const HATS := {"nessuno": "none", "berretto": "cap", "cilindro": "top_hat", "cuoco": "chef", "paglia": "straw", "corona": "crown"}

const MODELS := {
	"bancarella_mercato": "market_stall", "divano_tessuto_blu": "blue_fabric_sofa",
	"frigorifero_retro_crema": "retro_cream_fridge", "panchina_legno": "wooden_bench",
}

const BLUEPRINTS := {"casetta_intonaco": "plastered_cottage", "lampione": "streetlight"}

const OUTPUT_KINDS := {
	"a_te": "to_player", "tra_agenti": "between_agents", "pensieri": "thoughts", "codice": "code",
	"modelli": "models", "lavagna": "board", "strumenti": "tools",
}


static func agent(agent_name: String) -> String:
	return AGENTS.get(agent_name, agent_name)


static func palette(mat_name: String) -> String:
	return PALETTE.get(mat_name, mat_name)


static func model(id: String) -> String:
	return MODELS.get(id, id)


static func blueprint(bp_name: String) -> String:
	return BLUEPRINTS.get(bp_name, bp_name)


static func ground(g: String) -> String:
	return GROUNDS.get(g, g)


## An appearance dictionary with the old hair style and hat names translated.
static func look(d: Dictionary) -> Dictionary:
	var out := d.duplicate()
	if out.has("hair_style"):
		out["hair_style"] = HAIR_STYLES.get(str(out["hair_style"]), str(out["hair_style"]))
	if out.has("hat"):
		out["hat"] = HATS.get(str(out["hat"]), str(out["hat"]))
	return out


## The key under which settings.cfg stores something for an agent: its name, or the old
## Italian name of a built-in agent. "" if there is nothing.
static func settings_key(cfg: ConfigFile, section: String, agent_name: String) -> String:
	if cfg.has_section_key(section, agent_name):
		return agent_name
	for old in AGENTS:
		if AGENTS[old] == agent_name and cfg.has_section_key(section, old):
			return old
	return ""


## Translates an old save in place (authors, board, agents, models, ground).
static func migrate_save(data: Dictionary) -> void:
	for e in data.get("entities", []):
		if not e is Dictionary:
			continue
		e["author"] = agent(str(e.get("author", "?")))
		if e.get("kind") == "asset":
			e["asset"] = model(str(e.get("asset", "")))
	var board = data.get("board")
	if board is Dictionary:
		var nb := {}
		for k in board:
			nb[agent(str(k))] = board[k]
		data["board"] = nb
	var agents = data.get("agents")
	if agents is Dictionary:
		var positions = agents.get("positions")
		if positions is Dictionary:
			var np := {}
			for k in positions:
				np[agent(str(k))] = positions[k]
			agents["positions"] = np
		var hidden = agents.get("hidden")
		if hidden is Array:
			agents["hidden"] = hidden.map(func(h): return agent(str(h)))
		for def in agents.get("custom", []):
			if def is Dictionary and def.get("look") is Dictionary:
				def["look"] = look(def["look"])
	var env = data.get("environment")
	if env is Dictionary and env.has("ground"):
		env["ground"] = ground(str(env["ground"]))


## Renames the old Italian keys in user://settings.cfg once (agents' models and looks, chat
## filters), so personal settings survive the switch to English.
static func migrate_settings(path: String) -> void:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return
	var changed := false
	for section in ["models", "looks"]:
		for old in AGENTS:
			if not cfg.has_section_key(section, old):
				continue
			var v = cfg.get_value(section, old)
			if section == "looks" and v is Dictionary:
				v = look(v)
			if not cfg.has_section_key(section, AGENTS[old]):
				cfg.set_value(section, AGENTS[old], v)
			cfg.erase_section_key(section, old)
			changed = true
	if cfg.has_section_key("chat", "filter") and cfg.get_value("chat", "filter") is Dictionary:
		var f: Dictionary = cfg.get_value("chat", "filter")
		var kinds := {"squadra": "team", "azioni": "actions", "pensieri": "thoughts", "sistema": "system"}
		var nf := {}
		for k in f:
			nf[kinds.get(k, k)] = f[k]
		if nf != f:
			cfg.set_value("chat", "filter", nf)
			changed = true
	if changed:
		cfg.save(path)
