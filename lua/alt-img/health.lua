local M = {}

---@type string[]
local PROTOCOLS = { "iterm2", "sixel" }

---@param h vim.health.Report
local function active_provider_line(h)
    local ok, p = pcall(require("alt-img").provider)
    if not ok or not p then
        h.error(string.format("Active provider: none detected (%s)", tostring(p)))
        return
    end
    local name
    for _, n in ipairs(PROTOCOLS) do
        if p == require("alt-img." .. n) then
            name = n
            break
        end
    end
    h.ok(string.format("Active provider: %s (autodetected)", name or "?"))
end

---@param h vim.health.Report
local function probe_protocols(h)
    h.start("alt-img: protocols")
    for _, name in ipairs(PROTOCOLS) do
        local p = require("alt-img." .. name)
        local supported, msg = p._supported({ timeout = 200 })
        if supported then
            h.ok(string.format("%s: supported%s", name, msg and (" (" .. msg .. ")") or ""))
        else
            h.error(string.format("%s: not detected%s", name, msg and (" — " .. msg) or ""))
        end
    end
end

---@param h vim.health.Report
local function tooling(h)
    h.start("alt-img: external tools")

    local magick = require("alt-img._core.magick").binary()
    if magick then
        h.ok("ImageMagick: " .. magick)
    else
        h.info("ImageMagick: not found " .. "(set vim.g.alt_img.processing.magick or install magick/convert)")
    end

    local libsixel = require("alt-img.sixel._libsixel").binary()
    if libsixel then
        h.ok("libsixel: " .. libsixel)
    else
        h.info("libsixel: not found " .. "(set vim.g.alt_img.processing.img2sixel or install)")
    end

    local chafa = require("alt-img.sixel._chafa").binary()
    if chafa then
        h.ok("chafa: " .. chafa .. " (preserves PNG transparency in sixel output)")
    elseif libsixel or magick then
        -- chafa is the only external sixel encoder that preserves alpha. With
        -- only img2sixel/magick available, alpha-bearing PNGs render with
        -- transparent regions flattened to the tool's background color
        -- (default black). The pure-Lua tail still preserves alpha but is
        -- slower; the dispatch reaches it only when every external tool fails.
        h.warn(
            "chafa: not found — magick/img2sixel will flatten PNG alpha against "
                .. "their background color (default black), so transparent regions "
                .. "render as opaque black. Install chafa for proper transparency, "
                .. "or set your terminal background color to match what you want "
                .. "the alpha pixels to appear as."
        )
    else
        h.info("chafa: not found (and no other sixel encoder configured); pure-Lua encoder will run.")
    end

    local png = require("alt-img._core.png")
    if png.has_libz() then
        h.ok("PNG encoder: libz DEFLATE compression active")
    else
        h.info(
            "PNG encoder: libz not found, falling back to stored zlib blocks. "
                .. "When ImageMagick is available the sixel encoder sends raw RGBA "
                .. "to `magick` to skip the PNG hop. Install zlib (Windows: ensure "
                .. "zlib1.dll is on PATH) for the compressed-PNG path."
        )
    end

    -- Catch typos in processing.tools — names that aren't recognized are
    -- silently ignored at the resolver layer, so surface them here.
    local KNOWN = { magick = true, img2sixel = true, chafa = true, libz = true }
    local pcfg = require("alt-img._core.processing").read()
    if type(pcfg.tools) == "table" then
        for _, name in ipairs(pcfg.tools) do
            if not KNOWN[name] then
                h.warn(
                    string.format(
                        "processing.tools contains unknown name '%s' — known tools are magick, img2sixel, chafa, libz",
                        tostring(name)
                    )
                )
            end
        end
    end
end

---@param h vim.health.Report
local function environment(h)
    local notes = {}
    if vim.env.SSH_CONNECTION then
        notes[#notes + 1] = {
            "warn",
            "SSH connection detected. Inline images over SSH require terminal support on your local terminal.",
        }
    end
    if vim.env.TMUX then
        notes[#notes + 1] = {
            "warn",
            "tmux detected: tmux passthrough is NOT supported in this version of alt-img.nvim. "
                .. "Images may not render. Tracked in README.",
        }
    end
    if vim.env.TERM_PROGRAM == "Apple_Terminal" then
        notes[#notes + 1] = { "warn", "Apple Terminal echoes APC sequences but does not render sixel." }
    end
    if #notes == 0 then
        return
    end

    h.start("alt-img: environment")
    for _, n in ipairs(notes) do
        h[n[1]](n[2])
    end
end

---@return nil
function M.check()
    local h = vim.health
    h.start("alt-img")
    active_provider_line(h)
    probe_protocols(h)
    tooling(h)
    environment(h)
end

return M
