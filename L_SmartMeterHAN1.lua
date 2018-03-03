-- Plugin for the Rainforest Eagle 100/200
--
-- Copyright (c) 2017-2018 John Schmitz

-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:

-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.

-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.
--
--
-- based on the version 0.4 from robertmm in the Vera forums
-- converted to use the port 80 and get the json instead of port 5002 with xml
--
-- The IP and DeviceMACID (from the bottom of the device) must be specified.
-- Unlike the robertmm version, this version does not get the MACID automatically.
-- 
-- If the local web access has security enabled, you must provide the CLOUDID
-- and IN from bottom of your Eagle (as CloudId and DeviceIN)  - just the
-- hex value, no Ox in front.
--
-- Adds Price support
--
-- Adds ability to ResetKWH which reports values relative the values at the reset time
--
-- You must manually install "dkjson" - this module relies on it
--
-- Adds StartPeak and EndPeak actions to aid in the tracking of the peak and off peak
-- energy usage in case your supplier uses time of day billing.  Call these actions
-- at the start and stop of your peak period.
--
-- Also adds KWHDeliveredPrior which shows how much energy came in (not net) during
-- the last interval set by the ResetKWH action.  Some utilities have a
-- non-bypassable charge based on the amount of energy delivered regardless of the
-- net during the period.  This variable let's you see how much energy this is.
--
-- Added support (limited) for the Eagle 200 which has a POST interface but responds
-- with XML, not JSON.  Ouch.
-- Set the EagleModel device variable to "200" if that is what you have.  Default is
-- the "100".
--
--
local VERSION                   = "0.55js"
local HA_SERVICE                = "urn:micasaverde-com:serviceId:HaDevice1"
local ENERGY_SERVICE            = "urn:micasaverde-com:serviceId:EnergyMetering1"
local HAN_SERVICE               = "urn:smartmeter-han:serviceId:SmartMeterHAN1"
local HAN_DEFAULT_PULSE         = 300
local HAN_DEFAULT_METERINGTYPE  = "0"
local HAN_IP
local HAN_Device
local HAN_MACID
local HAN_IN
local HAN_CLOUDID
local HAN_MODEL
local HAN_HWADDR
local HAN_MeteringType


local HAN_REQUEST_DETAILS_PRE = [[<Command><Name>device_query</Name><DeviceDetails><HardwareAddress>]]
local HAN_REQUEST_DETAILS_POST = [[</HardwareAddress></DeviceDetails><Components><All>Y</All></Components></Command>]]

-- some test data
local testDeliver = 143313
local testWatts   =   1105
local xmlstringTest = [[<DeviceList>
  <Device>
    <HardwareAddress>0x00078100006a18d7</HardwareAddress>
    <Manufacturer>Generic</Manufacturer>
    <ModelId>electric_meter</ModelId>
    <Protocol>Zigbee</Protocol>
    <LastContact>0x5a11b1cb</LastContact>
    <ConnectionStatus>Connected</ConnectionStatus>
    <NetworkAddress>0x0000</NetworkAddress>
  </Device>
</DeviceList>]]

local function log(msg, level)
  luup.log("SmartMeterHAN1(" .. VERSION .. "): " .. msg, level)
end

-- Convert unsigned hex/decimal string
local function tonumber_u(num)
  if not num then return 0 end
  if (string.sub(num, 1, 2) == "0x") then
    -- Hex
    return tonumber(string.sub(num, 3, -1), 16)
  else
    -- Not hex
    return tonumber(num, 10)
  end
end

-- Prettify kWh output
local function formatkWh(value)
  return string.format("%.1f", (math.floor(value * 1000 + 0.5) / 1000))
end

local lom=require("lxp.lom")

-- some xml parsing functions to be used with the Eagle 200's xml output
-- from the POST request

local function findValueFor(name, xmlTable)
  if type(xmlTable) == 'table' then
    -- found it if the current table has 2 elements each containing a table
    -- where one of those tables has a element "tag" equal to "Name" and
    -- element [1]  has the 'name' as passed into the function.
    -- The other table has to have an element with "tag" equal to "Value".
    -- If it does, then the element [1] is supposed to have the value of
    -- interest
    -- if it is a table, then recurse into it as the lower level table
    -- might be the one of interest
    local foundName = false
    for k,v in pairs(xmlTable) do
      if type(v) == 'table' then
	-- print "looking into table"
	if (v["tag"] == "Name" and v[1] == name) then
	  foundName = true
	  -- print "found Name, so hitting break"
	  break
	end
	-- print "doing recursion"
        local ret = findValueFor(name, v)
        if ret then -- it found something
	  return ret
	end
	  
      end
    end
    if foundName then -- this is the correct parent table, so now search
      -- for the value
      for k,v in pairs(xmlTable) do
        if type(v) == 'table' then
	  if (v["tag"] == "Value") then
	    -- print(v[1])
	    return v[1]
	  end
        end
      end
    end
  else
    return nil
  end
end

local function findValue(name, xmlTable)
  if type(xmlTable) == 'table' then
    -- get value for given tag name, recurse as needed
    -- if it is a table, then recurse into it as the lower level table
    -- might be the one of interest
    for k,v in pairs(xmlTable) do
      if (v["tag"] == name) then
        return (v[1])
      end
      -- print "doing recursion in findValue"
      local ret = findValue(name, v)
      if ret then -- it found something
        return ret
      end
    end
  else
    return nil
  end
end

-- Get variable value.
-- Use HAN_SERVICE and HAN_Device as defaults
local function getVar(name, service, device)
 local value = luup.variable_get(service or HAN_SERVICE, name, tonumber(device or HAN_Device))
 return (value or '')
end

-- Update variable when value is different than current.
-- Use HAN_SERVICE and HAN_Device as defaults
local function setVar(name, value, service, device)
  local service = service or HAN_SERVICE
  local device = tonumber(device or HAN_Device)
  local old = luup.variable_get(service, name, device)
  if value and (tostring(value) ~= old) then 
   luup.variable_set(service, name, value, device)
  end
end

-- same as above, but force value regardless of current value
local function forceSetVar(name, value, service, device)
  local service = service or HAN_SERVICE
  local device = tonumber(device or HAN_Device)
  luup.variable_set(service, name, value, device)
end

--get device Variables, creating with default value if non-existent
local function defVar(name, default, service, device)
  local service = service or HAN_SERVICE
  local device = tonumber(device or HAN_Device)
  local value = luup.variable_get(service, name, device) 
  if (not value) then
    value = default or ''                           -- use default value or blank
    luup.variable_set(service, name, value, device) -- create missing variable with default value
  end
  return value
end

-- Set a luup failure message
local function setluupfailure(status,devID)
  if (luup.version_major < 7) then status = status ~= 0 end -- fix UI5 status type
  luup.set_failure(status,devID)
end

function startup(han_device)
  log("Starting", 2)
  HAN_Device        = han_device
  HAN_IP            = luup.devices[han_device].ip

  -- Set up default values
  HAN_MODEL = defVar("EagleModel", "100")
  defVar("Pulse", HAN_DEFAULT_PULSE, ENERGY_SERVICE)
  defVar("Watts", 0, ENERGY_SERVICE)
  defVar("KWH", 0, ENERGY_SERVICE)
  defVar("LinkStrength", 0)
  defVar("LinkStatus", 0)
  defVar("KWHDelivered", 0)
  defVar("KWHReceived", 0)
  defVar("KWHBaseDelivered", 0)
  defVar("KWHBaseReceived", 0)
  defVar("KWHPeak", 0)
  defVar("KWHOffPeak", 0)
  defVar("PeakPeriod", "OFF")
  defVar("Season", "Summer")
  HAN_MeteringType = defVar("MeteringType", HAN_DEFAULT_METERINGTYPE)
  defVar("dailyMinCharge", "0.32854")
  defVar("NBCRate", "0.02328")
  defVar("Rates", "0,0,0,0")
  HAN_MACID = defVar("DeviceMACID", "")
  HAN_IN = defVar("DeviceIN", "")
  HAN_CLOUDID = defVar("CloudId", "")
  defVar("WholeHouse", 1, ENERGY_SERVICE)
  defVar("ActualUsage", 1, ENERGY_SERVICE)

  if HAN_MODEL ~= "200" then
    log("Eagle Model 100", 2)
    if ((HAN_MACID or "") == "") then
      return false, "Please enter the DeviceMACID of your HAN device", "SmartMeterHAN1"
    end
  else
    -- log("Eagle Model 200", 3)
    log("Eagle Model 200", 2)
    -- get the hardware address of the Eagle 200 
    local xmlstring = retrieveEagleData("device_list")
    -- can use 'xmlstringTest' as defined above for testing
    if xmlstring == nil then
      log("no hardware address, retrieveEagleData returned nil for 'device_list'", 1)
      return false, "Cannot find hardware address of Eagle", "SmartMeterHAN1"
    end
    local tab = lom.parse(xmlstring)
    HAN_HWADDR = findValue("HardwareAddress", tab)
    local connectionStatus = findValue("ConnectionStatus", tab)
    if HAN_HWADDR == nil then
      log("no hardware address", 1)
      return false, "Cannot find hardware address", "SmartMeterHAN1"
    else
      log("Found hardware address: " .. HAN_HWADDR, 3)
    end
    if connectionStatus then
      log("Connection status: " .. connectionStatus, 3)
    end
  end
  if (HAN_IP:match("%d+%.%d+%.%d+%.%d+") == nil) then
    return false, "Please enter the IP address of of your HAN device", "SmartMeterHAN1"
  end

  if HAN_MeteringType == "2" then
    -- different json file for meters that are set up to show both inbound and outbound
    -- power/energy.  default for inbound only is less cluttered and won't show
    -- unneeded zeros (to grid, net)
    -- Note that another luup reload is needed after this, but instead of trying to
    -- detect when this is changed and do it automatically, just instruct the user to
    -- reload - this is a one-time change, not something that happens frequently
    luup.attr_set("device_json", "D_SmartMeterHAN1-2.json", han_device)
  end

  -- start polling in 10 seconds
  luup.call_delay("refreshCache", 10)

  -- handle UI7/UI5 meaning of status
  setluupfailure(0, HAN_Device)
  return true, "OK", "SmartMeterHAN1"
end


function retrieveEagleData(requestName)
  -- log("entering retrieveEagleData with: " .. requestName, 2)
  local http = require("socket.http")
  local ltn12 = require("ltn12")

  local path
  local path_suffix

  if HAN_MODEL == "200" then
    path_suffix = "/cgi-bin/post_manager"
  elseif HAN_MODEL == "100" then
    path_suffix = "/cgi-bin/cgi_manager"
  else
    log ("Unknown model in retrieveEagleData", 2)
  end

  if HAN_CLOUDID ~= "" then -- use ID for login
    path = "http://" .. HAN_CLOUDID .. ":" .. HAN_IN .. "@" .. HAN_IP .. path_suffix
  else
    path = "http://" .. HAN_IP .. path_suffix
  end

  local HAN_REQUEST = "<LocalCommand>\n<Name>" .. requestName .. "</Name>\n<MacId>" .. HAN_MACID .. "</MacId>\n</LocalCommand>\n"
  if HAN_MODEL == "200" then
    -- device_list gives the hardware address and the connection status
    if requestName == "device_list" then
      HAN_REQUEST = "<Command>\n<Name>device_list</Name>\n</Command>\n"
    -- device_query to get all variables at once
    elseif requestName == "200_allVariables" then
      HAN_REQUEST = HAN_REQUEST_DETAILS_PRE .. HAN_HWADDR .. HAN_REQUEST_DETAILS_POST
    else
      if requestName then
        log("bad request: " .. requestName, 2)
      else
	log("nil request to retrieveEagleData", 2)
      end
      return nil
    end
  end

  local obj = nil
  local pos = nil
  local err = nil

  -- log("post request is: " .. HAN_REQUEST, 3)
  -- log("path is: " .. path, 3)

  local response_body = { }
  local res, code, response_headers, status = http.request
  {
    url = path,
    method = "POST",
    headers =
    {
      ["Content-Type"] = "text/html",
      ["Content-Length"] = HAN_REQUEST:len()
    },
    source = ltn12.source.string(HAN_REQUEST),
    sink = ltn12.sink.table(response_body)
  }

  if res == nil then
    log("Error connecting to Rainforest Eagle server port, http request returned nil", 2)
    setVar("CommFailure", 1, HA_SERVICE)
    return nil
  end

  if code ~= 200 then
    log("Error connecting to Rainforest Eagle server port: " .. code, 2)
    setVar("CommFailure", 1, HA_SERVICE)
    return nil
  end

  if HAN_MODEL == "100" then
    local json = require("dkjson")
    obj, pos, err = json.decode(table.concat(response_body))
    if err then
      log("json decode error when decoding from Ealge 100: " .. err, 2)
      setVar("CommFailure", 1, HA_SERVICE)
      return nil
    end
    -- must have good data!
    setVar("CommFailure", 0, HA_SERVICE)
    return obj
  elseif HAN_MODEL == "200" then
    if table.concat(response_body) == nil then
      log("got nil response from Eagle 200 from POST request", 2)
      return nil
    end
    -- must have good data!
    setVar("CommFailure", 0, HA_SERVICE)
    return table.concat(response_body)
  end

  -- should never get here
  return nil
end

local function fixTimeStamp(timestamp)
  -- at least in my system the timestamp is not right - it is returning the current time minus the TZ
  -- maybe they made a mistake and started with the local time, then made the TZ offset?
  local nowTime = os.time()
  local utcdate   = os.date("!*t", nowTime)
  local localdate = os.date("*t", nowTime)
  localdate.isdst = false
  return(timestamp + os.difftime(os.time(utcdate), os.time(localdate)))
end

local function retrieveData(model)
  local dataTable = nil
  -- Model 100 uses a GET and returns JSON, 200 uses a POST and returns XML.  The call for the
  -- 100 returns a table with the JSON decoded and is modified as needed.
  -- The call for the 200 gets the XML into a table, then modifies the data to look like what
  -- the model 100 returns.
  if model == "100" then
    dataTable = retrieveEagleData("get_usage_data")

    if type(dataTable) ~= "table" then
      log("Unable to retrieve data from Eagle 100", 2)
    else
      local timestamp
      timestamp = fixTimeStamp(tonumber_u(dataTable.demand_timestamp))
      dataTable.timestamp = timestamp

      -- now pick up the link strength (only in the Eagle 100)
      local settingObj = retrieveEagleData("get_setting_data")
      if type(settingObj) == "table" then
        dataTable.network_link_strength = settingObj.network_link_strength
      end
    end

  elseif model == "200" then
    -- log("calling retrieve data 200", 2)
    local xmlstring = retrieveEagleData("200_allVariables")
    if xmlstring == nil then
      log("Unable to retrieve all variables from Eagle 200", 2)
    else -- got something from xml
      dataTable = {} -- blank table for the model 200 to fill in
   
      local tab = lom.parse(xmlstring)

      dataTable.meter_status = findValue("ConnectionStatus", tab)
      dataTable.timestamp = findValue("LastContact", tab)

      local pattern, demand
      pattern = [[(.*) *kW.*]]
      local demandString = findValueFor("zigbee:InstantaneousDemand", tab)
      if demandString then
        dataTable.demand = demandString:match(pattern)
      end

      local deliveredString = findValueFor("zigbee:CurrentSummationDelivered", tab)
      if deliveredString then
        dataTable.summation_delivered = deliveredString:match(pattern) * 1000
      end

      local receivedString = findValueFor("zigbee:CurrentSummationReceived", tab)
      if receivedString then
        dataTable.summation_received = receivedString:match(pattern) * 1000
      end

      dataTable.price = findValueFor("zigbee:Price", tab)

    end
  else
    log("unknown Eagle model in retrieveData")
  end

  return dataTable
end

local function storeData(dataTable)
  if type(dataTable) == "table" then
    if dataTable.meter_status ~= "Connected" then
      if dataTable.meter_status then
        log("Connection problem: " .. dataTable.meter_status, 2)
      else
        log("Connection problem, nil status ", 2)
      end
      setVar("CommFailure", 1, HA_SERVICE)
      return nil
    end
  else
    return nil
  end
  setVar("LinkStatus", dataTable.meter_status)

  setVar("CommFailure", 0, HA_SERVICE)
  if dataTable.timestamp then
    setVar("LastUpdate", dataTable.timestamp, HA_SERVICE)
    setVar("LastUpdateFormatted", os.date("%a %I:%M:%S %p", dataTable.timestamp))
  end

  local delivered, received, net
  delivered = tonumber(dataTable.summation_delivered)
  received = tonumber(dataTable.summation_received)

  if delivered and received then
    -- only proceed with caculations and variable setting if values are valid numbers
    --
    net = delivered - received

    -- get the base values so can do an incremental since the last reset
    -- if never reset this will have no effect
    -- (Note that if you later don't want this, you can set both variables to 0 and it will
    -- behave as if this was never reset.)
    local baseDelivered = getVar("KWHBaseDelivered")
    local baseReceived  = getVar("KWHBaseReceived")

    setVar("KWHDelivered", formatkWh(delivered))
    setVar("KWHReceived",  formatkWh(received))
    setVar("KWHNet",       formatkWh(net))

    if (HAN_MeteringType == "0") then
      setVar("KWH", formatkWh(delivered - baseDelivered), ENERGY_SERVICE)
    elseif (HAN_MeteringType == "1") then
      setVar("KWH", formatkWh(received - baseReceived), ENERGY_SERVICE)
    else
      setVar("KWH", formatkWh(net - (baseDelivered - baseReceived)), ENERGY_SERVICE)
      -- for 2 way meters, good to know the net incoming due to the non bypassable charges which are
      -- based on delivered power only and not offset by generation
      setVar("KWHDeliveredPerPeriod", delivered - baseDelivered)
    end

    setVar("KWHReading", tostring(dataTable.timestamp), ENERGY_SERVICE)
 
  end

  -- checks to see that it got a number back, sometimes get 'nan' on my meter
  if HAN_MODEL == "100" then
    if dataTable.demand ~= "nan" and tonumber(dataTable.demand) then
      local demand = tonumber(dataTable.demand) * 1000
      setVar("Watts", demand, ENERGY_SERVICE)
      if dataTable.demand then
        log("Issue with demand: " .. dataTable.demand, 2)
      else
        log("Issue with demand - has nil value", 2)
      end
    end
  end
  setVar("Price", dataTable.price, ENERGY_SERVICE)
  if tonumber(dataTable.price) and (tonumber(dataTable.price) ~= -1.00) then
    -- display in cents, not dollars
    setVar("DisplayPrice", string.format("%.1f", dataTable.price * 100))
  else
    -- apparently -1.00 means no data (at least for me), or if not a number
    -- don't dispaly anything
    setVar("DisplayPrice", '')
  end

  if HAN_MODEL == "100" then
    setVar("LinkStrength", tonumber_u(dataTable.network_link_strength))
  end

end

function refreshCache(timerInterval)
  -- Resubmit refresh job
  -- Make sure interval is smaller then 3600
  local pulse = getVar("Pulse", ENERGY_SERVICE)
  pulse = tonumber(pulse)

  if (pulse == nil or pulse > 3600) then
    pulse = HAN_DEFAULT_PULSE
  end

  -- Resubmit the poll job, unless the pulse==0 (disabled/manual)
  -- only resubmit if pulse is the same as with which the timer is started
  -- this takes care of cancelling older running timers
  if (pulse ~= 0 and (timerInterval == nil or timerInterval == "" or tostring(pulse) == tostring(timerInterval))) then
    -- luup.call_timer("refreshCache", 1, tostring(pulse), "", tostring(pulse))
    luup.call_delay("refreshCache", pulse, tostring(pulse))
  end
  -- End Resubmit refresh job

  -- get the data and then write it out to variables
  local dataTable = retrieveData(HAN_MODEL)
  storeData(dataTable)

end

function startPeak()
  -- start of peak period, record the off peak energy up to this point and get a reading
  -- for the next period
  local currentKWH = getVar("KWH", ENERGY_SERVICE)
  local currentOffPeak = getVar("KWHOffPeak")
  -- if not set yet, use currentKWH so we don't get a massive starting point
  local lastStartOffPeak = luup.variable_get(HAN_SERVICE, "KWHStartOffPeak", HAN_Device) or currentKWH
  local newOffPeak = currentKWH - lastStartOffPeak + currentOffPeak
  setVar("KWHOffPeak", newOffPeak)
  setVar("KWHStartPeak", currentKWH)
  setVar("PeakPeriod", "ON")
end

function endPeak()
  -- end of the peak period, record the peak energy up to this point and get a reading
  -- for the next period
  local currentKWH = getVar("KWH", ENERGY_SERVICE)
  local currentPeak = getVar("KWHPeak")
  -- if not set yet, use currentKWH so we don't get a massive starting point
  local lastStartPeak = luup.variable_get(HAN_SERVICE, "KWHStartPeak", HAN_Device) or currentKWH
  local newPeak = currentKWH - lastStartPeak + currentPeak
  setVar("KWHPeak", newPeak)
  setVar("KWHStartOffPeak", currentKWH)
  setVar("PeakPeriod", "OFF")
end

function resetKWH()
  -- reset the Base values to the current values
  local currentDelivered = getVar("KWHDelivered", HAN_Device)
  local baseDelivered    = getVar("KWHBaseDelivered", HAN_Device)
  local currentReceived  = getVar("KWHReceived",  HAN_Device)
  local netPeak          = getVar("KWHPeak",  HAN_Device)
  local netOffPeak       = getVar("KWHOffPeak",  HAN_Device)
  local periodType       = getVar("PeakPeriod",  HAN_Device)
  local currentKWH       = getVar("KWH", ENERGY_SERVICE)

  -- use the base delivered value from the prior period to determine how much was used during
  -- this period.  this is handy for knowing how much you will be charged for NBC (non bypassable
  -- charges)
  setVar("KWHDeliveredPrior", currentDelivered - baseDelivered)

  -- record the prior month's peak and off peak net energy consumption - this is used to determine
  -- the bill based on the rates - ignore the tiers for the moment
  if periodType == "ON" then -- we are in peak mode, so record the last bit of peak:
    local lastStartPeak = luup.variable_get(HAN_SERVICE, "KWHStartPeak", HAN_Device) or currentKWH
    netPeak = netPeak + currentKWH - lastStartPeak
  else -- must be off peak
    local lastStartOffPeak = luup.variable_get(HAN_SERVICE, "KWHStartOffPeak", HAN_Device) or currentKWH
    netOffPeak = netOffPeak + currentKWH - lastStartOffPeak
  end
  setVar("KWHNetPeak", netPeak)
  setVar("KWHNetOffPeak", netOffPeak)

  -- reset the tracking values for the next period:
  setVar("KWHStartPeak", 0)
  setVar("KWHStartOffPeak", 0)
  setVar("KWHPeak", 0)
  setVar("KWHOffPeak", 0)
  setVar("KWHBaseDelivered", currentDelivered)
  setVar("KWHBaseReceived",  currentReceived)
  setVar("KWH", 0, ENERGY_SERVICE)

  -- set up rates for the next period - the season may have changed
  local currentSeason = getVar("Season")
  local rates = getVar("Rates")
  local peakSummer, offPeakSummer, peakWinter, offPeakWinter = rates:match("%s*([0-9.]+)[,%s]+([0-9.]+)[,%s]+([0-9.]+)[,%s]+([0-9.]+)")
  if currentSeason == "Winter" then
    setVar("PeakRate", peakWinter)
    setVar("OffPeakRate", offPeakWinter)
    log("Set rates to " .. peakWinter .. " and " .. offPeakWinter, 6)
  else
    -- assume summer
    setVar("PeakRate", peakSummer)
    setVar("OffPeakRate", offPeakSummer)
    log("Set rates to " .. peakSummer .. " and " .. offPeakSummer, 6)
  end

  -- save a timestamp of when this was done - can then determine on the next pass
  -- how many days have elapsed in order to calculate the minimum monthly charge:
  setVar("PeriodStart", os.time())

  log("Reset base values for delivered and received", 7)
end

function setPulse(lul_settings)
  local pulse = tonumber(lul_settings.pulse)
  local currentPulse = getVar("Pulse", ENERGY_SERVICE)
  if pulse ~= currentPulse then
    -- don't start a new delay if the pulse is the same as the current one
    -- otherwise you'll have 2 or more of these running in a loop
    if (pulse == nil or pulse > 3600) then
      pulse = HAN_DEFAULT_PULSE
    end
    setVar("Pulse", tostring(pulse), ENERGY_SERVICE, lul_device)
    luup.call_delay("refreshCache", pulse, tostring(pulse))
  end
end

function setSeason(lul_settings)
  local season = lul_settings.season
  local currentSeason = getVar("Season")
  if season and season ~= currentSeason then
    setVar("Season", season, lul_device)
  end
end
