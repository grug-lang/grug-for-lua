--
-- Backend interface (duck-typed protocol):
--
--   backend:insert_file(new_file, existing_file_or_nil)
--     Called after _recompile_with_hot_reload compiles a file.
--     `existing_file` is the previous GrugFile when hot-reloading, nil otherwise.
--     The backend should migrate / reinitialise entity data as needed.
--
--   backend:init_entity(entity)
--     Called from GrugEntity.new after me_id, file, and state are set.
--     Must set entity.data to backend-specific per-entity state.
--     May raise a Lua error on runtime failure (e.g. STACK_OVERFLOW).
--
--   backend:call_on_function(entity, on_fn_name, ...)
--     Execute the named on_ function on entity with the given arguments.
--     Responsible for pcall, flow-error propagation, and GAME_FN_ERROR handling.
--     Should re-raise errors (including RERAISED_GAME_FN_ERROR) so callers can
--     catch them with their own pcall.
--
local InterpreterBackend = {}
InterpreterBackend.__index = InterpreterBackend

function InterpreterBackend.new()
	return setmetatable({}, InterpreterBackend)
end

-- Migrate entity data when a file is hot-reloaded.
-- For a fresh compile (existing_file == nil) this is a no-op.
function InterpreterBackend:insert_file(new_file, existing_file) -- luacheck: ignore
	if existing_file then
		for entity, _ in pairs(existing_file.entities or {}) do
			entity.file = new_file
			entity.data.file = new_file -- keep _InterpreterEntity in sync
			entity.data:_init_globals(new_file.global_variables)
			new_file.entities[entity] = true
		end
	end
end

-- Populate entity.data with a fresh _InterpreterEntity.
-- Raises a Lua error on runtime failure during global-variable initialisation.
function InterpreterBackend:init_entity(entity) -- luacheck: ignore
	entity.data = _InterpreterEntity.new(entity)
end

-- Execute `on_fn_name` on `entity` with the given arguments.
-- Mirrors the logic that previously lived in _on_fn_proxy_mt.__call.
function InterpreterBackend:call_on_function(entity, on_fn_name, ...) -- luacheck: ignore
	local interp = entity.data
	local ok, err = pcall(interp._run_on_fn, interp, on_fn_name, ...)
	if not ok then
		interp._flow = nil
		-- Game functions may signal errors by throwing a table with
		-- type = "GAME_FN_ERROR". Handle those here.
		if type(err) == "table" and err.type == "GAME_FN_ERROR" then
			interp.state.runtime_error_handler(err.reason, "GAME_FN_ERROR", interp.fn_name, interp.file.relative_path)
			return
		end
		-- Any other Lua error (including RERAISED_GAME_FN_ERROR, STACK_OVERFLOW,
		-- TIME_LIMIT_EXCEEDED): re-raise so the caller's pcall can handle it.
		error(err, 0)
	end
	local flow = interp._flow
	if flow then
		interp._flow = nil
		error(flow.err or flow, 2)
	end
end
