local GrugDir = {}

GrugDir.__index = function(self, key)
	-- Allow method lookups
	if GrugDir[key] then
		return GrugDir[key]
	end

	-- Directory lookup
	local dir = self.dirs[key]
	if dir ~= nil then
		return dir
	end

	-- File lookup
	local file = self.files[key]
	if file ~= nil then
		return file
	end

	error(("%s not found"):format(tostring(key)), 2)
end

function GrugDir.new(name)
	return setmetatable({
		name = name,
		files = {},
		dirs = {},
	}, GrugDir)
end

function GrugDir:create_entity()
	error(("'%s' is a directory, not a file"):format(self.name), 2)
end
