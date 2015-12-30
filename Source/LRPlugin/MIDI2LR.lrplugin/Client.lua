--[[----------------------------------------------------------------------------

Client.lua

Receives and processes commands from MIDI2LR
Sends parameters to MIDI2LR
 
This file is part of MIDI2LR. Copyright 2015 by Rory Jaffe.

MIDI2LR is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later version.

MIDI2LR is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with
MIDI2LR.  If not, see <http://www.gnu.org/licenses/>. 
------------------------------------------------------------------------------]]

require 'Develop_Params.lua' -- global table of develop params we need to observe
local Limits = require 'Limits'
local Ut     = require 'Utilities'
local LrApplication       = import 'LrApplication'
local LrApplicationView   = import 'LrApplicationView'
local LrDevelopController = import 'LrDevelopController'
local LrDialogs           = import 'LrDialogs'
local LrFunctionContext   = import 'LrFunctionContext'
local LrSelection         = import 'LrSelection'
local LrShell             = import 'LrShell'
local LrSocket            = import 'LrSocket'
local LrTasks             = import 'LrTasks'
local LrUndo              = import 'LrUndo'
-- signal for halt plugin if reloaded--LR doesn't kill main loop otherwise
currentLoadVersion = rawget (_G, 'currentLoadVersion') or 0  
currentLoadVersion = currentLoadVersion + 1 

--[[-----------debug section, enable by adding - to beginning this line
local LrMobdebug = import 'LrMobdebug'
LrMobdebug.start()
--]]-----------end debug section


MIDI2LR = {RECEIVE_PORT = 58763, SEND_PORT = 58764, PICKUP_THRESHOLD = 4, CONTROL_MAX = 127, BUTTON_ON = 127; --constants
  LAST_PARAM = '', PARAM_OBSERVER = {}, PICKUP_ENABLED = true, SERVER = {} } --non-local but in MIDI2LR namespace


-------------preferences
do

  local prefs = import 'LrPrefs'.prefsForPlugin() 
  prefs = prefs or {}
  MIDI2LR.Presets = prefs.Presets or {} -- read only global to access preferences
  LrTasks.startAsyncTask( function ()
      local currentMod = LrApplicationView.getCurrentModuleName()
      if currentMod ~= 'develop' then
        LrApplicationView.switchToModule('develop')
      end
      repeat
        LrTasks.sleep(1) -- problem with getting limits too early, getRange doesn't work
      until LrApplication.activeCatalog():getTargetPhoto() --need to have a photo selected for limits to work
      for i,v in pairs(Limits.GetPreferences()) do
        MIDI2LR[i] = v
      end
      if currentMod ~= 'develop' then
        LrApplicationView.switchToModule(currentMod)
      end
    end  )

  MIDI2LR.PasteList = prefs.PasteList or {}
end
-------------end preferences section

--File local function declarations (advance declared to allow it to be in scope for all calls. 
--When defining function, DO NOT USE local KEYWORD, as it will define yet another local function.
--These declaration are intended to get around some Lua gotcha's.
local develop_lerp_to_midi
local midi_lerp_to_develop
local processMessage
local sendChangedParams
local startServer
local updateParam

local function PasteSelectedSettings ()
  if MIDI2LR.Copied_Settings == nil then return end 
  if LrApplicationView.getCurrentModuleName() ~= 'develop' then
    LrApplicationView.switchToModule('develop')
  end
  for _,param in ipairs (DEVELOP_PARAMS) do --having trouble iterating pastelist--observable table iterator issue?
    if (MIDI2LR.PasteList[param]==true and MIDI2LR.Copied_Settings[param]~=nil) then
      MIDI2LR.PARAM_OBSERVER[param] = MIDI2LR.Copied_Settings[param]
      LrDevelopController.setValue(param,MIDI2LR.Copied_Settings[param])
    end
  end
end


local function PasteSettings  ()
  if MIDI2LR.Copied_Settings == nil then return end
  if LrApplicationView.getCurrentModuleName() ~= 'develop' then
    LrApplicationView.switchToModule('develop')
  end
  LrTasks.startAsyncTask ( function () 
      LrApplication.activeCatalog():withWriteAccessDo(
        'MIDI2LR: Paste settings', 
        function() LrApplication.activeCatalog():getTargetPhoto():applyDevelopSettings(MIDI2LR.Copied_Settings) end,
        { timeout = 4, 
          callback = function() LrDialogs.showError(LOC('$$$/MIDI2LR/Client/writeaccesscopy=Unable to get catalog write access for copy settings')) end, 
          asynchronous = true }
      ) 
    end )
end

local function CopySettings ()
  LrTasks.startAsyncTask ( 
    function () MIDI2LR.Copied_Settings = LrApplication.activeCatalog():getTargetPhoto():getDevelopSettings() end
  ) 
end

local function ApplyPreset(presetUuid)
  if presetUuid == nil then
    return
  end
  local preset = LrApplication.developPresetByUuid(presetUuid)
  LrTasks.startAsyncTask ( function () 
      LrApplication.activeCatalog():withWriteAccessDo(
        'Apply preset '..preset:getName(), 
        function() LrApplication.activeCatalog():getTargetPhoto():applyDevelopPreset(preset) end,
        { timeout = 4, 
          callback = function() LrDialogs.showError(LOC('$$$/MIDI2LR/Client/writeaccesspaste=Unable to get catalog write access for paste preset ^1',preset:getName())) end, 
          asynchronous = true }
      ) 
    end )
end

local function addToCollection()
  local catalog = LrApplication.activeCatalog()
  local quickname = catalog.kQuickCollectionIdentifier
  local targetname = catalog.kTargetCollection
  local quickcollection, targetcollection
  LrTasks.startAsyncTask (
    function () 
      LrApplication.activeCatalog():withWriteAccessDo( 
        '',
        function()
          quickcollection = catalog:createCollection(quickname,nil,true)
          targetcollection = catalog:createCollection(targetname,nil,true)
        end,
        { timeout = 4, 
          callback = function() LrDialogs.showError(LOC('$$$/MIDI2LR/Client/addtocollection=Unable to get catalog write access for add to collection.')) end, 
          asynchronous = true 
        }
      )
    end
  )
  return function(collectiontype,photos)
    local CollectionName
    if collectiontype == 'quick' then
      CollectionName = "$$$/AgLibrary/ThumbnailBadge/AddToQuickCollection=Add to Quick Collection."
    else
      CollectionName = "$$$/AgLibrary/ThumbnailBadge/AddToTargetCollection=Add to Target Collection"
    end
    LrTasks.startAsyncTask ( 
      function () 
        LrApplication.activeCatalog():withWriteAccessDo( 
          CollectionName,
          function()
            if LrApplication.activeCatalog() ~= catalog then
              catalog = LrApplication.activeCatalog()
              quickname = catalog.kQuickCollectionIdentifier
              targetname = catalog.kTargetCollection
              quickcollection = catalog:createCollection(quickname,nil,true)
              targetcollection = catalog:createCollection(targetname,nil,true)
            elseif catalog.kTargetCollection ~= targetname then
              targetcollection = catalog:createCollection(targetname,nil,true)
            end
            local usecollection
            if collectiontype == 'quick' then
              usecollection = quickcollection
            else
              usecollection = targetcollection
            end
            if type(photos)==table then
              usecollection:addPhotos(photos)
            else
              usecollection:addPhotos {photos}
            end
          end,
          { timeout = 4, 
            callback = function() LrDialogs.showError(LOC('$$$/MIDI2LR/Client/addtocollection=Unable to get catalog write access for add to collection.')) end, 
            asynchronous = true 
          }
        )
      end
    )
  end
end

addToCollection = addToCollection()

local ACTIONS = {
  CopySettings     = CopySettings,
  DecreaseRating   = LrSelection.decreaseRating,
  DecrementLastDevelopParameter = function() Ut.execFOM(LrDevelopController.decrement,MIDI2LR.LAST_PARAM) end,
  IncreaseRating   = LrSelection.increaseRating,
  IncrementLastDevelopParameter = function() Ut.execFOM(LrDevelopController.increment,MIDI2LR.LAST_PARAM) end,
  Next             = LrSelection.nextPhoto,
  PasteSelectedSettings = PasteSelectedSettings,
  PasteSettings    = PasteSettings,
  Pick             = LrSelection.flagAsPick,
  Prev             = LrSelection.previousPhoto,
  Profile_Adobe_Standard   = Ut.wrapFOM(LrDevelopController.setValue,'CameraProfile','Adobe Standard'),
  Profile_Camera_Clear     = Ut.wrapFOM(LrDevelopController.setValue,'CameraProfile','Camera Clear'),
  Profile_Camera_Deep      = Ut.wrapFOM(LrDevelopController.setValue,'CameraProfile','Camera Deep'),
  Profile_Camera_Landscape = Ut.wrapFOM(LrDevelopController.setValue,'CameraProfile','Camera Landscape'),
  Profile_Camera_Light     = Ut.wrapFOM(LrDevelopController.setValue,'CameraProfile','Camera Light'),
  Profile_Camera_Neutral   = Ut.wrapFOM(LrDevelopController.setValue,'CameraProfile','Camera Neutral'),
  Profile_Camera_Portrait  = Ut.wrapFOM(LrDevelopController.setValue,'CameraProfile','Camera Portrait'),
  Profile_Camera_Standard  = Ut.wrapFOM(LrDevelopController.setValue,'CameraProfile','Camera Standard'),
  Profile_Camera_Vivid     = Ut.wrapFOM(LrDevelopController.setValue,'CameraProfile','Camera Vivid'),
  Redo             = LrUndo.redo,
  Reject           = LrSelection.flagAsReject,
  RemoveFlag       = LrSelection.removeFlag,
  ResetAll         = Ut.wrapFOM(LrDevelopController.resetAllDevelopAdjustments),
  ResetBrushing    = Ut.wrapFOM(LrDevelopController.resetBrushing),
  ResetCircGrad    = Ut.wrapFOM(LrDevelopController.resetCircularGradient),
  ResetCrop        = Ut.wrapFOM(LrDevelopController.resetCrop),
  ResetGradient    = Ut.wrapFOM(LrDevelopController.resetGradient),
  ResetLast        = function() Ut.execFOM(LrDevelopController.resetToDefault,MIDI2LR.LAST_PARAM) end,
  ResetRedeye      = Ut.wrapFOM(LrDevelopController.resetRedeye),
  ResetSpotRem     = Ut.wrapFOM(LrDevelopController.resetSpotRemoval),
  SetRating0       = function () LrSelection.setRating(0) end,
  SetRating1       = function () LrSelection.setRating(1) end,
  SetRating2       = function () LrSelection.setRating(2) end,
  SetRating3       = function () LrSelection.setRating(3) end,
  SetRating4       = function () LrSelection.setRating(4) end,
  SetRating5       = function () LrSelection.setRating(5) end,
  ToggleBlue       = LrSelection.toggleBlueLabel,
  ToggleGreen      = LrSelection.toggleGreenLabel,
  TogglePurple     = LrSelection.togglePurpleLabel,
  ToggleRed        = LrSelection.toggleRedLabel,
  ToggleScreenTwo  = LrApplicationView.toggleSecondaryDisplay,
  ToggleYellow     = LrSelection.toggleYellowLabel,
  ToggleZoomOffOn  = LrApplicationView.toggleZoom,
  Undo             = LrUndo.undo,
  UprightAuto      = Ut.wrapFOM(LrDevelopController.setValue,'PerspectiveUpright',1),
  UprightFull      = Ut.wrapFOM(LrDevelopController.setValue,'PerspectiveUpright',2),
  UprightLevel     = Ut.wrapFOM(LrDevelopController.setValue,'PerspectiveUpright',3),
  UprightOff       = Ut.wrapFOM(LrDevelopController.setValue,'PerspectiveUpright',0),
  UprightVertical  = Ut.wrapFOM(LrDevelopController.setValue,'PerspectiveUpright',4),
  VirtualCopy      = function () LrApplication.activeCatalog():createVirtualCopies() end,
  ZoomInLargeStep  = LrApplicationView.zoomIn,
  ZoomInSmallStep  = LrApplicationView.zoomInSome,
  ZoomOutLargeStep = LrApplicationView.zoomOut,
  ZoomOutSmallStep = LrApplicationView.zoomOutSome,
}

local TOOL_ALIASES = {
  AdjustmentBrush = 'localized',
  CropOverlay     = 'crop',
  GraduatedFilter = 'gradient',
  Loupe           = 'loupe',
  RadialFilter    = 'circularGradient',
  RedEye          = 'redeye',
  SpotRemoval     = 'dust',
}

local TOGGLE_PARAMETERS = { --alternate on/off by button presses
  ConvertToGrayscale                     = true,
  EnableCalibration                      = true,
  EnableCircularGradientBasedCorrections = true,
  EnableColorAdjustments                 = true,
  EnableDetail                           = true,
  EnableEffects                          = true,
  EnableGradientBasedCorrections         = true,
  EnableGrayscaleMix                     = true,
  EnableLensCorrections                  = true,
  EnablePaintBasedCorrections            = true,
  EnableRedEye                           = true,
  EnableRetouch                          = true,
  EnableSplitToning                      = true,
}

local TOGGLE_PARAMETERS_01 = { --alternate on/off, but 0/1 rather than false/true
  AutoLateralCA                          = true,
  LensProfileEnable                      = true,
}


local SETTINGS = {
  Pickup = function(enabled) MIDI2LR.PICKUP_ENABLED = (enabled == 1) end,
}

function midi_lerp_to_develop(param, midi_value)
  -- map midi range to develop parameter range
  local min,max = Limits.GetMinMax(param)
  return midi_value/MIDI2LR.CONTROL_MAX * (max-min) + min
end

function develop_lerp_to_midi(param)
  -- map develop parameter range to midi range
  local min,max = Limits.GetMinMax(param)
  return (LrDevelopController.getValue(param)-min)/(max-min) * MIDI2LR.CONTROL_MAX
end

function updateParam() --closure
  local lastclock, lastparam --tracking for pickup when scrubbing control rapidly
  return function(param, midi_value)
    -- this function does a 'pickup' type of check
    -- that is, it will ensure the develop parameter is close 
    -- to what the inputted command value is before updating it
    if LrApplicationView.getCurrentModuleName() ~= 'develop' then
      LrApplicationView.switchToModule('develop')
    end
    -- if pickup mode, keep LR value within pickup limits so pickup can work
    if Limits.Parameters[param] and MIDI2LR.PICKUP_ENABLED then
      Limits.ClampValue(param)
    end
    -- enable movement if pickup mode is off; controller is within pickup range; 
    -- or control was last used recently and rapidly moved out of pickup range
    if(
      (not MIDI2LR.PICKUP_ENABLED) or
      (math.abs(midi_value - develop_lerp_to_midi(param)) <= MIDI2LR.PICKUP_THRESHOLD) or
      (lastclock + 0.5 > os.clock() and lastparam == param) 
    )
    then
      if MIDI2LR.PICKUP_ENABLED then -- update info to use for detecting fast control changes
        lastclock = os.clock()
        lastparam = param
      end
      local value = midi_lerp_to_develop(param, midi_value)
      MIDI2LR.PARAM_OBSERVER[param] = value
      LrDevelopController.setValue(param, value)
      MIDI2LR.LAST_PARAM = param
    end
  end
end
updateParam = updateParam() --complete closure

-- message processor
function processMessage(message)
  if type(message) == 'string' then
    -- messages are in the format 'param value'
    local _, _, param, value = string.find( message, '(%S+)%s(%S+)' )

    if(ACTIONS[param]) then -- perform a one time action
      if(tonumber(value) == MIDI2LR.BUTTON_ON) then ACTIONS[param]() end
    elseif(param:find('Reset') == 1) then -- perform a reset other than those explicitly coded in ACTIONS array
      if(tonumber(value) == MIDI2LR.BUTTON_ON) then Ut.execFOM(LrDevelopController.resetToDefault,param:sub(6)) end
    elseif(param:find('WhiteBalance') == 1) then -- adjust white balance
      if(tonumber(value) == MIDI2LR.BUTTON_ON) then Ut.execFOM(LrDevelopController.setValue,'WhiteBalance',param:sub(13)) end
    elseif(param:find('SwToM') == 1) then -- perform a switch to module
      if(tonumber(value) == MIDI2LR.BUTTON_ON) then LrApplicationView.switchToModule(param:sub(6)) end
    elseif(param:find('ShoVw') == 1) then -- change application's view mode
      if(tonumber(value) == MIDI2LR.BUTTON_ON) then LrApplicationView.showView(param:sub(6)) end
    elseif(param:find('ShoScndVw') == 1) then -- change application's view mode
      if(tonumber(value) == MIDI2LR.BUTTON_ON) then LrApplicationView.showSecondaryView(param:sub(10)) end
    elseif(param:find('Preset_') == 1) then --apply preset by #
      if(tonumber(value) == MIDI2LR.BUTTON_ON) then ApplyPreset(MIDI2LR.Presets[tonumber(param:sub(8))]) end
    elseif(TOGGLE_PARAMETERS[param]) then --enable/disable 
      if(tonumber(value) == MIDI2LR.BUTTON_ON) then LrDevelopController.setValue(param,not Ut.execFOM(LrDevelopController.getValue,param)) end -- toggle parameters if button on
    elseif(TOGGLE_PARAMETERS_01[param]) then --enable/disable
      if(tonumber(value) == MIDI2LR.BUTTON_ON) then 
        if Ut.execFOM(LrDevelopController.getValue(param)) == 0 then
          LrDevelopController.setValue(param,1)
        else
          LrDevelopController.setValue(param,0)
        end
      end
    elseif(TOOL_ALIASES[param]) then -- switch to desired tool
      if(tonumber(value) == MIDI2LR.BUTTON_ON) then 
        if(LrDevelopController.getSelectedTool() == TOOL_ALIASES[param]) then -- toggle between the tool/loupe
          Ut.execFOM(LrDevelopController.selectTool,'loupe')
        else
          Ut.execFOM(LrDevelopController.selectTool,TOOL_ALIASES[param])
        end
      end
    elseif(SETTINGS[param]) then
      SETTINGS[param](tonumber(value))
    else -- otherwise update a develop parameter
      updateParam(param, tonumber(value))
    end
  end
end

-- send changed parameters to MIDI2LR
-- only works while in develop module 
-- if I add change to module at beginning
-- and change back at end, program ends up
-- switching to develop module whenever
-- a picture is selected--an unwanted behavior
function sendChangedParams( observer ) 
  if LrApplicationView.getCurrentModuleName() ~= 'develop' then return end
  for _, param in ipairs(DEVELOP_PARAMS) do
    if(observer[param] ~= LrDevelopController.getValue(param)) then
      MIDI2LR.SERVER:send(string.format('%s %g\n', param, develop_lerp_to_midi(param)))
      observer[param] = LrDevelopController.getValue(param)
      MIDI2LR.LAST_PARAM = param
    end
  end
end

function startServer(context)
  MIDI2LR.SERVER = LrSocket.bind {
    functionContext = context,
    plugin = _PLUGIN,
    port = MIDI2LR.SEND_PORT,
    mode = 'send',
    onClosed = function( socket ) -- this callback never seems to get called...
      -- MIDI2LR closed connection, allow for reconnection
      -- socket:reconnect()
    end,
    onError = function( socket, err )
      socket:reconnect()
    end,
  }
end

-- Main task
LrTasks.startAsyncTask( function()
    LrFunctionContext.callWithContext( 'socket_remote', function( context )
        LrDevelopController.revealAdjustedControls( true ) -- reveal affected parameter in panel track



        -- add an observer for develop param changes
        LrDevelopController.addAdjustmentChangeObserver( context, MIDI2LR.PARAM_OBSERVER, sendChangedParams )

        local client = LrSocket.bind {
          functionContext = context,
          plugin = _PLUGIN,
          port = MIDI2LR.RECEIVE_PORT,
          mode = 'receive',
          onMessage = function(socket, message)
            processMessage(message)
          end,
          onClosed = function( socket )
            -- MIDI2LR closed connection, allow for reconnection
            socket:reconnect()

            -- calling SERVER:reconnect causes LR to hang for some reason...
            MIDI2LR.SERVER:close()
            startServer(context)
          end,
          onError = function(socket, err)
            if err == 'timeout' then -- reconnect if timed out
              socket:reconnect()
            end
          end
        }

        startServer(context)


        local loadVersion = currentLoadVersion  
        while (loadVersion == currentLoadVersion)  do --detect halt or reload
          LrTasks.sleep( 1/2 )
        end

        client:close()
        MIDI2LR.SERVER:close()
      end )
  end )

LrTasks.startAsyncTask( function()
    if(WIN_ENV) then
      LrShell.openFilesInApp({_PLUGIN.path..'/Info.lua'}, _PLUGIN.path..'/MIDI2LR.exe')
    else
      LrShell.openFilesInApp({_PLUGIN.path..'/Info.lua'}, _PLUGIN.path..'/MIDI2LR.app') -- On Mac it seems like the files argument has to include an existing file
    end
  end
)