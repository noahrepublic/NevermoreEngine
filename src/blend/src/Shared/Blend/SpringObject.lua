--[=[
	This is like a [Spring], but it can be observed, and emits events. It handles [Observable]s and

	@class SpringObject
]=]

local require = require(script.Parent.loader).load(script)

local RunService= game:GetService("RunService")

local Blend = require("Blend")
local DuckTypeUtils = require("DuckTypeUtils")
local Maid = require("Maid")
local Observable = require("Observable")
local Promise = require("Promise")
local Rx = require("Rx")
local Signal = require("Signal")
local Spring = require("Spring")
local SpringUtils = require("SpringUtils")
local StepUtils = require("StepUtils")

local SpringObject = {}
SpringObject.ClassName = "SpringObject"
SpringObject.__index = SpringObject

--[=[
	Constructs a new SpringObject.

	The spring object is initially initialized as a spring at 0, with a target of 0. Upon setting
	a target or position, it will be initialized and begin emitting events.

	If two observables emit different types the spring will retain the speed, damper, and switch to
	an initializes.

	@param target T
	@param speed number | Observable<number> | ValueObject<number> | NumberValue | any
	@param damper number | Observable<number> | NumberValue | any
	@return Spring<T>
]=]
function SpringObject.new(target, speed, damper)
	local self = setmetatable({
		_maid = Maid.new();
		_epsilon = 1e-6;
		Changed = Signal.new();
	}, SpringObject)

--[=[
	Event fires when the spring value changes
	@prop Changed Signal<()> -- Fires whenever the spring initially changes state
	@within SpringObject
]=]
	self._maid:GiveTask(self.Changed)

	if target then
		self:SetTarget(target)
	end

	if speed then
		self.Speed = speed
	end

	if damper then
		self.Damper = damper
	end

	return self
end

--[=[
	Returns whether an object is a SpringObject.
	@param value any
	@return boolean
]=]
function SpringObject.isSpringObject(value)
	return DuckTypeUtils.isImplementation(SpringObject, value)
end

--[=[
	Observes the spring animating
	@return Observable<T>
]=]
function SpringObject:ObserveRenderStepped()
	return self:ObserveOnSignal(RunService.RenderStepped)
end

--[=[
	Alias for [ObserveRenderStepped]

	@return Observable<T>
]=]
function SpringObject:Observe()
	if RunService:IsClient() then
		return self:ObserveOnSignal(RunService.RenderStepped)
	else
		return self:ObserveOnSignal(RunService.Stepped)
	end
end

--[=[
	Observes the current target of the spring

	@return Observable<T>
]=]
function SpringObject:ObserveTarget()
	return Observable.new(function(sub)
		local maid = Maid.new()

		local lastTarget = self.Target

		maid:GiveTask(self.Changed:Connect(function()
			local target = self.Target
			if lastTarget ~= target then
				lastTarget = target
				sub:Fire(target)
			end
		end))

		sub:Fire(lastTarget)

		return maid
	end)
end

function SpringObject:ObserveVelocityOnRenderStepped()
	return self:ObserveVelocityOnSignal(RunService.RenderStepped)
end

--[=[
	Promises that the spring is done, based upon the animating property
	Relatively expensive.

	@param signal RBXScriptSignal | nil
	@return Observable<T>
]=]
function SpringObject:PromiseFinished(signal)
	signal = signal or RunService.RenderStepped

	local maid = Maid.new()
	local promise = maid:Add(Promise.new())

	-- TODO: Mathematical solution?
	local startAnimate, stopAnimate = StepUtils.bindToSignal(signal, function()
		local currentSpring = rawget(self, "_currentSpring")
		if not currentSpring then
			return false
		end

		local animating = SpringUtils.animating(currentSpring, self._epsilon)
		if not animating then
			promise:Resolve(true)
		end

		return animating
	end)

	maid:GiveTask(stopAnimate)
	maid:GiveTask(self.Changed:Connect(startAnimate))
	startAnimate()

	self._maid[promise] = maid

	promise:Finally(function()
		self._maid[promise] = nil
	end)

	maid:GiveTask(function()
		self._maid[promise] = nil
	end)

	return promise
end

function SpringObject:ObserveVelocityOnSignal(signal)
	return Observable.new(function(sub)
		local maid = Maid.new()

		local startAnimate, stopAnimate = StepUtils.bindToSignal(signal, function()
			local currentSpring = rawget(self, "_currentSpring")
			if not currentSpring then
				return false
			end

			local animating = SpringUtils.animating(currentSpring, self._epsilon)
			if animating then
				sub:Fire(SpringUtils.fromLinearIfNeeded(currentSpring.Velocity))
			else
				sub:Fire(SpringUtils.fromLinearIfNeeded(0*currentSpring.Velocity))
			end

			return animating
		end)

		maid:GiveTask(stopAnimate)
		maid:GiveTask(self.Changed:Connect(startAnimate))
		startAnimate()

		return maid
	end)
end

--[=[
	Observes the spring animating
	@param signal RBXScriptSignal
	@return Observable<T>
]=]
function SpringObject:ObserveOnSignal(signal)
	return Observable.new(function(sub)
		local maid = Maid.new()

		local startAnimate, stopAnimate = StepUtils.bindToSignal(signal, function()
			local currentSpring = rawget(self, "_currentSpring")
			if not currentSpring then
				return false
			end

			local animating, position = SpringUtils.animating(currentSpring, self._epsilon)
			sub:Fire(SpringUtils.fromLinearIfNeeded(position))
			return animating
		end)

		maid:GiveTask(stopAnimate)
		maid:GiveTask(self.Changed:Connect(startAnimate))
		startAnimate()

		return maid
	end)
end

--[=[
	Returns true when we're animating
	@return boolean -- True if animating
]=]
function SpringObject:IsAnimating()
	local currentSpring = rawget(self, "_currentSpring")
	if not currentSpring then
		return false
	end

	return (SpringUtils.animating(currentSpring, self._epsilon))
end

--[=[
	Impulses the spring, increasing velocity by the amount given. This is useful to make something shake,
	like a Mac password box failing.

	@param velocity T -- The velocity to impulse with
	@return ()
]=]
function SpringObject:Impulse(velocity)
	local converted = SpringUtils.toLinearIfNeeded(velocity)
	local currentSpring = self:_getSpringForType(velocity)
	currentSpring:Impulse(converted)
	self.Changed:Fire()
end

--[=[
	Sets the actual target. If doNotAnimate is set, then animation will be skipped.

	@param target T -- The target to set
	@param doNotAnimate boolean? -- Whether or not to animate
]=]
function SpringObject:SetTarget(target, doNotAnimate)
	assert(target ~= nil, "Bad target")

	local observable = Blend.toPropertyObservable(target) or Rx.of(target)

	if doNotAnimate then
		local isFirst = true

		self._maid._targetSub = observable:Subscribe(function(unconverted)
			local converted = SpringUtils.toLinearIfNeeded(unconverted)
			assert(converted, "Not a valid converted target")

			local spring = self:_getSpringForType(converted)
			spring:SetTarget(converted, isFirst)
			isFirst = false

			self.Changed:Fire()
		end)
	else
		self._maid._targetSub = observable:Subscribe(function(unconverted)
			local converted = SpringUtils.toLinearIfNeeded(unconverted)
			self:_getSpringForType(converted).Target = converted
			self.Changed:Fire()
		end)
	end
end

--[=[
	Sets the velocity for the spring

	@param velocity T
]=]
function SpringObject:SetVelocity(velocity)
	assert(velocity ~= nil, "Bad velocity")

	local observable = Blend.toPropertyObservable(velocity) or Rx.of(velocity)

	self._maid._velocitySub = observable:Subscribe(function(unconverted)
		local converted = SpringUtils.toLinearIfNeeded(unconverted)

		self:_getSpringForType(0*converted).Velocity = converted
		self.Changed:Fire()
	end)
end

--[=[
	Sets the position for the spring

	@param position T
]=]
function SpringObject:SetPosition(position)
	assert(position ~= nil, "Bad position")

	local observable = Blend.toPropertyObservable(position) or Rx.of(position)

	self._maid._positionSub = observable:Subscribe(function(unconverted)
		local converted = SpringUtils.toLinearIfNeeded(unconverted)
		self:_getSpringForType(converted).Value = converted
		self.Changed:Fire()
	end)
end

--[=[
	Sets the damper for the spring

	@param damper number | Observable<number>
]=]
function SpringObject:SetDamper(damper)
	assert(damper ~= nil, "Bad damper")

	local observable = assert(Blend.toNumberObservable(damper), "Invalid damper")

	self._maid._damperSub = observable:Subscribe(function(unconverted)
		assert(type(unconverted) == "number", "Bad damper")

		local currentSpring = rawget(self, "_currentSpring")
		if currentSpring then
			currentSpring.Damper = unconverted
		else
			self:_getInitInfo().Damper = unconverted
		end

		self.Changed:Fire()
	end)
end

--[=[
	Sets the damper for the spring

	@param speed number | Observable<number>
]=]
function SpringObject:SetSpeed(speed)
	assert(speed ~= nil, "Bad speed")

	local observable = assert(Blend.toNumberObservable(speed), "Invalid speed")

	self._maid._speedSub = observable:Subscribe(function(unconverted)
		assert(type(unconverted) == "number", "Bad damper")

		local currentSpring = rawget(self, "_currentSpring")
		if currentSpring then
			currentSpring.Speed = unconverted
		else
			self:_getInitInfo().Speed = unconverted
		end

		self.Changed:Fire()
	end)
end

--[=[
	Sets the clock function for the spring

	@param clock () -> (number)
]=]
function SpringObject:SetClock(clock)
	assert(type(clock) == "function", "Bad clock clock")

	local currentSpring = rawget(self, "_currentSpring")
	if currentSpring then
		currentSpring.Clock = clock
	else
		self:_getInitInfo().Clock = clock
	end

	self.Changed:Fire()
end

--[=[
	Sets the epsilon for the spring to stop animating

	@param epsilon number
]=]
function SpringObject:SetEpsilon(epsilon)
	assert(type(epsilon) == "number", "Bad epsilon")

	rawset(self, "_epsilon", epsilon)

	self.Changed:Fire()
end

--[=[
	Instantly skips the spring forwards by that amount time
	@param delta number -- Time to skip forwards
	@return ()
]=]
function SpringObject:TimeSkip(delta)
	assert(type(delta) == "number", "Bad delta")

	local currentSpring = rawget(self, "_currentSpring")
	if not currentSpring then
		return
	end

	currentSpring:TimeSkip(delta)
	self.Changed:Fire()
end

function SpringObject:__index(index)
	local currentSpring = rawget(self, "_currentSpring")

	if SpringObject[index] then
		return SpringObject[index]
	elseif index == "Value" or index == "Position" or index == "p" then
		if currentSpring then
			return SpringUtils.fromLinearIfNeeded(currentSpring.Value)
		else
			return 0
		end
	elseif index == "Velocity" or index == "v" then
		if currentSpring then
			return SpringUtils.fromLinearIfNeeded(currentSpring.Velocity)
		else
			return 0
		end
	elseif index == "Target" or index == "t" then
		if currentSpring then
			return SpringUtils.fromLinearIfNeeded(currentSpring.Target)
		else
			return 0
		end
	elseif index == "Damper" or index == "d" then
		if currentSpring then
			return currentSpring.Damper
		else
			return self:_getInitInfo().Damper
		end
	elseif index == "Speed" or index == "s" then
		if currentSpring then
			return currentSpring.Speed
		else
			return self:_getInitInfo().Speed
		end
	elseif index == "Clock" then
		if currentSpring then
			return currentSpring.Clock
		else
			return self:_getInitInfo().Clock
		end
	elseif index == "Epsilon" then
		return self._epsilon
	elseif index == "_currentSpring" then
		local found = rawget(self, "_currentSpring")
		if found then
			return found
		end

		-- Note that sometimes the current spring isn't loaded yet as a type so
		-- we use a number for this.
		error("Internal error: Cannot get _currentSpring, as we aren't initialized yet")
	else
		error(string.format("%q is not a member of SpringObject", tostring(index)))
	end
end

function SpringObject:__newindex(index, value)
	if index == "Value" or index == "Position" or index == "p" then
		self:SetPosition(value)
	elseif index == "Velocity" or index == "v" then
		self:SetVelocity(value)
	elseif index == "Target" or index == "t" then
		self:SetTarget(value)
	elseif index == "Damper" or index == "d" then
		self:SetDamper(value)
	elseif index == "Speed" or index == "s" then
		self:SetSpeed(value)
	elseif index == "Clock" then
		self:SetClock(value)
	elseif index == "Epsilon" then
		self:SetEpsilon(value)
	elseif index == "_currentSpring" then
		error("Cannot set _currentSpring")
	else
		error(string.format("%q is not a member of SpringObject", tostring(index)))
	end
end

--[[
	Callers of this must invoke .Changed after using this method
]]
function SpringObject:_getSpringForType(converted)
	local currentSpring = rawget(self, "_currentSpring")

	if currentSpring == nil then

		-- only happens on init
		local newSpring = Spring.new(converted)

		local foundInitInfo = rawget(self, "_initInfo")
		if foundInitInfo then
			rawset(self, "_initInfo", nil)
			newSpring.Clock = foundInitInfo.Clock
			newSpring.Speed = foundInitInfo.Speed
			newSpring.Damper = foundInitInfo.Damper
		end

		rawset(self, "_currentSpring", newSpring)

		return newSpring
	else
		local currentType = typeof(SpringUtils.fromLinearIfNeeded(currentSpring.Value))
		if currentType == typeof(SpringUtils.fromLinearIfNeeded(converted)) then
			return currentSpring
		else
			local oldDamper = currentSpring.d
			local oldSpeed = currentSpring.s
			local clock = currentSpring.Clock

			local newSpring = Spring.new(converted)
			newSpring.Clock = clock
			newSpring.Speed = oldSpeed
			newSpring.Damper = oldDamper
			rawset(self, "_currentSpring", newSpring)
			return newSpring
		end
	end
end

function SpringObject:_getInitInfo()
	local currentSpring = rawget(self, "_currentSpring")
	if currentSpring then
		error("Should not have currentSpring")
	end

	local foundInitInfo = rawget(self, "_initInfo")
	if foundInitInfo then
		return foundInitInfo
	end

	local value = {
		Clock = os.clock;
		Damper = 1;
		Speed = 1;
	}

	rawset(self, "_initInfo", value)

	return value
end

--[=[
	Cleans up the BaseObject and sets the metatable to nil
]=]
function SpringObject:Destroy()
	self._maid:DoCleaning()
	setmetatable(self, nil)
end

return SpringObject