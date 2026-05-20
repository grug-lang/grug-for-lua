--
-- GrugEntity: the thin public-facing entity wrapper.
-- It holds the file/state references and a backend-specific `data` field.
-- on_ functions are looked up via __index and routed through the backend.
--
local GrugEntity = {}

function GrugEntity:__index(key) -- luacheck: ignore
	local val = rawget(GrugEntity, key)
	if val ~= nil then
		return val
	end

	if type(key) == "string" and string.sub(key, 1, 3) == "on_" then
		local fn = self.state.backend:get_on_fn(self, key)
		rawset(self, key, fn) -- cache: future accesses hit the table directly, no __index
		return fn
	end
end

-- Create a new GrugEntity for `file`.
-- Registers it in file.entities (weak), increments state.next_id,
-- then delegates to backend:init_entity to populate entity.data.
-- May raise a Lua error if a runtime error occurs during initialisation.
function GrugEntity.new(file)
	local self = setmetatable({
		me_id = file.state.next_id,
		file = file,
		state = file.state,
		data = nil, -- set by backend:init_entity
	}, GrugEntity)

	file.entities[self] = true
	file.state.next_id = file.state.next_id + 1

	-- Delegate initialisation of backend-specific data.
	-- For the InterpreterBackend this evaluates global-variable
	-- initialisers and stores an _InterpreterEntity in self.data.
	file.state.backend:init_entity(self)

	return self
end
