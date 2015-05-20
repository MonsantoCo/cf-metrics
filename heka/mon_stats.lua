--[[
Converts stat values extracted from statmetric messages to circular buffer data and periodically emits
messages containing this data to be graphed by a DashboardOutput. Also creates Anomaly Anotations and injects 
it back to the data stream if an anomalyis detected.

Note that
this filter expects the stats data to be available in the message fields, so
the StatAccumInput *must* be configured with `emit_in_fields` set to true for
this filter to work correctly.

Config:

- title (string, optional, default "Stats"):
    Title for the graph output generated by this filter.

- rows (uint, optional, default 300):
    The number of rows to store in our circular buffer. Each row represents
    one time interval.

- sec_per_row (uint, optional, default 1):
    The number of seconds in each circular buffer time interval.

- stats (string):
    Space separated list of stat names. Each specified stat will be expected
    to be found in the fields of the received statmetric messages, and will be
    extracted and inserted into its own column in the accumulated circular
    buffer.

- stat_labels (string):
    Space separated list of header label names to use for the extracted stats.
    Must be in the same order as the specified stats. Any label longer than 15
    characters will be truncated.

- mon_anomaly_config (string, optional):
    Anomaly detection configuration.
    <anomaly_type> : <col>
    anomaly_type are as follows
    'spike': random spikes in data stream - uses ROC algorithm
    'slowchange': slower changes in data in any directions - uses mww
    'creepingchange': really slow changes in data - uses mww_nonparametric
    'breakdown' : detects a failure in the data stream ie alerts if data stopped comming in
    'breakout' : dectects breakouts in data (TODO: port twitter' breakout algo)
  

- preservation_version (uint, optional, default 0):
    If `preserve_data = true` is set in the SandboxFilter configuration, then
    this value should be incremented every time any edits are made to your
    `rows`, `sec_per_row`, `stats`, or `stat_labels` values, or else Heka
    will fail to start because the preserved data will no longer match the
    filter's data structure.

- stat_aggregation (string, optional, default "sum"):
    Controls how the column data is aggregated when combining multiple circular buffers.
        "sum"  - The total is computed for the time/column (default).
        "min"  - The smallest value is retained for the time/column.
        "max"  - The largest value is retained for the time/column.
        "none" - No aggregation will be performed the column.

- stat_unit (string, optional, default "count"):
    The unit of measure (maximum 7 characters). Alpha numeric, '/', and '*' 
    characters are allowed everything else will be converted to underscores. 
    i.e. KiB, Hz, m/s (default: count).

*Example Heka Configuration*

.. code-block:: ini

    [stat-graph]
    type = "SandboxFilter"
    filename = "lua_filters/stat_graph.lua"
    ticker_interval = 10
    preserve_data = true
    message_matcher = "Type == 'heka.statmetric'"

      [stat-graph.config]
      title = "Hits and Misses"
      rows = 1440
      stat_aggregation = "none"
      stat_unit = "count"
      sec_per_row = 10
      stats = "stats.counters.hits.count stats.counters.misses.count"
      stat_labels = "hits misses"
      mon_anomaly_config = "spikes:1 slowchanges:1"
      anomaly_emergency = 1
      preservation_version = 0
--]]

_PRESERVATION_VERSION = read_config("preservation_version") or 0

require("circular_buffer")
require("string")
require("mon_anomaly_w")
local lpeg = require("lpeg")

local alert = require "alert"
local annotation = require "annotation"
local anomaly = require "anomaly"

local title = read_config("title") or "Stats"
local rows = read_config("rows") or 300
local sec_per_row = read_config("sec_per_row") or 1
local stats_config = read_config("stats") or error("stats configuration must be specified")
local stat_labels_config = read_config("stat_labels") or error("stat_labels configuration must be specified")
local stat_aggregation   = read_config("stat_aggregation") or "sum"
local stat_unit          = read_config("stat_unit") or "count"

local anomaly_config = read_config("anomaly_config")
local mon_anomaly_config = read_config("mon_anomaly_config")
local anom_str = ''
local anomaly_cfg = ''

--[[ ****to be deleted***
local mon_win = read_config("anomaly_window") or 10
local mon_hwin = read_config("anomaly_hist_window") or 0
--]]
local throttle_to = read_config("throttle_threshold") or 10

--[[ temp code
local anom_str_d = read_config("anomaly_config")
--local anomaly_config = anomaly.parse_config(anom_str_d)
alert.send(0,anom_str_d)
--]]

-- ** TODO - Fix Alert Module
--alert.set_throttle = throttle_to * 1e9

if not mon_anomaly_config and not anomaly_config then
   anomaly_cfg = nil
else   
   if mon_anomaly_config and not anomaly_config then 
      -- if only monsanto anomaly config is set
      anom_str = trnslt_anomaly_config(title,mon_anomaly_config)
   elseif (not mon_anomaly_config and anomaly_config) or (mon_anomaly_config and anomaly_config) then
     -- either monsanto config is not set or both are set, take heka config 
      anom_str = anomaly_config
   end   
   anomaly_cfg = anomaly.parse_config(anom_str)
end
 
annotation.set_prune(title, rows * sec_per_row * 1e9)

local stats = {}
local i = 1

for stat in string.gmatch(stats_config, "%S+") do
    stats[i] = stat
    i = i + 1
end
stats_config = nil

local stat_labels = {}
i = 1
for stat_label in string.gmatch(stat_labels_config, "%S+") do
    stat_labels[i] = stat_label
    i = i + 1
end
stat_labels_config = nil

if #stats ~= #stat_labels then error("stats and stat_labels configuration must have the same number of items") end

cbuf = circular_buffer.new(rows, #stats, sec_per_row)
local field_names = {}
for i, stat_name in pairs(stats) do
    cbuf:set_header(i, stat_labels[i], stat_unit, stat_aggregation)
    field_names[i] = string.format("Fields[%s]", stat_name)
end

function process_message()
    local ts = read_message("Fields[timestamp]")
    if type(ts) ~= "number" then return -1 end
    ts = ts * 1e9

    for i, stat_name in pairs(stats) do
        local stat_value = read_message(field_names[i])
        if type(stat_value) == "number" then
           cbuf:add(ts, i, stat_value)
        end
    end
    return 0
end

function timer_event(ns)
    if anomaly_cfg then
        if not alert.throttled(ns) then
            local msg, annos = anomaly.detect(ns, title, cbuf, anomaly_cfg)
            if msg then
                annotation.concat(title, annos)
                alert.send(ns, msg)
            end
        end
        inject_payload("cbuf", title, annotation.prune(title, ns), cbuf)
    else
        inject_payload("cbuf", title, cbuf)
    end
end
