-- Shared DEFAULT wrk workload: one stateless request, driven entirely by the
-- PERF_* env contract. Counterpart of the shared k6 default.js, and the fallback
-- a lab gets when it ships no <lab>/loadgen/wrk.lua of its own. A project that
-- needs auth or per-request data provides its own per-lab wrk.lua instead of
-- editing this file -- see harness/core/lib/common.sh:loadgen_script.
local method = os.getenv("PERF_METHOD") or "GET"
local path = os.getenv("PERF_PATH") or "/"
local body = os.getenv("PERF_BODY") or ""
local run_id = os.getenv("PERF_RUN_ID") or "wrk-manual"
-- Optional extra headers as a flat JSON object, e.g. a pre-minted bearer token:
-- PERF_HEADERS='{"Authorization":"Bearer ..."}'. Inert when unset.
local extra_headers = os.getenv("PERF_HEADERS") or ""

wrk.method = method
wrk.path = path
wrk.headers["Accept"] = "application/json"
wrk.headers["X-Perf-Run-Id"] = run_id

if method == "POST" or method == "PUT" or method == "PATCH" then
  wrk.headers["Content-Type"] = "application/json"
  wrk.body = body
end

-- Minimal parse of a flat {"Name":"Value",...} object into headers. Values must
-- not contain embedded double quotes; sufficient for a bearer token / API key.
if extra_headers ~= "" then
  for name, value in string.gmatch(extra_headers, '"([^"]+)"%s*:%s*"([^"]*)"') do
    wrk.headers[name] = value
  end
end
