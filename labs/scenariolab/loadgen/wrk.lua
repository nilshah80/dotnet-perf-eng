-- scenariolab wrk workload. Identical to the shared harness default
-- (harness/adapters/loadgen/wrk/default.lua): scenariolab endpoints are
-- unauthenticated single-request scenarios. It lives here so the lab owns its
-- workload; a project that needs auth provides its own copy.
local method = os.getenv("PERF_METHOD") or "GET"
local path = os.getenv("PERF_PATH") or "/"
local body = os.getenv("PERF_BODY") or ""
local run_id = os.getenv("PERF_RUN_ID") or "wrk-manual"
local extra_headers = os.getenv("PERF_HEADERS") or ""

wrk.method = method
wrk.path = path
wrk.headers["Accept"] = "application/json"
wrk.headers["X-Perf-Run-Id"] = run_id

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
