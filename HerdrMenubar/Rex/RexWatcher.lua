local TERMINAL = "com.superlogical.terminal"
local TEXT_MAX = 300

local function out(t)
  local s, err = rex.json.encode(t)
  if not s then s = rex.json.encode({ t = "encode_error", err = tostring(err) }) end
  print(s); io.stdout:flush()
end

local function clip(s)
  if type(s) ~= "string" or #s <= TEXT_MAX then return s end
  local cut = TEXT_MAX
  while cut > 0 and s:byte(cut + 1) and s:byte(cut + 1) >= 0x80 and s:byte(cut + 1) < 0xC0 do cut = cut - 1 end
  return s:sub(1, cut)
end

local function gone(err)
  local e = tostring(err)
  return e:find("code=not_found", 1, true) or e:find("code=session_not_found", 1, true)
end

-- Authoritative re-read of one block. `via` carries what the triggering event said.
local function block_status(s, b, via)
  local st, err = rex.block.call(TERMINAL, "program_status", { session_id = s, block_id = b })
  if not st then
    if gone(err) then out{ t = "block", s = s, b = b, records = {}, gone = true, via = via }
    else out{ t = "status_error", s = s, b = b, err = tostring(err) } end
    return
  end
  local recs = {}
  for _, r in ipairs(st.records or {}) do
    recs[#recs + 1] = { id = r.id or "", state = r.state, kind = r.kind, at = r.updated_at,
                        app = r.effective_app or r.app, title = r.title, msg = clip(r.msg) }  -- title ≤192 bytes by protocol
  end
  out{ t = "block", s = s, b = b, records = recs, via = via }
end

local function view(s)
  local v, err = rex.session.view{ session_id = s }
  if not v then
    if not gone(err) then out{ t = "view_error", s = s, err = tostring(err) } end
    return
  end
  local blocks = {}
  for _, w in ipairs(v.windows or {}) do
    for _, l in ipairs(w.layers or {}) do
      for _, bl in ipairs(l.blocks or {}) do
        blocks[#blocks + 1] = { b = bl.block_id, creator = bl.creator_name,
                                window_id = w.window_id, window_label = w.label, block_label = bl.label }
      end
    end
  end
  out{ t = "view", s = s, session_label = v.label, blocks = blocks }
end

rex.on("terminal.program_status_changed", function(ctx, ev)
  local r = ev.record or {}
  block_status(ctx.session_id, ctx.block_id, { id = ev.id or "", state = r.state, at = r.updated_at })
end)
rex.on("terminal.program_status_removed", function(ctx, ev)
  block_status(ctx.session_id, ctx.block_id, { removed = ev.ids })
end)
rex.on("block_closed",      function(ctx, ev) out{ t = "block_closed", s = ctx.session_id, b = ev.block_id } end)
rex.on("session_destroyed", function(ctx, ev) out{ t = "session_destroyed", s = ev.session_id } end)
rex.on("session_created",   function(ctx, ev)
  local s = ev.session and ev.session.session_id
  if not s then return end
  out{ t = "session_created", s = s, label = ev.session.label }
  view(s)
end)

local pending = {}
local function schedule_view(s)
  if not s or pending[s] then return end
  pending[s] = rex.after(0.5, function() pending[s] = nil; view(s) end)
end
rex.on("session_view_changed",  function(ctx) schedule_view(ctx.session_id) end)
rex.on("session_label_changed", function(ctx) schedule_view(ctx.session_id) end)
rex.on("block_created",         function(ctx) schedule_view(ctx.session_id) end)

local function snapshot()
  local listed, err = rex.call("session.list")
  if not listed then error("session.list: " .. tostring(err)) end
  for _, s in ipairs(listed.sessions or {}) do
    local id = s.session_id
    local lb, e2 = rex.session.list_blocks{ session_id = id }
    if lb then
      out{ t = "session", s = id, label = s.label }
      view(id)
      for _, b in ipairs(lb.blocks or {}) do
        if b.creator_name == TERMINAL then block_status(id, b.block_id, nil) end
      end
    elseif not gone(e2) then
      error("list_blocks " .. id .. ": " .. tostring(e2))
    end
  end
  out{ t = "snapshot_done" }
end

rex.after(0, function()
  local ok, err = pcall(snapshot)
  if not ok then out{ t = "snapshot_error", err = tostring(err) }; rex.stop(1) end
end)
rex.every(5, function() out{ t = "heartbeat" } end)
-- no return value (F1)
