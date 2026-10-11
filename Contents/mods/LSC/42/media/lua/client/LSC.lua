local get_square = getSquare
local instanceof = instanceof
local PRINT_INTERVAL = 5000 -- milliseconds
local MAX_INT = 2147483647

-- mod data setup
local modDataKey = "LongStandingConstructions"

-- create global mod data with my key
--local globalModData = ModData.getOrCreate(modDataKey)

local getOrSetOriginalThumpDamage = function(object)
    local modData = object:getModData()

    -- record data for object if none exists
    if not modData[modDataKey] then
        local thumpDamage = object:getThumpDmg()
        if thumpDamage == MAX_INT then return end

        modData[modDataKey] = thumpDamage
    end

    return modData[modDataKey]
end

-- function to get threshold of zombies for each object
local lastPrintThreshold = 0
local getThreshold = function(baseObjectType, level)
    local threshold = SandboxVars.LSC[baseObjectType]

    -- add to the threshold based on levels if object has a level
    if level then 
        threshold = threshold + SandboxVars.LSC.ThresholdPerLevel * level
    end

    -- debug print
    local now = getTimestampMs()
    if SandboxVars.LSC.DebugEnabled then
        if now - lastPrintThreshold > PRINT_INTERVAL then 
            lastPrintThreshold = now

            print("Threshold:", threshold)
        end
    end

    return threshold
end

-- function to set thump damage value of objects based on number of attackers
local setObjectThump = function(zombieCount, object, baseObjectType, level)
    local modEnabled = SandboxVars.LSC.ModEnabled -- set here each time to avoid stale values
    if modEnabled == nil then -- enable if sandbox setting becomes nil
        modEnabled = true
    end

    -- get wall type from first part of target string
    local object_string = tostring(object)
    --local objectType = object_string:match("^([^:]+)")

    -- get threshold for object
    local threshold
    if modEnabled then
        threshold = getThreshold(baseObjectType, level) or 2
    else 
        threshold = 0 
    end

    -- set back to original thump damage if past threshold 
    if zombieCount >= threshold then
        if object:getThumpDmg() ~= MAX_INT then return end

        local thumpDamage = getOrSetOriginalThumpDamage(object)
        if thumpDamage == nil or thumpDamage == MAX_INT then return end

        object:setThumpDmg(thumpDamage)

    else -- under threshold
        if not modEnabled then return end -- never set to max int if disabled
        if object:getThumpDmg() == MAX_INT then return end 

        object:setThumpDmg(MAX_INT)
    end
end

-- zombie update handler, includes its target
local lastPrintTarget = 0
local handle_zombie_update = function(zombie)
    local target = zombie:getThumpTarget()
    if not target then return end -- return if no target for zombie

    -- return if it's not any thumpable object
    -- doors and barricades aren't implemented right now but check for them too
    if not instanceof(target, "IsoBarricade") and 
        not instanceof(target, "IsoDoor") and  
        not instanceof(target, "IsoThumpable")
    then return end

    local zombie_count = zombie:getSurroundingThumpers()

    -- get wall type from first part of target string
    local target_string = tostring(target)
    local objectType = target_string:match("^([^:]+)")

    -- extract Lv[x] from object name if it has a level
    local level
    if objectType then
        level = tonumber(objectType:match("Lvl(%d+)$"))
    end

    -- remove level from object type if it's a leveled object
    if level then
        objectType = objectType:gsub("Lvl%d+$", "")
    end

    -- record object data if it isn't recorded yet
    if instanceof(target, "IsoThumpable") then
        getOrSetOriginalThumpDamage(target)

        -- call function to update thump damage value
        setObjectThump(zombie_count, target, objectType, level)
    end

    -- debug print
    if SandboxVars.LSC.DebugEnabled then
        local now = getTimestampMs()
        if now - lastPrintTarget > PRINT_INTERVAL then 
            lastPrintTarget = now
            print("Mod enabled:", SandboxVars.LSC.ModEnabled)
            print("Debug enabled:", SandboxVars.LSC.DebugEnabled)
            print("target: ", target)
            print("Class:", target:getClass():getSimpleName())
            print("Object name:", target:getObjectName())

            if instanceof(target, "IsoThumpable") then
                print("Thump damage:", target:getThumpDmg())
                print("Object type:", objectType)
            end

            print("Object health:", target:getHealth())
            print("Zombie count:", zombie_count)

            if level then
                print("Level:", level)
            end
        end
    end
end

-- zombie update event which includes their target and such
Events.OnZombieUpdate.Add(handle_zombie_update) 
