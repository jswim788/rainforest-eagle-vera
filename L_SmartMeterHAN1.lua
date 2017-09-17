-- Plugin for the Rainforest Eagle
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
--
local VERSION                   = 0.5
local HA_SERVICE                = "urn:micasaverde-com:serviceId:HaDevice1"
local ENERGY_SERVICE            = "urn:micasaverde-com:serviceId:EnergyMetering1"
local HAN_SERVICE               = "urn:smartmeter-han:serviceId:SmartMeterHAN1"
local HAN_DEFAULT_PULSE         = 300
local HAN_DEFAULT_METERINGTYPE  = "0"
local HAN_IP
local HAN_MACID
local HAN_IN
local HAN_CLOUDID

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
  return string.format("%.3f", (math.floor(value * 1000 + 0.5) / 1000))
end


function startup(han_device)
  log("Starting ZigBee HAN device", 3)
  HAN_Device       = han_device
  HAN_IP           = luup.devices[han_device].ip
  HAN_Pulse        = luup.variable_get(ENERGY_SERVICE, "Pulse",        HAN_Device)
  HAN_Watts        = luup.variable_get(ENERGY_SERVICE, "Watts",        HAN_Device)
  HAN_LinkStrength = luup.variable_get(HAN_SERVICE,    "LinkStrength", HAN_Device)
  HAN_LinkStatus   = luup.variable_get(HAN_SERVICE,    "LinkStatus",   HAN_Device)
  HAN_MACID        = luup.variable_get(HAN_SERVICE,    "DeviceMACID",  HAN_Device)
  HAN_IN           = luup.variable_get(HAN_SERVICE,    "DeviceIN",     HAN_Device)
  HAN_CLOUDID      = luup.variable_get(HAN_SERVICE,    "CloudId",      HAN_Device)
  HAN_MeteringType = luup.variable_get(HAN_SERVICE,    "MeteringType", HAN_Device)
  local wholehouse = luup.variable_get(ENERGY_SERVICE, "WholeHouse",   HAN_Device)
  local actualusage= luup.variable_get(ENERGY_SERVICE, "ActualUsage",  HAN_Device)

  -- Set up default values
  if ((wholehouse or "") == "") then
    luup.variable_set(ENERGY_SERVICE, "WholeHouse", "1", HAN_Device)
  end
  if ((actualusage or "") == "") then
    luup.variable_set(ENERGY_SERVICE, "ActualUsage", "1", HAN_Device)
  end
  if ((HAN_MeteringType or "") == "") then
    HAN_MeteringType = HAN_DEFAULT_METERINGTYPE
    luup.variable_set(HAN_SERVICE, "MeteringType", HAN_MeteringType, HAN_Device)
  end
  if ((HAN_Pulse or "") == "") then
    local interval = luup.variable_get(HAN_SERVICE, "Interval", HAN_Device)
    if ((interval or "") ~= "") then
      HAN_Pulse = interval
    else
      HAN_Pulse = HAN_DEFAULT_PULSE
    end
    luup.variable_set(ENERGY_SERVICE, "Pulse", HAN_Pulse, HAN_Device)
  end
  if ((HAN_Watts or "") == "") then
    luup.variable_set(ENERGY_SERVICE, "Watts", 0, HAN_Device)
  end
  if ((HAN_LinkStrength or "") == "") then
    luup.variable_set(HAN_SERVICE, "LinkStrength", 0, HAN_Device)
  end
  if ((HAN_LinkStatus or "") == "") then
    luup.variable_set(HAN_SERVICE, "LinkStatus", 0, HAN_Device)
  end
  -- the next 3 are to create these device variables if they don't exist so that
  -- the user can enter the values after the device is first created
  if ((HAN_MACID or "") == "") then
    luup.variable_set(HAN_SERVICE, "DeviceMACID", "", HAN_Device)
  end
  if ((HAN_IN or "") == "") then
    luup.variable_set(HAN_SERVICE, "DeviceIN", "", HAN_Device)
  end
  if ((HAN_CLOUDID or "") == "") then
    luup.variable_set(HAN_SERVICE, "CloudId", "", HAN_Device)
  end
  if ((HAN_MACID or "") == "") then
    return false, "Please enter the DeviceMACID of your HAN device", "SmartMeterHAN1"
  end
  if (HAN_IP:match("%d+%.%d+%.%d+%.%d+") == nil) then
    return false, "Please enter the IP address of of your HAN device", "SmartMeterHAN1"
  end

  refreshCache()
  luup.set_failure(0)
  return true, "OK", "SmartMeterHAN1"
end

local function retrieveEagleData(requestName)
  local http = require("socket.http")
  local ltn12 = require("ltn12")
  local json = require("dkjson")

  local path
  if HAN_CLOUDID ~= "" then -- use ID for login
    path = "http://" .. HAN_CLOUDID .. ":" .. HAN_IN .. "@" .. HAN_IP .. "/cgi-bin/cgi_manager"
  else
    path = "http://" .. HAN_IP .. "/cgi-bin/cgi_manager"
  end

  local HAN_REQUEST = "<LocalCommand>\n<Name>" .. requestName .. "</Name>\n<MacId>" .. HAN_MACID .. "</MacId>\n</LocalCommand>\n"

  local obj = nil
  local pos = nil
  local err = nil

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
    log("Error connecting to Rainforest Eagle server port, http request returned nil")
    luup.variable_set(HA_SERVICE, "CommFailure", 1, HAN_Device)
    return nil
  end

  if code ~= 200 then
    log("Error connecting to Rainforest Eagle server port: " .. code)
    luup.variable_set(HA_SERVICE, "CommFailure", 1, HAN_Device)
    return nil
  end

  obj, pos, err = json.decode(response_body[1])
  if err then
    log("json decode error" .. err)
    luup.variable_set(HA_SERVICE, "CommFailure", 1, HAN_Device)
    return nil
  end

  return obj
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

local function retrieveData()
  local usageObj = retrieveEagleData("get_usage_data")

  if usageObj then
    if usageObj.meter_status ~= "Connected" then
      log("Connection problem: " .. usageObj.meter_status)
      luup.variable_set(HA_SERVICE, "CommFailure", 1, HAN_Device)
      return nil
    end
  else
    return nil
  end
  luup.variable_set(HAN_SERVICE, "LinkStatus", usageObj.meter_status, HAN_Device)

  local timestamp, delivered, received, net

  timestamp = fixTimeStamp(tonumber_u(usageObj.demand_timestamp))

  luup.variable_set(HA_SERVICE, "CommFailure", 0, HAN_Device)
  luup.variable_set(HA_SERVICE, "LastUpdate", timestamp, HAN_Device)
  luup.variable_set(HAN_SERVICE, "LastUpdateFormatted", os.date("%a %I:%M:%S %p", timestamp), HAN_Device)

  delivered = tonumber(usageObj.summation_delivered)
  received = tonumber(usageObj.summation_received)
  net = delivered - received

  -- get the base values so can do an incremental since the last reset
  -- if never reset this will have no effect
  -- (Note that if you later don't want this, you can set both variables to 0 and it will
  -- behave as if this was never reset.)
  local baseDelivered = luup.variable_get(HAN_SERVICE, "KWHBaseDelivered", HAN_Device) or "0"
  local baseReceived  = luup.variable_get(HAN_SERVICE, "KWHBaseReceived",  HAN_Device) or "0"

  luup.variable_set(HAN_SERVICE, "KWHDelivered", delivered, HAN_Device)
  luup.variable_set(HAN_SERVICE, "KWHReceived",  received,  HAN_Device)
  luup.variable_set(HAN_SERVICE, "KWHNet",       net,       HAN_Device)

  if (HAN_MeteringType == "0") then
    luup.variable_set(ENERGY_SERVICE, "KWH", formatkWh(delivered - baseDelivered), HAN_Device)
  elseif (HAN_MeteringType == "1") then
    luup.variable_set(ENERGY_SERVICE, "KWH", formatkWh(received - baseReceived), HAN_Device)
  else
    luup.variable_set(ENERGY_SERVICE, "KWH", formatkWh(net - (baseDelivered - baseReceived)), HAN_Device)
	-- for 2 way meters, good to know the net incoming due to the non bypassable charges which are
	-- based on delivered power only and not offset by generation
    luup.variable_set(HAN_SERVICE, "KWHDeliveredPerPeriod", delivered - baseDelivered, HAN_Device)
  end
  luup.variable_set(ENERGY_SERVICE, "KWHReading", tostring(timestamp), HAN_Device)
 
  -- checks to see that it got a number back, sometimes get 'nan' on my meter
  if usageObj.demand ~= "nan" and tonumber(usageObj.demand) then
    local demand = tonumber(usageObj.demand) * 1000
    luup.variable_set(ENERGY_SERVICE, "Watts", demand, HAN_Device)
  else
    log("Issue with demand: " .. usageObj.demand)
  end
  luup.variable_set(ENERGY_SERVICE, "Price", usageObj.price, HAN_Device)

  local settingObj = retrieveEagleData("get_setting_data")
  luup.variable_set(HAN_SERVICE, "LinkStrength", tonumber_u(settingObj.network_link_strength), HAN_Device)

end

function refreshCache(timerInterval)
  -- Resubmit refresh job
  -- Make sure interval is smaller then 3600
  local pulse = luup.variable_get(ENERGY_SERVICE, "Pulse", HAN_Device)
  pulse = tonumber(pulse)

  if (pulse == nil or pulse > 3600) then
    pulse = HAN_DEFAULT_PULSE
  end

  -- Resubmit the poll job, unless the pulse==0 (disabled/manual)
  -- only resubmit if pulse is the same as with which the timer is started
  -- this takes care of cancelling older running timers
  if (pulse ~= 0 and (timerInterval == nil or tostring(pulse) == tostring(timerInterval))) then
    -- luup.call_timer("refreshCache", 1, tostring(pulse), "", tostring(pulse))
    luup.call_delay("refreshCache", pulse, tostring(pulse))
  end
  -- End Resubmit refresh job

  retrieveData()
end

function startPeak()
  -- start of peak period, record the off peak energy up to this point and get a reading
  -- for the next period
  local currentKWH = luup.variable_get(ENERGY_SERVICE, "KWH", HAN_Device) or "0"
  local currentOffPeak = luup.variable_get(HAN_SERVICE, "KWHOffPeak", HAN_Device) or "0"
  -- if not set yet, use currentKWH so we don't get a massive starting point
  local lastStartOffPeak = luup.variable_get(HAN_SERVICE, "KWHStartOffPeak", HAN_Device) or currentKWH
  local newOffPeak = currentKWH - lastStartOffPeak + currentOffPeak
  luup.variable_set(HAN_SERVICE, "KWHOffPeak", newOffPeak, HAN_Device)
  luup.variable_set(HAN_SERVICE, "KWHStartPeak", currentKWH, HAN_Device)
  luup.variable_set(HAN_SERVICE, "PeakPeriod", "ON", HAN_Device)
end

function endPeak()
  -- end of the peak period, record the peak energy up to this point and get a reading
  -- for the next period
  local currentKWH = luup.variable_get(ENERGY_SERVICE, "KWH", HAN_Device) or "0"
  local currentPeak = luup.variable_get(HAN_SERVICE, "KWHPeak", HAN_Device) or "0"
  -- if not set yet, use currentKWH so we don't get a massive starting point
  local lastStartPeak = luup.variable_get(HAN_SERVICE, "KWHStartPeak", HAN_Device) or currentKWH
  local newPeak = currentKWH - lastStartPeak + currentPeak
  luup.variable_set(HAN_SERVICE, "KWHPeak", newPeak, HAN_Device)
  luup.variable_set(HAN_SERVICE, "KWHStartOffPeak", currentKWH, HAN_Device)
  luup.variable_set(HAN_SERVICE, "PeakPeriod", "OFF", HAN_Device)
end

function resetKWH()
  -- reset the Base values to the current values
  local currentDelivered = luup.variable_get(HAN_SERVICE, "KWHDelivered", HAN_Device) or "0"
  local baseDelivered    = luup.variable_get(HAN_SERVICE, "KWHBaseDelivered", HAN_Device) or "0"
  local currentReceived  = luup.variable_get(HAN_SERVICE, "KWHReceived",  HAN_Device) or "0"
  local netPeak          = luup.variable_get(HAN_SERVICE, "KWHPeak",  HAN_Device) or "0"
  local netOffPeak       = luup.variable_get(HAN_SERVICE, "KWHOffPeak",  HAN_Device) or "0"
  -- use the base delivered value from the prior period to determine how much was used during
  -- this period.  this is handy for knowing how much you will be charged for NBC (non bypassable
  -- charges)
  luup.variable_set(HAN_SERVICE, "KWHDeliveredPrior", currentDelivered - baseDelivered, HAN_Device)
  -- record the prior month's peak and off peak net energy consumption - this is used to determine
  -- the bill based on the rates - ignore the tiers for the moment
  luup.variable_set(HAN_SERVICE, "KWHNetPeak", netPeak, HAN_Device)
  luup.variable_set(HAN_SERVICE, "KWHNetOffPeak", netOffPeak, HAN_Device)
  luup.variable_set(HAN_SERVICE, "KWHBaseDelivered", currentDelivered, HAN_Device)
  luup.variable_set(HAN_SERVICE, "KWHBaseReceived",  currentReceived,  HAN_Device)
  luup.variable_set(ENERGY_SERVICE, "KWH", 0, HAN_Device)
  luup.log("SmartHAN1: Reset base values for delivered and received")
end

function setPulse()
  local pulse = tonumber(lul_settings.pulse)
  currentPulse = luup.variable_get(ENERGY_SERVICE, "Pulse", HAN_Device)
  if pulse ~= currentPulse then
    -- don't start a new delay if the pulse is the same as the current one
    -- otherwise you'll have 2 or more of these running in a loop
    if (pulse == nil or pulse > 3600) then
      pulse = HAN_DEFAULT_PULSE
    end
    luup.variable_set(ENERGY_SERVICE, "Pulse", tostring(pulse), lul_device)
    luup.call_delay("refreshCache", pulse, tostring(pulse))
  end
end
