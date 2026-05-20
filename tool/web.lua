local config = require "core.config"
local json = require "core.json"
local context = require "plugins.assistant.tool_context"
local Tool = require "plugins.assistant.tool"

---HTTP and web-search tool implementations.
---@class assistant.tool.web
local webtools = {}

---Compact compact.
---@param label string
---@return fun(_: assistant.Tool, result: string): string
local function compact(label)
  return function(_, result)
    return context.compact_provider_text_result(result, label)
  end
end

---Handle web fetch raw.
---@param url string
---@param method string?
---@param headers table?
---@param body string?
---@param timeout_ms number?
---@return boolean ok
---@return table|string result
local function web_fetch_raw(url, method, headers, body, timeout_ms)
  local parsed, parse_err = context.parse_url(url)
  if not parsed then return false, parse_err end
  method = tostring(context.optional_text(method) or "GET"):upper()
  local allowed = {
    GET = true,
    POST = true,
    PUT = true,
    PATCH = true,
    DELETE = true,
    HEAD = true,
    OPTIONS = true
  }
  if not allowed[method] then return false, "unsupported HTTP method: " .. method end
  if not context.host_allowed(parsed.host) and not context.confirm("web_request", url, method) then
    return false, "user denied web request: " .. tostring(url)
  end
  local ok, err, response, info = context.http_request(method, url, headers, body, timeout_ms)
  if not ok then return false, err or "web request failed" end
  local status = tonumber(info and info.status)
  if status and (status < 200 or status >= 300) then
    return false, string.format(
      "HTTP %d\nurl: %s\nheaders:\n%s\nbody:\n%s",
      status,
      tostring(info and info.url or url),
      context.format_headers(info and info.headers),
      context.limited(response or "")
    )
  end
  return true, {
    status = status or "",
    url = info and info.url or url,
    headers = info and info.headers or {},
    body = tostring(response or "")
  }
end

---Fetch a URL and format the response for the model.
---@param url string
---@param method string?
---@param headers table?
---@param body string?
---@param timeout_ms number?
---@return boolean ok
---@return string result
function webtools.web_fetch(url, method, headers, body, timeout_ms)
  local ok, result = web_fetch_raw(url, method, headers, body, timeout_ms)
  if not ok then return false, result end
  return true, string.format(
    "status: %s\nurl: %s\nheaders:\n%s\nbody:\n%s",
    tostring(result.status),
    tostring(result.url),
    context.format_headers(result.headers),
    context.limited(result.body)
  )
end

---Run a search through the configured JSON search endpoint.
---@param query string
---@param limit number?
---@param timeout_ms number?
---@return boolean ok
---@return string result
function webtools.web_search(query, limit, timeout_ms)
  query = context.optional_text(query)
  if not query then return false, "missing query" end
  local conf = config.plugins.assistant or {}
  local url = context.optional_text(conf.web_search_url)
  if not url then return false, "web search provider not configured" end
  local param = context.optional_text(conf.web_search_query_param) or "q"
  local sep = url:find("?", 1, true) and "&" or "?"
  local request_url = url .. sep .. context.urlencode(param) .. "=" .. context.urlencode(query)
  local ok, result = web_fetch_raw(request_url, "GET", nil, nil, timeout_ms)
  if not ok then return false, result end
  local body = result.body or ""
  local decoded = json.decode(body)
  local extracted = type(decoded) == "table" and context.extract_path(decoded, conf.web_search_results_path) or nil
  local output
  if type(extracted) == "table" then
    local rows = {}
    local max = tonumber(limit) or 10
    for i, item in ipairs(extracted) do
      if i > max then break end
      if type(item) == "table" then
        table.insert(rows, table.concat({
          tostring(item.title or item.name or item.url or ("result " .. i)),
          tostring(item.url or item.link or ""),
          tostring(item.snippet or item.description or item.text or "")
        }, "\n"))
      else
        table.insert(rows, tostring(item))
      end
    end
    output = table.concat(rows, "\n\n")
  elseif context.looks_like_html(body) then
    output = table.concat({
      "Web search endpoint returned an HTML page, not structured search results.",
      "Configure `plugins.assistant.web_search_url` to a JSON search endpoint and set `plugins.assistant.web_search_results_path`, or fetch a specific URL with `web_fetch`.",
      "Fetched URL: " .. tostring(result.url or request_url),
      "Response bytes: " .. tostring(#body)
    }, "\n")
  else
    output = body
  end
  output = context.optional_text(output) or "No results."
  return true, context.limited(output)
end

---Fetch a URL and return matching body lines.
---@param url string
---@param pattern string
---@param plain boolean|string?
---@param timeout_ms number?
---@return boolean ok
---@return string result
function webtools.web_find(url, pattern, plain, timeout_ms)
  pattern = context.optional_text(pattern)
  if not pattern then return false, "missing pattern" end
  local ok, result = web_fetch_raw(url, "GET", nil, nil, timeout_ms)
  if not ok then return false, result end
  local out = {}
  local use_plain = plain == nil or plain == true or plain == "true"
  local line_no = 1
  for line in ((result.body or "") .. "\n"):gmatch("(.-)\n") do
    local matched = use_plain and line:find(pattern, 1, true) or line:find(pattern)
    if matched then
      table.insert(out, string.format("%d:%s", line_no, line))
      if #out >= 50 then break end
    end
    line_no = line_no + 1
    if line_no % 200 == 0 then context.yield_ui() end
  end
  if #out == 0 then return true, "No matches." end
  return true, context.limited(table.concat(out, "\n"))
end

webtools.tools = {
  Tool:new({
    name = "web_fetch",
    callback = webtools.web_fetch,
    compact_result = compact("web fetch"),
    description = "Fetch an HTTP or HTTPS URL with Pragtical core.http after user confirmation.",
    read_only = true,
    requires_approval = context.web_request_requires_approval,
    params = {
      { name = "url", description = "HTTP or HTTPS URL to fetch.", type = "string" },
      { name = "method", description = "HTTP method. Defaults to GET.", type = "string", enum = { "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS" }, required = false },
      { name = "headers", description = "Optional request headers as an object.", type = "object", required = false },
      { name = "body", description = "Optional request body.", type = "string", required = false },
      { name = "timeout_ms", description = "Timeout in milliseconds.", type = "number", required = false }
    }
  }),
  Tool:new({
    name = "web_search",
    callback = webtools.web_search,
    compact_result = compact("web search"),
    description = "Search the web using the configured assistant web search endpoint.",
    read_only = true,
    requires_approval = context.web_request_requires_approval,
    params = {
      { name = "query", description = "Search query.", type = "string" },
      { name = "limit", description = "Maximum number of formatted results.", type = "number", required = false },
      { name = "timeout_ms", description = "Timeout in milliseconds.", type = "number", required = false }
    }
  }),
  Tool:new({
    name = "web_find",
    callback = webtools.web_find,
    compact_result = compact("web find"),
    description = "Fetch a URL and return lines matching a pattern.",
    read_only = true,
    requires_approval = context.web_request_requires_approval,
    params = {
      { name = "url", description = "HTTP or HTTPS URL to fetch.", type = "string" },
      { name = "pattern", description = "Text or Lua pattern to find in the fetched body.", type = "string" },
      { name = "plain", description = "Use plain text matching when true. Defaults to true.", type = "boolean", required = false },
      { name = "timeout_ms", description = "Timeout in milliseconds.", type = "number", required = false }
    }
  })
}

return webtools
