--[=[
	@class PlayerSettings
]=]

local require = require(script.Parent.loader).load(script)

local Binder = require("Binder")
local DataStoreStringUtils = require("DataStoreStringUtils")
local PlayerSettingsBase = require("PlayerSettingsBase")
local PlayerSettingsConstants = require("PlayerSettingsConstants")
local PlayerSettingsInterface = require("PlayerSettingsInterface")
local PlayerSettingsUtils = require("PlayerSettingsUtils")
local Remoting = require("Remoting")
local SettingRegistryServiceShared = require("SettingRegistryServiceShared")

local PlayerSettings = setmetatable({}, PlayerSettingsBase)
PlayerSettings.ClassName = "PlayerSettings"
PlayerSettings.__index = PlayerSettings

function PlayerSettings.new(obj, serviceBag)
	local self = setmetatable(PlayerSettingsBase.new(obj, serviceBag), PlayerSettings)

	self._serviceBag = assert(serviceBag, "No serviceBag")
	self._settingRegistryServiceShared = self._serviceBag:GetService(SettingRegistryServiceShared)

	self:_setupRemoting()

	self._maid:GiveTask(self._settingRegistryServiceShared:ObserveRegisteredDefinitionsBrio():Subscribe(function(brio)
		if brio:IsDead() then
			return
		end

		local value = brio:GetValue()
		self:EnsureInitialized(value:GetSettingName(), value:GetDefaultValue())
	end))

	self._maid:GiveTask(PlayerSettingsInterface.Server:Implement(self._obj, self))

	return self
end

function PlayerSettings:EnsureInitialized(settingName, defaultValue)
	assert(DataStoreStringUtils.isValidUTF8(settingName), "Bad settingName")
	assert(defaultValue ~= nil, "defaultValue cannot be nil")

	local attributeName = PlayerSettingsUtils.getAttributeName(settingName)

	-- Paranoid UTF8 check. Don't even initialize this setting.
	if type(defaultValue) == "string" then
		assert(DataStoreStringUtils.isValidUTF8(defaultValue), "Bad UTF8 defaultValue")
	end

	if self._obj:GetAttribute(attributeName) == nil then
		local encoded = PlayerSettingsUtils.encodeForAttribute(defaultValue)

		-- Paranoid UTF8 check
		if type(encoded) == "string" then
			assert(DataStoreStringUtils.isValidUTF8(defaultValue), "Bad UTF8 defaultValue")
		end

		self._obj:SetAttribute(attributeName, encoded)
	end
end

function PlayerSettings:_setupRemoting()
	self._remoting = self._maid:Add(Remoting.new(self._obj, "PlayerSettings", Remoting.Realms.SERVER))

	self._maid:Add(self._remoting.RequestUpdateSettings:Bind(function(player, settingsMap)
		assert(self:GetPlayer() == player, "Bad player")

		return self:_setSettingsMap(settingsMap)
	end))
end

function PlayerSettings:_setSettingsMap(settingsMap)
	assert(type(settingsMap) == "table", "Bad settingsMap")

	for settingName, value in pairs(settingsMap) do
		assert(type(settingName) == "string", "Bad key")

		-- Avoid even letting these be set.
		if not DataStoreStringUtils.isValidUTF8(settingName) then
			warn("[PlayerSettings] - Bad UTF8 settingName. Skipping setting.")
			continue
		end

		local attributeName = PlayerSettingsUtils.getAttributeName(settingName)

		if self._obj:GetAttribute(attributeName) == nil then
			warn(string.format("[PlayerSettings] - Cannot set setting %q on attribute that is not defined on the server.", attributeName))
			continue
		end

		-- Paranoid UTF8 check. Avoid letting this value be set.
		if type(value) == "string" then
			if not DataStoreStringUtils.isValidUTF8(value) then
				warn(string.format("[PlayerSettings] - Bad UTF8 value setting value for %q. Skipping setting.", settingName))
				continue
			end
		end

		local decoded = PlayerSettingsUtils.decodeForNetwork(value)
		local encodedAttribute = PlayerSettingsUtils.encodeForAttribute(decoded)

		if type(encodedAttribute) == "string" then
			-- Paranoid UTF8 check. Avoid letting this value be set.
			if not DataStoreStringUtils.isValidUTF8(encodedAttribute) then
				warn(string.format("[PlayerSettings] - Bad UTF8 encodedAttribute value for %q. Skipping setting.", settingName))
				continue
			end

			-- Paranoid length check. One setting could prevent all from saving if we overflow our save limit.
			if (#encodedAttribute + #settingName) > PlayerSettingsConstants.MAX_SETTINGS_LENGTH then
				warn(string.format("[PlayerSettings] - Setting %q is too long. Skipping setting.", settingName))
				continue
			end
		end

		self._obj:SetAttribute(attributeName, encodedAttribute)
	end
end

return Binder.new("PlayerSettings", PlayerSettings)