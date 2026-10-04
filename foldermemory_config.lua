--[[
memory.lua – folder memory config management
Handles loading/saving per-folder settings for sort, display mode,
book status filter, and items per page (mosaic grid / list).
--]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local FileChooser = require("ui/widget/filechooser")
local FileManager = require("apps/filemanager/filemanager")
local logger = require("logger")

local SETTINGS_FILE = DataStorage:getSettingsDir() .. "/foldermemory.lua"

-- Key name for default/template settings
local DEFAULT_KEY = "__default__"

-- Key name for inheritance flag
local INHERITANCE_KEY = "__inheritance__"

-- CoverBrowser settings that decide how many items fit on a page. KOReader keeps
-- them in global settings shared with CoverBrowser's menus for History,
-- Collections and the file searcher, so the plugin restores them on the file
-- chooser instance instead of writing those globals (see applyFolderMemory).
local GRID_FIELDS = {
    "nb_cols_portrait",
    "nb_rows_portrait",
    "nb_cols_landscape",
    "nb_rows_landscape",
    "files_per_page",
}

local Memory = {}

-- Cached settings instance (loaded once, flushed on write)
local _settings = nil

-- BookInfoManager availability (checked once at init)
local _BookInfoManager = nil
local _hasBookInfoManager = nil

-- Whether to inherit settings from parent folders (default: true)
Memory.inheritance_enabled = true

-- Flag: true while editing __default__ settings from the config submenu.
-- When set, all auto-save hooks bail out so that changes are only persisted
-- to the __default__ entry and never leak to the current folder.
Memory._editing_default = false

-- Flag: true while editing a global setting from the "Global settings for other
-- views" submenu. The auto-save hooks bail out, so the change stays global: it is
-- neither mirrored onto the file chooser nor saved for the current folder.
Memory._editing_global = false

--- Initialize: load settings once, check optional modules
function Memory.init()
    _settings = LuaSettings:open(SETTINGS_FILE)
    -- Restore inheritance flag
    local inh = _settings:readSetting(INHERITANCE_KEY)
    if inh ~= nil then
        Memory.inheritance_enabled = inh
    end
    local ok, bim = pcall(require, "bookinfomanager")
    if ok and bim then
        _hasBookInfoManager = true
        _BookInfoManager = bim
    else
        _hasBookInfoManager = false
        _BookInfoManager = nil
    end
    -- Auto-create __default__ from current settings on first install
    Memory.ensureDefaultSettings()
end

--- Flush and close settings (call before shutdown)
function Memory.close()
    if _settings then
        _settings:flush()
        _settings = nil
    end
end

--- Check if a path has its own saved settings (not from default template)
function Memory.hasOwnSettings(path)
    if not _settings then
        Memory.init()
    end
    local mem = _settings:readSetting(path)
    return type(mem) == "table" and next(mem) ~= nil
end

--- Extract parent path (one level up). Paths are expected to end with "/".
--- e.g. "/mnt/onboard/Books/Fantasy/" → "/mnt/onboard/Books/"
--- Returns nil if already at root (no parent).
local function _getParentPath(path)
    if not path or path == "/" then return nil end
    local has_trailing = path:sub(-1) == "/"
    local p = has_trailing and path:sub(1, -2) or path
    -- Find last "/"
    local i = p:find("/[^/]*$")
    if i then
        local parent = p:sub(1, i)
        -- Preserve trailing slash convention from original path
        if not has_trailing and parent:sub(-1) == "/" then
            parent = parent:sub(1, -2)
        end
        return parent
    end
    return nil
end

--- Read saved memory for a given path.
--- Returns nil if no entry exists (caller decides fallback logic).
--- Inheritance chain:
---   1. Own settings for this path
---   2. Nearest ancestor with saved settings (parent, grandparent, …)
---   3. __default__ template
---   4. nil (global defaults)
---
--- Virtual views (History, Favorites, Collections) always use __default__ only.
function Memory.getFolderMemory(path)
    if not _settings then
        Memory.init()
    end

    -- 1. Own settings
    local mem = _settings:readSetting(path)
    if type(mem) == "table" and next(mem) ~= nil then
        return mem
    end

    -- 2. Walk up to nearest ancestor with saved settings (only if inheritance enabled)
    if Memory.inheritance_enabled then
        local parent = _getParentPath(path)
        while parent do
            mem = _settings:readSetting(parent)
            if type(mem) == "table" and next(mem) ~= nil then
                return mem
            end
            parent = _getParentPath(parent)
        end
    end

    -- 3. Fallback to default template
    local def = _settings:readSetting(DEFAULT_KEY)
    if type(def) == "table" and next(def) ~= nil then
        return def
    end

    return nil
end

--- Save memory for a given path. If mem is nil or empty, delete the entry.
function Memory.saveFolderMemory(path, mem)
    if not _settings then
        Memory.init()
    end
    if mem == nil or type(mem) ~= "table" or next(mem) == nil then
        _settings:delSetting(path)
    else
        -- Clean nil values
        local clean = {}
        for k, v in pairs(mem) do
            if v ~= nil then
                clean[k] = v
            end
        end
        if next(clean) == nil then
            _settings:delSetting(path)
        else
            _settings:saveSetting(path, clean)
        end
    end
    _settings:flush()
end

--- Enable or disable parent folder inheritance.
--- When disabled, folders without own settings fall back directly to __default__
--- (skipping ancestor folders).
function Memory.setInheritance(enabled)
    Memory.inheritance_enabled = enabled
    if not _settings then
        Memory.init()
    end
    _settings:saveSetting(INHERITANCE_KEY, enabled)
    _settings:flush()
end

--- Save current settings as the default template for all folders
function Memory.saveAsDefault()
    local mem = Memory.captureCurrentSettings()
    Memory.saveFolderMemory(DEFAULT_KEY, mem)
end

--- Clear all folder memory (keep defaults if user wants to)
function Memory.clearAll(keep_default)
    if not _settings then
        Memory.init()
    end
    local default = nil
    if keep_default then
        default = _settings:readSetting(DEFAULT_KEY)
    end
    -- First collect all keys, then delete (avoid modifying table during iteration)
    local keys = {}
    for key in pairs(_settings.data) do
        table.insert(keys, key)
    end
    for _, key in ipairs(keys) do
        _settings:delSetting(key)
    end
    -- Restore default template if requested
    if keep_default and default and type(default) == "table" and next(default) ~= nil then
        _settings:saveSetting(DEFAULT_KEY, default)
    end
    _settings:flush()
end

--- Auto-create __default__ settings from current KOReader state
--- if no default template exists yet (used on first plugin install).
function Memory.ensureDefaultSettings()
    if not _settings then Memory.init() end
    local def = _settings:readSetting(DEFAULT_KEY)
    -- Already exists – bail out
    if type(def) == "table" and next(def) ~= nil then
        return
    end
    -- Capture current KOReader settings as the default template
    local mem = Memory.captureCurrentSettings()
    if mem and next(mem) ~= nil then
        Memory.saveFolderMemory(DEFAULT_KEY, mem)
        logger.dbg("FolderMemory: auto-created __default__ from current settings")
    end
end

--- Clear memory for a specific folder
function Memory.clearFolder(path)
    if not _settings then
        Memory.init()
    end
    _settings:delSetting(path)
    _settings:flush()
end

--- Capture all current settings from the live FileChooser instance
function Memory.captureCurrentSettings()
    local mem = {}

    -- Read from the live FileChooser instance, not from G_reader_settings
    local fm = FileManager.instance
    local fc = fm and fm.file_chooser
    if fc then
        -- collate – read the collate ID from the instance's live state
        mem.collate = G_reader_settings:readSetting("collate")
        mem.reverse_collate = G_reader_settings:readSetting("reverse_collate")
        mem.collate_mixed = G_reader_settings:readSetting("collate_mixed")
    else
        -- Fallback to global settings if instance not available
        mem.collate = G_reader_settings:readSetting("collate")
        mem.reverse_collate = G_reader_settings:readSetting("reverse_collate")
        mem.collate_mixed = G_reader_settings:readSetting("collate_mixed")
    end

    -- Book status filter (deep copy to avoid reference sharing)
    -- Convention: nil = "all" (no filter), {status={...}} = active filter
    local sf = FileChooser.show_filter
    if sf and sf.status and next(sf.status) ~= nil then
        mem.show_filter = { status = {} }
        for k, v in pairs(sf.status) do
            mem.show_filter.status[k] = v
        end
    else
        -- No filter active (nil means "all" – explicit choice)
        mem.show_filter = nil
    end

    -- Display mode from CoverBrowser (if available)
    -- nil in CoverBrowser means "classic" – store it explicitly as "classic"
    if _hasBookInfoManager then
        mem.display_mode = _BookInfoManager:getSetting("filemanager_display_mode") or "classic"
        -- Grid settings: the file chooser carries the effective value (either the
        -- per-folder override or, failing that, the global one).
        for _, field in ipairs(GRID_FIELDS) do
            mem[field] = (fc and fc[field]) or _BookInfoManager:getSetting(field)
        end
    end

    -- Items per page in classic display mode. The file chooser may carry a
    -- per-folder override (see applyFolderMemory); otherwise KOReader's global
    -- setting is in effect.
    mem.items_per_page = (fc and fc.items_per_page) or G_reader_settings:readSetting("items_per_page")

    return mem
end

--- Apply saved memory to the current state (global settings + instance)
function Memory.applyFolderMemory(mem)
    -- Per-folder overrides live on the file chooser instance rather than in the
    -- global settings, because KOReader keeps these values globally and shares
    -- them with Collections, OPDS, History and search results – writing them
    -- there would make all of those inherit the last folder visited. They are
    -- reset here, before the early returns below, so a folder with no memory –
    -- or with no value for a given setting – falls back to the global one.
    local chooser = FileManager.instance and FileManager.instance.file_chooser
    if chooser then
        chooser.items_per_page = nil
        if _hasBookInfoManager then
            for _, field in ipairs(GRID_FIELDS) do
                chooser[field] = _BookInfoManager:getSetting(field)
            end
        end
    end

    if not mem then return end

    -- Sort by
    if mem.collate ~= nil then
        G_reader_settings:saveSetting("collate", mem.collate)
    end

    -- Reverse sort
    if mem.reverse_collate ~= nil then
        G_reader_settings:saveSetting("reverse_collate", mem.reverse_collate)
    else
        G_reader_settings:delSetting("reverse_collate")
    end

    -- Mixed sort
    if mem.collate_mixed ~= nil then
        G_reader_settings:saveSetting("collate_mixed", mem.collate_mixed)
    else
        G_reader_settings:delSetting("collate_mixed")
    end

    -- Book status filter
    if mem.show_filter ~= nil then
        if mem.show_filter.status and next(mem.show_filter.status) ~= nil then
            FileChooser.show_filter = { status = {} }
            for k, v in pairs(mem.show_filter.status) do
                FileChooser.show_filter.status[k] = v
            end
        else
            FileChooser.show_filter = {}
        end
    else
        -- nil means "all" – reset filter
        FileChooser.show_filter = {}
    end

    -- Display mode
    if mem.display_mode ~= nil then
        local ui = FileManager.instance
        if ui and ui.coverbrowser then
            -- "classic" is the empty/nil mode in CoverBrowser
            local dm = (mem.display_mode == "classic") and nil or mem.display_mode
            ui.coverbrowser:setDisplayMode(dm)
        end
    end

    -- Items per page in classic mode: set on the file chooser instance only, so
    -- the global setting – and with it Collections, OPDS and search results –
    -- stays untouched. Folders in another display mode keep the override
    -- cleared, since the value does not affect their file list at all.
    -- Sits before the CoverBrowser guard below, classic mode not needing it.
    if chooser and mem.items_per_page ~= nil
            and (mem.display_mode == nil or mem.display_mode == "classic") then
        chooser.items_per_page = mem.items_per_page
    end

    -- Items per page (mosaic grid + list): instance overrides only, so the
    -- global CoverBrowser settings – and with them the menus of Collections,
    -- History and the file searcher – keep the value the user set there.
    if not _hasBookInfoManager then return end

    if chooser then
        for _, field in ipairs(GRID_FIELDS) do
            if mem[field] ~= nil then
                chooser[field] = mem[field]
            end
        end
    end
end

return Memory
