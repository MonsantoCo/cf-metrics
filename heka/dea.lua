require "string"

local total = 0 
local count = 0 
local stats = {ip = "0.0.0.0", ratio = "1.0"}
local deas = {}

function process_message ()
    local ratio = read_message("Fields[Value]")
    if ratio == nil then
        ratio = "_unknonwn_"
    end
    local ip =  read_message("Fields[IP]")
    if ip == nil then 
        ip = "_unknown_"
    end
    if ratio < "0.15" then
       count = count + 1
       stats.ip = ip
       stats.ratio = ratio
       deas[count] = stats    
    end
    total = total + 1
    return 0
end

function timer_event(ns)
    if count > 0 then
       add_to_payload("!!!!CF NP DEA Memory Alert!!!!\n")
       add_to_payload("dea ip\t\t\t\t\t\t\tratio\n")
       for k, v in pairs(deas) do
    	  add_to_payload(string.format("%s\t%s\n", v.ip, v.ratio))
       end
       add_to_payload(string.format("%d messages in the last minute for DEA's with less than 15 percent memory; %d had less than 20 percent", count, total))
       inject_payload()
    end   
       count=0
       total=0
       for k,v in pairs(deas) do deas[k]=nil end
end

