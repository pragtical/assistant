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

---Return compact web activity.
---@param call table|nil
---@param status string|nil
---@return string
local function compact_web_activity(call, status)
  local args = call and call.arguments or {}
  local target = tostring(args.url or args.query or "")
  return "**Searching web**: " .. (target ~= "" and target or "web") .. Tool.status_suffix(status)
end

---Return whether a web result represents a successful request.
---@param _ table|nil
---@param result_message table|nil
---@return boolean
local function web_result_is_successful(_, result_message)
  local content = tostring(result_message and (result_message.content or result_message.output) or "")
  if content == "" then return false end
  if content:find("^tool error:", 1, false) then return false end
  if content:find("user denied web request", 1, true) then return false end
  return true
end

---Return a short historical web result summary.
---@param message table|nil
---@param _ table|nil
---@param included_ids table|nil
---@param result_texts table|nil
---@return table[]
local function compact_web_history(message, _, included_ids, result_texts)
  local rows = {
    "# Prior Web Lookups",
    "",
    "Historical web tool calls were omitted from provider history. Use these summaries only as background; fetch again only if the user asks for current external information or the previous result is insufficient.",
    ""
  }
  local inserted = false
  for _, provider_call in ipairs(type(message) == "table" and message.tool_calls or {}) do
    local id = tostring(provider_call.id or "")
    if id ~= "" and included_ids and included_ids[id] then
      local fn = provider_call["function"] or {}
      local args = {}
      if type(fn.arguments) == "string" then
        pcall(function() args = json.decode(fn.arguments) or {} end)
      elseif type(fn.arguments) == "table" then
        args = fn.arguments
      end
      local target = tostring(args.url or args.query or "web")
      local result = tostring(result_texts and result_texts[id] or "")
      table.insert(rows, "- `" .. tostring(fn.name or provider_call.name or "web") .. "`: " .. target)
      local status = result:match("status:%s*([^\n]+)")
      local url = result:match("url:%s*([^\n]+)") or result:match("Fetched URL:%s*([^\n]+)")
      if status then table.insert(rows, "  - status: " .. status) end
      if url and url ~= target then table.insert(rows, "  - fetched: " .. url) end
      local sample = Tool.first_lines(result:gsub("^Tool `%w+` result:%s*", ""), 5)
      if sample ~= "" then
        table.insert(rows, "")
        table.insert(rows, Tool.fenced(sample, "text"))
        table.insert(rows, "")
      end
      inserted = true
    end
  end
  if not inserted then return {} end
  return {
    {
      role = "assistant",
      content = table.concat(rows, "\n")
    }
  }
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

---Decode a small subset of HTML entities commonly found in search pages.
---@param text string
---@return string
local function html_unescape(text)
  local named = {
    amp = "&",
    apos = "'",
    gt = ">",
    lt = "<",
    nbsp = " ",
    quot = '"'
  }
  return tostring(text or "")
    :gsub("&#x([%da-fA-F]+);", function(hex)
      local value = tonumber(hex, 16)
      return value and value < 256 and string.char(value) or ""
    end)
    :gsub("&#(%d+);", function(decimal)
      local value = tonumber(decimal)
      return value and value < 256 and string.char(value) or ""
    end)
    :gsub("&([%a]+);", function(name)
      return named[name] or "&" .. name .. ";"
    end)
end

---Remove HTML tags and normalize whitespace.
---@param text string
---@return string
local function html_text(text)
  text = tostring(text or "")
    :gsub("<script.-</script>", " ")
    :gsub("<style.-</style>", " ")
    :gsub("<[^>]+>", " ")
  text = html_unescape(text):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  return text
end

---Decode percent-escaped URL text.
---@param text string
---@return string
local function urldecode(text)
  return tostring(text or ""):gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
end

---Return the value of a query parameter from a URL.
---@param url string
---@param name string
---@return string|nil
local function url_param(url, name)
  local escaped = name:gsub("([^%w])", "%%%1")
  local value = tostring(url or ""):match("[?&]" .. escaped .. "=([^&#]+)")
  if not value then return nil end
  return urldecode((value:gsub("+", " ")))
end

---Extract a useful destination URL from a search-result href.
---@param href string
---@return string|nil
local function search_result_url(href)
  href = html_unescape(href or "")
  if href == "" or href:match("^#") or href:match("^javascript:") or href:match("^mailto:") then
    return nil
  end
  local uddg = url_param(href, "uddg")
  if uddg then return uddg end
  local google = url_param(href, "q")
  if google and google:match("^https?://") then return google end
  if href:match("^//") then return "https:" .. href end
  if href:match("^https?://") then return href end
end

---Extract readable results from a generic HTML search page.
---@param body string
---@param limit number?
---@return string|nil output
local function extract_html_search_results(body, limit)
  local rows = {}
  local seen = {}
  local max = tonumber(limit) or 10
  for attrs, label in tostring(body or ""):gmatch("<a%s+([^>]-href%s*=%s*['\"][^'\"]+['\"][^>]*)>(.-)</a>") do
    local href = attrs:match("href%s*=%s*['\"]([^'\"]+)['\"]")
    local url = search_result_url(href)
    local title = html_text(label)
    if url and title ~= "" and not seen[url] then
      seen[url] = true
      table.insert(rows, title .. "\n" .. url)
      if #rows >= max then break end
    end
    if #rows % 25 == 0 then context.yield_ui() end
  end
  if #rows == 0 then return nil end
  return table.concat(rows, "\n\n")
end

---Run a search through the configured search page or JSON endpoint.
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
    output = extract_html_search_results(body, limit)
      or table.concat({
        "No search results could be extracted from the HTML page. Raw HTML follows.",
        "Fetched URL: " .. tostring(result.url or request_url),
        "Response bytes: " .. tostring(#body),
        "",
        body
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
    result_is_successful = web_result_is_successful,
    compact_history = compact_web_history,
    activity_label = function() return "Searching web" end,
    compact_activity_markdown = compact_web_activity,
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
    result_is_successful = web_result_is_successful,
    compact_history = compact_web_history,
    activity_label = function() return "Searching web" end,
    compact_activity_markdown = compact_web_activity,
    description = "Search the web using the configured assistant web search page or JSON endpoint.",
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
    result_is_successful = web_result_is_successful,
    compact_history = compact_web_history,
    activity_label = function() return "Searching web" end,
    compact_activity_markdown = compact_web_activity,
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
