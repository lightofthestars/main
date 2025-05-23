local Players = game:GetService("Players")

local Argument = require(script.Parent.Argument)
local Type = require(script.Parent.Parent.Type)

local Command = {
	Argument = Argument,
}
Command.__index = Command

function Command.new(_K, commandAlias, commandDefinition: Type.CommandDefinition, commandArray, from, text)
	return setmetatable({
		_K = _K,
		alias = commandAlias,
		array = commandArray,
		definition = commandDefinition,
		env = commandDefinition and commandDefinition.env,
		from = from,
		fromPlayer = Players:GetPlayerByUserId(from),
		fromRank = _K.Auth.getRank(from),
		text = text,
		undo = string.find(commandAlias, "un", 1, true) == 1,

		args = {},
		preparedArgs = {},
		-- flags = {};
		validated = false,
	}, Command)
end

function Command:shouldRequest(player: Player)
	if self._K._shouldRequestOverride then
		local value = self._K._shouldRequestOverride(self, player)
		if value ~= nil then
			return value
		end
	end
	return self.fromRank <= self._K.Auth.getRank(player.UserId)
end

function Command:requestCommand(player: Player)
	if not self.validated then
		return false
	end

	local userName = if player.Name == player.DisplayName then "" else " @" .. player.Name

	if not self.requested then
		self.requested = {}
	end
	local requested = self.requested[player]
	self.requested[player] = true
	if not requested then
		self._K.Remote.Notify:FireClient(self.fromPlayer, {
			Text = `Requesting <b>{self.alias}</b> command on <b>{player.DisplayName}<font transparency="0.5">{userName}</font></b>.`,
		})
	end

	local accepted = self._K.Remote.RequestCommand:InvokeClient(
		player,
		self.fromPlayer,
		`{self._K.Data.settings.prefix}{self.alias} {player.Name}`
	)

	local status = if accepted
		then "<font color='#0f0'>accepted</font>"
		elseif accepted == false then "<font color='#f00'>denied</font>"
		else "<font transparency='0.5'>already in progress</font>"

	if not requested then
		self._K.Remote.Notify:FireClient(
			self.fromPlayer,
			{ Text = `Command request for <b>{self.alias}</b> was <b>{status}</b>.`, From = player.UserId }
		)
	end

	return accepted
end

function Command:run()
	if not self.validated then
		return false, "Command must be validated before it is run!"
	end

	local run = self.definition[if self._K.IsServer then "run" else "runClient"]
	if not run then
		return
	end

	-- filter args for shouldRequest
	-- TODO: silently fail for userids of lowerRank/shouldRequest
	if self._K.IsServer then
		for argIndex, arg in self.args do
			if arg.definition.shouldRequest and string.find(string.lower(arg.rawType.name), "player", 1, true) then
				-- use instead of lowerRank to request the command to those who aren't higher rank
				local prepared = self.preparedArgs[argIndex]
				if prepared == nil then
					continue
				end

				if typeof(prepared) == "Instance" then
					if arg == self.fromPlayer then
						continue -- don't request self
					end
					if self:shouldRequest(arg) then
						local accepted = self:requestCommand(arg)
						if not accepted then
							return false, "Command request denied."
						end
					end
				else -- table?
					for i, player in prepared do
						if player == self.fromPlayer then
							continue -- don't request self
						end
						if self:shouldRequest(player) then
							prepared[i] = nil
							task.spawn(function()
								local accepted = self:requestCommand(player)
								if accepted then
									-- these ignore hooks, clone self in the future to allow for hooks?
									local soloPrepared = table.clone(self.preparedArgs)
									soloPrepared[argIndex] = { player }
									pcall(run, self, unpack(soloPrepared))
								end
							end)
						end
					end
				end
			end
		end
	end

	self._K.Hook.preCommand:Fire(self)
	if not self.validated then
		return false, self.Error
	end

	local ok, err = pcall(run, self, unpack(self.preparedArgs))
	self.Ran = ok
	self.Error = err
	self._K.Hook.postCommand:Fire(self)

	return ok, err
end

function Command:validate()
	if self.validated then
		return true
	end

	local commandArray = self.array

	-- always try first argument
	if #self.definition.args > 0 and #commandArray < 2 then
		self.text ..= " "
		commandArray[2] = { #self.text, "" }
	end

	-- start from 2 to skip the command name
	for i = 2, #commandArray do
		local argIndex = #self.preparedArgs + 1
		local argPos, rawArg = unpack(commandArray[i])

		local argDefinition = self.definition.args[argIndex]
		if not argDefinition then
			-- end of defined positional arguments
			break
		end

		if argDefinition.permissions then
			if not self._K.Auth.hasArgument(self.from, argDefinition) then
				continue
			end
		end

		-- if last defined argument, concatenate the rest of the command's arguments
		local isLastArgument = argIndex == #self.definition.args
		if isLastArgument then
			local buffer = { rawArg }
			for x = i + 1, #commandArray do
				local _, arg = unpack(commandArray[x])
				table.insert(buffer, arg)
			end
			rawArg = table.concat(buffer, " ")
		end

		local arg = Argument.new(self, argDefinition, argPos, rawArg)
		table.insert(self.args, arg)

		local ok, result = arg:prepare()
		if not ok then
			return false, result or "Argument failed to prepare"
		end
		table.insert(self.preparedArgs, result)

		if isLastArgument then
			self.validated = true
			return true
		end
	end

	for i, argDefinition in self.definition.args do
		local arg = self.args[i]
		if not arg and not argDefinition.optional then
			local first = self.array[1]
			local last = self.array[#self.array]
			self.invalidArg = string.sub(self.text, first[1], last[1] + #last[2])
			self.invalidPos = first[1]
			self.argMissing = `Argument {i} missing: {argDefinition.name}`
			return false, self.argMissing
		end
	end

	self.validated = true
	return true
end

return Command
