-- scenariolab wrk workload. Identical to the shared harness default
-- (harness/adapters/loadgen/wrk/default.lua): scenariolab endpoints are
-- unauthenticated single-request scenarios. It lives here so the lab owns its
-- workload; a project that needs auth provides its own copy.
-- wrk is request-only: journeys and mixes are rejected before any traffic.
local workload_kind = os.getenv("PERF_WORKLOAD_KIND") or "request"
if workload_kind == "journey" or workload_kind == "mix" then
  error("capability generator.wrk.journey is unsupported; rejected before traffic")
end
local method = os.getenv("PERF_METHOD") or "GET"
local path = os.getenv("PERF_PATH") or "/"
local body = os.getenv("PERF_BODY") or ""
local extra_headers = os.getenv("PERF_HEADERS") or ""

wrk.method = method
wrk.path = path
wrk.headers["Accept"] = "application/json"

if method == "POST" or method == "PUT" or method == "PATCH" then
  wrk.headers["Content-Type"] = "application/json"
  wrk.body = body
end

-- Minimal parse of a flat {"Name":"Value",...} object into headers.
if extra_headers ~= "" then
  for name, value in string.gmatch(extra_headers, '"([^"]+)"%s*:%s*"([^"]*)"') do
    wrk.headers[name] = value
  end
end

-- perflab-baggage-v1 (D-P1-8): the request's run and phase as W3C baggage, so
-- the application stamps them on its spans, logs and request metrics. A value
-- the application would reject is not sent.
local baggage = {}
local run_id = os.getenv("PERF_RUN_ID") or ""
if #run_id > 0 and #run_id <= 128 and run_id:match("^[%w%._:%-]+$") then
  table.insert(baggage, "perf.run.id=" .. run_id)
end
local phase = os.getenv("PERF_PHASE") or ""
if phase == "warmup" or phase == "measure" or phase == "diagnostic" then
  table.insert(baggage, "perf.phase=" .. phase)
end
if #baggage > 0 then
  wrk.headers["baggage"] = table.concat(baggage, ",")
end
