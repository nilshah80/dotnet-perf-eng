local method = os.getenv("PERF_METHOD") or "GET"
local path = os.getenv("PERF_PATH") or "/"
local body = os.getenv("PERF_BODY") or ""
local run_id = os.getenv("PERF_RUN_ID") or "wrk-manual"

wrk.method = method
wrk.path = path
wrk.headers["Accept"] = "application/json"
wrk.headers["X-Perf-Run-Id"] = run_id

if method == "POST" then
  wrk.headers["Content-Type"] = "application/json"
  wrk.body = body
end

