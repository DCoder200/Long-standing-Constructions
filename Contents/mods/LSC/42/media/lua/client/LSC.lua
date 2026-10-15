print("### LSC STARTED ###")

-- toggles
local modEnabled = SandboxVars.LSC.ModEnabled
local debug = SandboxVars.LSC.DebugEnabled

-- set to true if they're nil for whatever reason
local modEnabled = SandboxVars.LSC.ModEnabled
if modEnabled == nil then modEnabled = true end

local debug = SandboxVars.LSC.DebugEnabled
if debug == nil then debug = true end

local instanceof = instanceof
local PRINT_INTERVAL = 5 -- seconds
local MAX_INT = 2147483647

-- track health values of barricades and doors at runtime (don't need to store this data)
local barricadesAndDoors = {}

-- track when each wall was last attacked during runtime
local attackTimestamps = {}

-- mod data setup
local modDataKey = "LongStandingConstructions"

-- declare global mod data, set it up when it's initialised 
local globalModData
local dataLoaded = function()
    globalModData = ModData.getOrCreate(modDataKey) -- get or create global mod data with my mod key
end

-- record or return original thump damage values for objects
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

-- reset of object
local resetObject = function(object)
    local now = getTimestamp()

    -- treat an untracked object as if it's just been attacked by setting up runtime value
    if not attackTimestamps[object] then
        attackTimestamps[object] = {}
    end

    if not attackTimestamps[object].lastAttacked then
        attackTimestamps[object].lastAttacked = now
    end

    local timestamp = attackTimestamps[object].lastAttacked

    -- check when object was last attacked
    if now - timestamp > 10 then
        local originalThump = getOrSetOriginalThumpDamage(object)

        -- reset thump damage
        local currentThump = object:getThumpDmg()

        -- return skip if there's no original thump but current thump is a normal value
        if not originalThump and currentThump ~= MAX_INT then return true end

        if currentThump ~= originalThump then
            object:setThumpDmg(originalThump)

            if debug then
                print("Current thump: ", currentThump)
                print("Reset to: ", originalThump)
            end
        end

        -- delete object mod data
        local modData = object:getModData()
        if modData then 
            modData[modDataKey] = nil
        end 

        return true -- return success

    else -- attacked recently
        return false -- return fail
    end
end

-- function to periodically cleanup data and reset objects that aren't in play
local cleanup = function()
    if not globalModData then return end

    if debug then print("running cleanup") end

    -- go through each square inside global data
    for key, data in pairs(globalModData) do
        local skippedOne = false -- flag this to true if any valid objects in the square were skipped

        if debug then print("LSC: Saved entry:", key, data.x, data.y, data.z) end

        -- get square from xyz
        local square = getCell():getGridSquare(data.x, data.y, data.z)
        if square then  

            -- go through objects within grid square looking for thumpables 
            local objects = square:getObjects()
            if objects then 

                -- objects is a java array list of iso objects
                for i = 0, objects:size() - 1 do
                    local object = objects:get(i)

                    -- if it's a thumpable
                    if instanceof(object, "IsoThumpable") then
                        if not resetObject(object) then skippedOne = true end
                    end
                end
            end

            -- if no objects were skipped for reversion then delete the square from global data
            -- also only do it if square exists (is loaded)
            if not skippedOne then
                globalModData[key] = nil
            end
        end
    end
end

-- record modified squares
local recordModified = function(object)
    local square = object:getSquare()
    if not square then return end

    local x, y, z = object:getX(), object:getY(), object:getZ()
    local key = x .. "_" .. y .. "_" .. z

    if globalModData[key] then return end -- don't re-record

    -- record tile coordinate entry
    globalModData[key] = { x = x, y = y, z = z }

    if debug then
        print("Global entry added:", globalModData[key].x, globalModData[key].y, globalModData[key].z)
    end
end

-- function to get threshold of zombies for each object
local lastPrintThreshold = 0
local getThreshold = function(baseObjectType, level, numberPlanks)
    if not modEnabled then return 1 end -- return 1 if mod disabled

    local threshold = SandboxVars.LSC[baseObjectType]

    -- add to the threshold based on levels if object has a level
    if level then 
        threshold = math.floor(threshold + SandboxVars.LSC.ThresholdPerLevel * level)
    end

    -- add to the threshold of plank barricades based on number of planks
    if baseObjectType == "BarricadePlanks" then
        threshold = math.floor(threshold + SandboxVars.LSC.AddedPlankThreshold * numberPlanks)
    end

    -- debug print
    local now = getTimestamp()
    if debug then
        if now - lastPrintThreshold > PRINT_INTERVAL then 
            lastPrintThreshold = now

            if numberPlanks then print("Planks: ", numberPlanks) end

            print("Object: ", baseObjectType)
            print("Threshold: ", threshold)
        end
    end

    -- return 2 for unknown objects
    if not threshold or threshold == nil then threshold = 2 end

    return threshold
end

-- function to set thump damage value of walls based on number of attackers
local handleWall = function(zombieCount, wall, wallType, level)

    -- record attack timestamp
    local now = getTimestamp()
    if not attackTimestamps[wall] then
        attackTimestamps[wall] = {}
    else
        attackTimestamps[wall].lastAttacked = now
    end

    -- get threshold for object
    local threshold = getThreshold(wallType, level)

    -- set back to original thump damage if past threshold 
    if zombieCount >= threshold then
        if wall:getThumpDmg() ~= MAX_INT then return end

        local thumpDamage = getOrSetOriginalThumpDamage(wall)
        if thumpDamage == nil or thumpDamage == MAX_INT then return end

        wall:setThumpDmg(thumpDamage)

    else -- under threshold
        if not modEnabled then return end -- never set to max int if disabled

        -- record that the tile the object is on contains modified objects 
        recordModified(wall)

        if wall:getThumpDmg() == MAX_INT then return end 
        wall:setThumpDmg(MAX_INT)
    end
end

-- function to handle barricades and doors
local handleBarricade = function(zombieCount, barricade)
    local countPlanks

    -- get barricade type using IsoBarricade methods
    local barricadeType 
    if barricade:isMetal() then
        barricadeType = "BarricadeMetalSheet"
    elseif barricade:isMetalBar() then
        barricadeType = "BarricadeMetalBar"
    else
        barricadeType = "BarricadePlanks"
        countPlanks = barricade:getNumPlanks()
    end

    -- get threshold for object (pass nil for level because barricades have none)
    local threshold = getThreshold(barricadeType, nil, countPlanks)

    -- over threshold, remove dictionary entry so it can be refreshed if it goes back below threshold
    if zombieCount >= threshold then
        if not barricadesAndDoors[barricade] then return end
        barricadesAndDoors[barricade] = nil

    else -- under threshold, take note of health and keep restoring it
        if not barricadesAndDoors[barricade] then
            barricadesAndDoors[barricade] = {health = barricade:getHealth()}
        end

        -- set health to what's been recorded while below threshold for each hit 
        local recordedHealth = barricadesAndDoors[barricade].health
        if barricade:getHealth() >= recordedHealth then return end
        barricade:setHealth(recordedHealth)
    end
end

-- function to handle garage doors, could be merged into handleBarricade but might diverge in the future
local handleGarageDoor = function(zombieCount, garageDoor)

    -- get threshold for object
    local threshold = getThreshold("GarageDoor")

    -- over threshold, remove dictionary entry so it can be refreshed if it goes back below threshold
    if zombieCount >= threshold then
        if not barricadesAndDoors[garageDoor] then return end
        barricadesAndDoors[garageDoor] = nil

    else -- under threshold, take note of health and keep restoring it
        if not barricadesAndDoors[garageDoor] then
            barricadesAndDoors[garageDoor] = {health = garageDoor:getHealth()}
        end

        -- set health to what's been recorded while below threshold for each hit 
        local recordedHealth = barricadesAndDoors[garageDoor].health
        if garageDoor:getHealth() >= recordedHealth then return end
        garageDoor:setHealth(recordedHealth)
    end
end

-- zombie update handler, includes its target
local lastPrintTarget = 0
local handleZombieUpdate = function(zombie)
    local target = zombie:getThumpTarget()
    if not target then return end -- return if no target for zombie

    -- return if it's not any thumpable object
    if not instanceof(target, "IsoBarricade") and 
        not instanceof(target, "IsoDoor") and  
        not instanceof(target, "IsoThumpable") and 
        not instanceof(target, "IsoWindowFrame") and
        not instanceof(target, "IsoWindow")
    then return end

    local zombieCount = zombie:getSurroundingThumpers()

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

    -- walls
    if instanceof(target, "IsoThumpable") then
        getOrSetOriginalThumpDamage(target) -- record object data if it isn't recorded yet

        -- call function to update thump damage value
        handleWall(zombieCount, target, objectType, level)
    end

    -- barricades
    if instanceof(target, "IsoBarricade") then--or instanceof(target, "IsoDoor") then
        handleBarricade(zombieCount, target)
    end

    -- window frames, windows, and doors, could have barricades on 1 or 2 sides
    if instanceof(target, "IsoDoor") or 
        instanceof(target, "IsoWindowFrame") or
        instanceof(target, "IsoWindow") 
    then

        -- get barricade relevant to zombie with class static method
        local barricade = target:getBarricadeForCharacter(zombie)

        -- handle barricade if there is one
        if barricade then
            handleBarricade(zombieCount, barricade)
        end

        -- handle garage doors
        if instanceof(target, "IsoDoor") then

            -- if it has a garage door index of 0 or more then it's a garage door
            local garageDoorIndex = IsoDoor.getGarageDoorIndex(target)
            if garageDoorIndex ~= -1 then
                handleGarageDoor(zombieCount, target)
            end
        end
    end

    -- debug print
    if debug then
        local now = getTimestamp()
        if now - lastPrintTarget > PRINT_INTERVAL then 
            lastPrintTarget = now
            print("Mod enabled:", modEnabled)
            print("Debug enabled:", debug)
            print("target: ", target)
            
            -- some doors don't have get simple name method, windows don't either
            if not instanceof(target, "IsoDoor") and not instanceof(target, "IsoWIndow") then 
                print("Class:", target:getClass():getSimpleName()) 
            end

            print("Object name:", target:getObjectName())

            if instanceof(target, "IsoThumpable") then
                print("Thump damage:", target:getThumpDmg())
                print("Object type:", objectType)
            end

            if instanceof(target, "IsoBarricade") then
                print("Is metal:", target:isMetal())
                print("Is metal bar:", target:isMetalBar())
            end

            if not instanceof(target, "IsoWindowFrame") then 
                print("Object health:", target:getHealth()) 
            end

            print("Zombie count:", zombieCount)

            if level then
                print("Level:", level)
            end
        end
    end
end

-- zombie update event which includes their target and such
Events.OnZombieUpdate.Add(handleZombieUpdate) 

-- triggers cleanup each hour ingame
Events.EveryHours.Add(cleanup)

-- triggers once global data is retrieved by the game
Events.OnInitGlobalModData.Add(dataLoaded)
