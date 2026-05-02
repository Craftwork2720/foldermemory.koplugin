--[[
Folder Memory – zapamiętuje ustawienia per folder (tryb ręczny).

Co zapamiętuje:
- sort by (collate)
- reverse sort
- mixed sort
- book status filter
- display mode (CoverBrowser): list, mosaic, classic
- items per page: mosaic columns/rows (portrait + landscape), list files_per_page

Logika:
- Przy wejściu do folderu: przywraca zapisane ustawienia (changeToPath hook)
- Zapis TYLKO ręczny – użytkownik wybiera "Save current settings for this folder"
- Opcja "Save current settings as default" – szablon dla folderów bez pamięci

Zarządzanie:
- Menu wtyczki w file browser settings
- Zapisz bieżące ustawienia jako domyślne dla folderów bez pamięci
- Wyczyść pamięć dla bieżącego folderu
- Wyczyść całą pamięć folderów
--]]

local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local FileChooser = require("ui/widget/filechooser")
local FileManager = require("apps/filemanager/filemanager")
local _ = require("gettext")
local T = require("ffi/util").template
local util = require("util")
local logger = require("logger")

local Memory = require("memory")

-- Check for CoverBrowser (BookInfoManager) availability
local _BookInfoManager = nil
local _hasBookInfoManager = false
do
    local ok, bim = pcall(require, "bookinfomanager")
    if ok and bim then
        _hasBookInfoManager = true
        _BookInfoManager = bim
    end
end

local BookList = require("ui/widget/booklist")
local SpinWidget = require("ui/widget/spinwidget")
local DoubleSpinWidget = require("ui/widget/doublespinwidget")

local FolderMemory = WidgetContainer:extend{
    name = "foldermemory",
    is_doc_only = false,
}

function FolderMemory:init()
    -- Initialize Memory module (loads settings once, checks optional modules)
    Memory.init()
    self.ui.menu:registerToMainMenu(self)
    self:_setupHooks()
    logger.dbg("FolderMemory: plugin loaded – per-folder sort/display/filter/grid memory enabled")
end

-- ============================================================
-- Hooki – refreshPath do przywracania pamięci + auto-save
-- ============================================================

function FolderMemory:_setupHooks()
    -- ============================================================
    -- Track the last path for which settings were applied.
    -- We only restore folder memory when actually entering a new
    -- folder, not on every refresh (otherwise user changes to
    -- sort/book-status would be immediately reverted).
    -- ============================================================
    local lastAppliedPath = nil

    -- ============================================================
    -- Flag: true while applyFolderMemory is running.
    -- All auto-save hooks check this to avoid feedback loops
    -- (restore triggers hooks → hooks would re-save → pointless).
    -- ============================================================
    local _applying = false
    local _force_apply = false   
    -- ============================================================
    -- Core auto-save: capture + persist current settings for the
    -- active folder.  Always called via nextTick so the original
    -- setter has fully finished before we snapshot state.
    -- ============================================================
    local function autoSave()
        if _applying then return end
        if Memory._editing_default then return end
        local fm = FileManager.instance
        if not fm or not fm.file_chooser then return end
        local path = fm.file_chooser.path
        if not path then return end
        local current = Memory.captureCurrentSettings()
        Memory.saveFolderMemory(path, current)
        logger.dbg("FolderMemory: auto-saved settings for", path)
    end

    local function scheduleAutoSave()
        if _applying then return end
        if Memory._editing_default then return end
        UIManager:nextTick(autoSave)
    end

    -- ============================================================
    -- Wrap Memory.applyFolderMemory so the _applying flag is set
    -- around the call – this suppresses all auto-save hooks that
    -- fire as a side-effect of restoring settings.
    -- ============================================================
    local orig_apply = Memory.applyFolderMemory
    Memory.applyFolderMemory = function(mem)
        _applying = true
        local ok, err = pcall(orig_apply, mem)
        _applying = false
        if not ok then error(err, 2) end
    end

    -- ============================================================
    -- Helper: apply folder memory for a given path, but only if
    -- the path actually changed.
    -- ============================================================
    
local function applyMemoryIfNeeded(path)
    if _applying then return end
    if path and (path ~= lastAppliedPath or _force_apply) then   -- ← sprawdza flagę
        _force_apply = false
        lastAppliedPath = path
        local mem = Memory.getFolderMemory(path)
        if mem then
            Memory.applyFolderMemory(mem)
        end
    end
end


    -- ============================================================
    -- Hook 1: FileChooser.refreshPath
    -- Covers normal navigation: changeToPath, onFolderUp, goHome
    -- (changeToPath calls refreshPath after setting self.path)
    -- ============================================================
    -- On the very first call (startup), defer to nextTick so that
    -- CoverBrowser has time to finish initializing before we try
    -- to set the display mode. Subsequent calls run synchronously
    -- *before* orig_refreshPath to avoid a visible flicker.
    local _startup_done = false

    local orig_refreshPath = FileChooser.refreshPath
    FileChooser.refreshPath = function(self)
        if self.name == "filemanager" then
            local path = self.path
            if not _startup_done then
                UIManager:nextTick(function()
                    _startup_done = true
                    applyMemoryIfNeeded(path)
                end)
            else
                applyMemoryIfNeeded(path)
            end
        end
        local ok, err = pcall(orig_refreshPath, self)
        if not ok then
            logger.warn("FolderMemory: refreshPath failed:", err)
        end
    end

    -- ============================================================
    -- Hook 2: FileManager.onRefresh
    -- Covers return from reader (UIManager shows existing FM instance)
    -- and other cases where refreshPath hook might be shadowed by
    -- other plugins (e.g., CoverBrowser wraps FileChooser methods).
    -- ============================================================
    local orig_onRefresh = FileManager.onRefresh
    FileManager.onRefresh = function(self)
        if self.file_chooser then
            local path = self.file_chooser.path
            if not _startup_done then
                UIManager:nextTick(function()
                    _startup_done = true
                    applyMemoryIfNeeded(path)
                end)
            else
                applyMemoryIfNeeded(path)
            end
        end
        local ok, err = pcall(orig_onRefresh, self)
        if not ok then
            logger.warn("FolderMemory: onRefresh failed:", err)
        end
    end

    -- ============================================================
    -- AUTO-SAVE HOOKS – catch changes made via native KOReader menus
    -- ============================================================

    -- --------------------------------------------------------
    -- Hook 3: G_reader_settings – collate / reverse / mixed
    --
    -- The native sort menus call:
    --   G_reader_settings:saveSetting("collate", id)
    --   G_reader_settings:flipNilOrFalse("reverse_collate")
    --   G_reader_settings:flipNilOrFalse("collate_mixed")
    --
    -- We hook saveSetting for "collate" and flipNilOrFalse for
    -- the two boolean toggles (flipNilOrFalse internally calls
    -- saveSetting *or* delSetting – hooking it once covers both).
    -- --------------------------------------------------------
    local _collate_watch  = { collate = true }
    local _boolean_watch  = { reverse_collate = true, collate_mixed = true }

    local orig_gs_save = G_reader_settings.saveSetting
    G_reader_settings.saveSetting = function(self, key, val, ...)
        orig_gs_save(self, key, val, ...)
        if _collate_watch[key] then
            scheduleAutoSave()
        end
    end

    local orig_gs_flip = G_reader_settings.flipNilOrFalse
    if orig_gs_flip then
        G_reader_settings.flipNilOrFalse = function(self, key, ...)
            orig_gs_flip(self, key, ...)
            if _boolean_watch[key] then
                scheduleAutoSave()
            end
        end
    end

    -- --------------------------------------------------------
    -- Hook 4: BookInfoManager.saveSetting – display mode + grid
    --
    -- CoverBrowser's setDisplayMode() and the grid-size dialogs
    -- all funnel through _BookInfoManager:saveSetting().
    -- We intercept the relevant keys and schedule an auto-save.
    -- --------------------------------------------------------
    if _hasBookInfoManager then
        local _bim_watch = {
            filemanager_display_mode = true,
            nb_cols_portrait         = true,
            nb_rows_portrait         = true,
            nb_cols_landscape        = true,
            nb_rows_landscape        = true,
            files_per_page           = true,
        }
        local orig_bim_save = _BookInfoManager.saveSetting
        _BookInfoManager.saveSetting = function(self, key, val, ...)
            orig_bim_save(self, key, val, ...)
            if _bim_watch[key] then
                scheduleAutoSave()
            end
        end
    end

    -- --------------------------------------------------------
    -- Hook 5: FileChooser.show_filter (book status filter)
    --
    -- The native book-status menu writes directly to the class-
    -- level table FileChooser.show_filter.status, then calls
    -- refreshPath.  There is no setter to hook, so we detect
    -- changes via a fingerprint compared on every refreshPath.
    --
    -- Strategy: wrap the already-wrapped FileChooser.refreshPath
    -- (Hook 1) with a second, thin wrapper that runs *before*
    -- the inner wrapper and checks whether show_filter changed.
    -- --------------------------------------------------------
    local function filterFingerprint()
        local sf = FileChooser.show_filter
        if not sf or not sf.status or not next(sf.status) then return "" end
        local parts = {}
        for k, v in pairs(sf.status) do
            if v then table.insert(parts, k) end
        end
        table.sort(parts)
        return table.concat(parts, ",")
    end

    -- Initialise fingerprint to whatever state was restored at startup;
    -- updated again after every apply so we don't spuriously fire.
    local _lastFilterFP = filterFingerprint()

    -- Patch applyFolderMemory wrapper once more to also reset the
    -- fingerprint after an apply (prevents false-positive auto-save
    -- from the refreshPath that follows restoration).
    local orig_apply_wrapped = Memory.applyFolderMemory
    Memory.applyFolderMemory = function(mem)
        orig_apply_wrapped(mem)
        -- Snapshot the filter we just applied so Hook 5 won't fire.
        _lastFilterFP = filterFingerprint()
    end

    -- Second wrapper around FileChooser.refreshPath (wraps Hook 1's version).
    -- The fingerprint check runs BEFORE the inner wrapper (which updates
    -- lastAppliedPath), so on folder navigation self.path != lastAppliedPath
    -- and we skip the check entirely – no spurious auto-save on cd.
    local orig_refreshPath2 = FileChooser.refreshPath
    FileChooser.refreshPath = function(self)
        if self.name == "filemanager" and not _applying
                and self.path == lastAppliedPath then
            local fp = filterFingerprint()
            if fp ~= _lastFilterFP then
                _lastFilterFP = fp
                scheduleAutoSave()
            end
        end
        orig_refreshPath2(self)
    end

    -- ============================================================
    -- Apply __default__ when entering virtual views
    -- (History, Favorites, Collections) and reset lastAppliedPath
    -- so that the real folder's settings are re-applied on return.
    -- ============================================================
    local function onEnterVirtualView()
        _force_apply = true        -- ← ustaw flagę (nie zeruj lastAppliedPath)
        Memory.applyDefaultMemory()
    end


    -- History: onShowHist
    local FileManagerHistory = require("apps/filemanager/filemanagerhistory")
    if FileManagerHistory then
        local orig_onShowHist = FileManagerHistory.onShowHist
        FileManagerHistory.onShowHist = function(self, ...)
            onEnterVirtualView()
            if orig_onShowHist then
                return orig_onShowHist(self, ...)
            end
        end
    end

    -- Collections: onShowColl / onShowCollList
    local FileManagerCollection = require("apps/filemanager/filemanagercollection")
    if FileManagerCollection then
        local orig_onShowColl = FileManagerCollection.onShowColl
        FileManagerCollection.onShowColl = function(self, ...)
            onEnterVirtualView()
            if orig_onShowColl then
                return orig_onShowColl(self, ...)
            end
        end

        local orig_onShowCollList = FileManagerCollection.onShowCollList
        FileManagerCollection.onShowCollList = function(self, ...)
            onEnterVirtualView()
            if orig_onShowCollList then
                return orig_onShowCollList(self, ...)
            end
        end
    end
end

-- +--------------------------------------------+
-- | Helper: build book status filter submenu   |
-- +--------------------------------------------+

function FolderMemory:_buildBookStatusMenuTable(refresh_fn, save_fn)
    local statuses = { "new", "reading", "abandoned", "complete" }
    local sub_item_table = {
        {
            text = BookList.getBookStatusString("all"):lower(),
            checked_func = function()
                return FileChooser.show_filter.status == nil
            end,
            radio = true,
                callback = function()
                    FileChooser.show_filter.status = nil
                    if save_fn then save_fn() end
                    if refresh_fn then refresh_fn() end
                end,
            separator = true,
        },
    }
    for _, v in ipairs(statuses) do
        table.insert(sub_item_table, {
            text = BookList.getBookStatusString(v):lower(),
            checked_func = function()
                return FileChooser.show_filter.status and FileChooser.show_filter.status[v]
            end,
                callback = function()
                    FileChooser.show_filter.status = FileChooser.show_filter.status or {}
                    FileChooser.show_filter.status[v] = not FileChooser.show_filter.status[v] or nil
                    local statuses_nb = util.tableSize(FileChooser.show_filter.status)
                    if statuses_nb == 0 or statuses_nb == #statuses then
                        FileChooser.show_filter.status = nil
                    end
                    if save_fn then save_fn() end
                    if refresh_fn then refresh_fn() end
                end,
        })
    end
    return {
        text_func = function()
            local text
            if FileChooser.show_filter.status == nil then
                text = BookList.getBookStatusString("all"):lower()
            else
                for _, v in ipairs(statuses) do
                    if FileChooser.show_filter.status[v] then
                        local status_string = BookList.getBookStatusString(v):lower()
                        text = text and text .. ", " .. status_string or status_string
                    end
                end
            end
            return T(_("Book status: %1"), text)
        end,
        sub_item_table = sub_item_table,
        hold_callback = function(touchmenu_instance)
            FileChooser.show_filter.status = nil
            if refresh_fn then refresh_fn() end
            touchmenu_instance:updateItems()
        end,
    }
end

-- +--------------------------------------------+
-- | Helper: build display mode radio submenu   |
-- +--------------------------------------------+

function FolderMemory:_buildDisplayModeMenuTable(save_fn)
    local modes = {
        { _("Classic (filename only)"), "classic" },
        { _("Mosaic with cover images"), "mosaic_image" },
        { _("Mosaic with text covers"), "mosaic_text" },
        { _("Detailed list with cover images and metadata"), "list_image_meta" },
        { _("Detailed list with metadata, no images"), "list_only_meta" },
        { _("Detailed list with cover images and filenames"), "list_image_filename" },
    }
    local sub_item_table = {}
    for _, mode in ipairs(modes) do
        local mode_label = mode[1]
        local mode_key = mode[2]
        table.insert(sub_item_table, {
            text = mode_label,
            checked_func = function()
                local current = _BookInfoManager:getSetting("filemanager_display_mode")
                if mode_key == "classic" then
                    return current == nil or current == "classic"
                end
                return current == mode_key
            end,
            radio = true,
            callback = function()
                local ui = FileManager.instance
                if ui and ui.coverbrowser then
                    -- "classic" in CoverBrowser is nil
                    local dm = (mode_key == "classic") and nil or mode_key
                    ui.coverbrowser:setDisplayMode(dm)
                end
                if save_fn then save_fn() end
            end,
        })
    end
    return {
        text_func = function()
            local dm = _BookInfoManager:getSetting("filemanager_display_mode")
            if dm == nil or dm == "classic" then
                return _("Display mode") .. ": " .. modes[1][1]
            end
            local names = {}
            for _, mode in ipairs(modes) do
                if mode[2] ~= nil and mode[2] ~= "classic" then
                    names[mode[2]] = mode[1]
                end
            end
            return _("Display mode") .. ": " .. (names[dm] or modes[1][1])
        end,
        sub_item_table = sub_item_table,
    }
end

-- ============================================================
-- Default config submenu builder – edits __default__ only.
-- Never touches KOReader live settings, so hook-based auto-save
-- never fires and changes are only persisted to the __default__
-- entry in foldermemory.lua.
-- ============================================================

function FolderMemory:_buildDefaultConfigSubmenu()
    local menu_items = {}
    local DEFAULT_KEY = "__default__"

    -- --------------------------------------------------------
    -- Helpers
    -- --------------------------------------------------------

    -- Read one field from __default__ memory; fallback to liveReader().
    local function getDef(key, liveReader)
        local def = Memory.getFolderMemory(DEFAULT_KEY)
        if def and def[key] ~= nil then
            return def[key]
        end
        if liveReader then
            return liveReader()
        end
        return nil
    end

    -- Edit __default__ entry safely: set the flag so auto-save hooks
    -- bail out, then clear it on nextTick.
    local function editDefault(fn)
        Memory._editing_default = true
        fn()
        UIManager:nextTick(function() Memory._editing_default = false end)
    end

    -- Save a single field to __default__, preserving other fields.
    local function saveField(key, value)
        editDefault(function()
            local def = Memory.getFolderMemory(DEFAULT_KEY)
            local mem = {}
            if def then
                for k, v in pairs(def) do mem[k] = v end
            end
            if value == nil then
                mem[key] = nil
            else
                mem[key] = value
            end
            Memory.saveFolderMemory(DEFAULT_KEY, mem)
        end)
    end

    -- Shallow-clone a table (used for show_filter).
    local function shallowClone(t)
        if not t then return {} end
        local c = {}
        for k, v in pairs(t) do c[k] = v end
        return c
    end

    -- Save the whole mem table (used when multiple fields change, e.g. show_filter).
    local function saveMem(new_mem)
        editDefault(function()
            Memory.saveFolderMemory(DEFAULT_KEY, new_mem)
        end)
    end

    -- +----------------------------+
    -- | 1. Sort by (radio submenu) |
    -- +----------------------------+
    local function buildSortBySubmenu()
        local sub = {}
        local fc = self.ui.file_chooser
        for k, v in pairs(fc.collates) do
            table.insert(sub, {
                text = v.text,
                menu_order = v.menu_order or 0,
                checked_func = function()
                    local id = getDef("collate", function()
                        local _, cid = fc:getCollate()
                        return cid
                    end)
                    return k == id
                end,
                callback = function(touchmenu_instance)
                    saveField("collate", k)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
                radio = true,
            })
        end
        table.sort(sub, function(a, b) return a.menu_order < b.menu_order end)
        return sub
    end

    menu_items.sort_by = {
        text_func = function()
            local fc = self.ui.file_chooser
            local id = getDef("collate", function()
                local _, cid = fc:getCollate()
                return cid
            end)
            local label = "access"
            if id and fc.collates[id] then
                label = fc.collates[id].text
            end
            return T(_("Sort by: %1"), label)
        end,
        sub_item_table = buildSortBySubmenu(),
    }

    -- +--------------------+
    -- | 2. Reverse sorting |
    -- +--------------------+
    menu_items.reverse_sorting = {
        text = _("Reverse sorting"),
        checked_func = function()
            return getDef("reverse_collate", function()
                return G_reader_settings:isTrue("reverse_collate")
            end)
        end,
        callback = function(touchmenu_instance)
            local cur = getDef("reverse_collate", function()
                return G_reader_settings:isTrue("reverse_collate")
            end)
            saveField("reverse_collate", not cur)
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    }

    -- +--------------------------------+
    -- | 3. Folders and files mixed     |
    -- +--------------------------------+
    menu_items.sort_mixed = {
        text = _("Folders and files mixed"),
        separator = true,
        enabled_func = function()
            local fc = self.ui.file_chooser
            local id = getDef("collate", function()
                local _, cid = fc:getCollate()
                return cid
            end)
            if id and fc.collates[id] then
                return fc.collates[id].can_collate_mixed or false
            end
            return false
        end,
        checked_func = function()
            return getDef("collate_mixed", function()
                return G_reader_settings:isTrue("collate_mixed")
            end)
        end,
        callback = function(touchmenu_instance)
            local cur = getDef("collate_mixed", function()
                return G_reader_settings:isTrue("collate_mixed")
            end)
            saveField("collate_mixed", not cur)
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    }

    -- +---------------------+
    -- | 4. Book status      |
    -- +---------------------+
    do
        local statuses = { "new", "reading", "abandoned", "complete" }
        local sub_item_table = {
            {
                text = BookList.getBookStatusString("all"):lower(),
                checked_func = function()
                    return getDef("show_filter", function() return G_reader_settings:readSetting("show_filter") end) == nil
                        or (function()
                            local sf = getDef("show_filter", function() return G_reader_settings:readSetting("show_filter") end)
                            return sf == nil or sf.status == nil
                        end)()
                end,
                radio = true,
                callback = function(touchmenu_instance)
                    saveField("show_filter", nil)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
                separator = true,
            },
        }
        for _, v in ipairs(statuses) do
            table.insert(sub_item_table, {
                text = BookList.getBookStatusString(v):lower(),
                checked_func = function()
                    local sf = getDef("show_filter", function() return G_reader_settings:readSetting("show_filter") end)
                    return sf and sf.status and sf.status[v] == true
                end,
                callback = function(touchmenu_instance)
                    local sf = getDef("show_filter", function() return G_reader_settings:readSetting("show_filter") end)
                    local mem = {}
                    local def = Memory.getFolderMemory(DEFAULT_KEY)
                    if def then
                        for kk, vv in pairs(def) do mem[kk] = vv end
                    end
                    local new_sf = {}
                    if sf and sf.status then
                        new_sf = { status = shallowClone(sf.status) }
                    else
                        new_sf = { status = {} }
                    end
                    new_sf.status[v] = not new_sf.status[v] or nil
                    if not next(new_sf.status) then
                        mem.show_filter = nil
                    else
                        mem.show_filter = new_sf
                    end
                    saveMem(mem)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end
        menu_items.book_status = {
            text_func = function()
                local sf = getDef("show_filter", function() return G_reader_settings:readSetting("show_filter") end)
                local text
                if sf == nil or sf.status == nil then
                    text = BookList.getBookStatusString("all"):lower()
                else
                    for _, v in ipairs(statuses) do
                        if sf.status[v] then
                            local status_string = BookList.getBookStatusString(v):lower()
                            text = text and text .. ", " .. status_string or status_string
                        end
                    end
                end
                return T(_("Book status: %1"), text)
            end,
            sub_item_table = sub_item_table,
            hold_callback = function(touchmenu_instance)
                saveField("show_filter", nil)
                touchmenu_instance:updateItems()
            end,
        }
        menu_items.book_status.separator = true
    end

    -- +--------------------+
    -- | 5. Display mode    |
    -- +--------------------+
    if _hasBookInfoManager then
        local modes = {
            { _("Classic (filename only)"), "classic" },
            { _("Mosaic with cover images"), "mosaic_image" },
            { _("Mosaic with text covers"), "mosaic_text" },
            { _("Detailed list with cover images and metadata"), "list_image_meta" },
            { _("Detailed list with metadata, no images"), "list_only_meta" },
            { _("Detailed list with cover images and filenames"), "list_image_filename" },
        }
        local sub_item_table = {}
        for _, mode in ipairs(modes) do
            local mode_label = mode[1]
            local mode_key = mode[2]
            table.insert(sub_item_table, {
                text = mode_label,
                checked_func = function()
                    local dm = getDef("display_mode", function()
                        return _BookInfoManager:getSetting("filemanager_display_mode")
                    end)
                    if mode_key == "classic" then
                        return dm == nil or dm == "classic"
                    end
                    return dm == mode_key
                end,
                radio = true,
                callback = function(touchmenu_instance)
                    saveField("display_mode", mode_key)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end
        menu_items.display_mode = {
            text_func = function()
                local dm = getDef("display_mode", function()
                    return _BookInfoManager:getSetting("filemanager_display_mode")
                end)
                if dm == nil or dm == "classic" then
                    return _("Display mode") .. ": " .. modes[1][1]
                end
                local names = {}
                for _, mode in ipairs(modes) do
                    if mode[2] ~= nil and mode[2] ~= "classic" then
                        names[mode[2]] = mode[1]
                    end
                end
                return _("Display mode") .. ": " .. (names[dm] or modes[1][1])
            end,
            sub_item_table = sub_item_table,
        }
    end

    -- +-----------------------------------+
    -- | 6. Items per page (grid / list)   |
    -- +-----------------------------------+
    if _hasBookInfoManager then
        -- Portrait mosaic grid
        menu_items.mosaic_portrait_grid = {
            keep_menu_open = true,
            text_func = function()
                local cols = getDef("nb_cols_portrait", function()
                    return _BookInfoManager:getSetting("nb_cols_portrait")
                end) or 3
                local rows = getDef("nb_rows_portrait", function()
                    return _BookInfoManager:getSetting("nb_rows_portrait")
                end) or 3
                return T(_("Items per page in portrait mosaic mode: %1 × %2"), cols, rows)
            end,
            callback = function(touchmenu_instance)
                local nb_cols = getDef("nb_cols_portrait", function()
                    return _BookInfoManager:getSetting("nb_cols_portrait")
                end) or 3
                local nb_rows = getDef("nb_rows_portrait", function()
                    return _BookInfoManager:getSetting("nb_rows_portrait")
                end) or 3
                local left_value = nb_cols
                local right_value = nb_rows
                local widget = DoubleSpinWidget:new{
                    title_text = _("Default portrait mosaic mode"),
                    width_factor = 0.6,
                    left_text = _("Columns"),
                    left_value = nb_cols,
                    left_min = 2,
                    left_max = 8,
                    left_default = 3,
                    left_precision = "%01d",
                    right_text = _("Rows"),
                    right_value = nb_rows,
                    right_min = 2,
                    right_max = 8,
                    right_default = 3,
                    right_precision = "%01d",
                    keep_shown_on_apply = true,
                    callback = function(lv, rv)
                        left_value = lv
                        right_value = rv
                        -- Save immediately so text_func sees the updated value
                        editDefault(function()
                            local def = Memory.getFolderMemory(DEFAULT_KEY)
                            local mem = {}
                            if def then
                                for k, v in pairs(def) do mem[k] = v end
                            end
                            mem.nb_cols_portrait = lv
                            mem.nb_rows_portrait = rv
                            Memory.saveFolderMemory(DEFAULT_KEY, mem)
                        end)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                    close_callback = function()
                        -- Final save already done in callback; just verify
                        if left_value ~= nb_cols or right_value ~= nb_rows then
                            editDefault(function()
                                local def = Memory.getFolderMemory(DEFAULT_KEY)
                                local mem = {}
                                if def then
                                    for k, v in pairs(def) do mem[k] = v end
                                end
                                mem.nb_cols_portrait = left_value
                                mem.nb_rows_portrait = right_value
                                Memory.saveFolderMemory(DEFAULT_KEY, mem)
                            end)
                        end
                    end,
                }
                UIManager:show(widget)
            end,
        }
        -- Landscape mosaic grid
        menu_items.mosaic_landscape_grid = {
            keep_menu_open = true,
            text_func = function()
                local cols = getDef("nb_cols_landscape", function()
                    return _BookInfoManager:getSetting("nb_cols_landscape")
                end) or 4
                local rows = getDef("nb_rows_landscape", function()
                    return _BookInfoManager:getSetting("nb_rows_landscape")
                end) or 2
                return T(_("Items per page in landscape mosaic mode: %1 × %2"), cols, rows)
            end,
            callback = function(touchmenu_instance)
                local nb_cols = getDef("nb_cols_landscape", function()
                    return _BookInfoManager:getSetting("nb_cols_landscape")
                end) or 4
                local nb_rows = getDef("nb_rows_landscape", function()
                    return _BookInfoManager:getSetting("nb_rows_landscape")
                end) or 2
                local left_value = nb_cols
                local right_value = nb_rows
                local widget = DoubleSpinWidget:new{
                    title_text = _("Default landscape mosaic mode"),
                    width_factor = 0.6,
                    left_text = _("Columns"),
                    left_value = nb_cols,
                    left_min = 2,
                    left_max = 8,
                    left_default = 4,
                    left_precision = "%01d",
                    right_text = _("Rows"),
                    right_value = nb_rows,
                    right_min = 2,
                    right_max = 8,
                    right_default = 2,
                    right_precision = "%01d",
                    keep_shown_on_apply = true,
                    callback = function(lv, rv)
                        left_value = lv
                        right_value = rv
                        -- Save immediately so text_func sees the updated value
                        editDefault(function()
                            local def = Memory.getFolderMemory(DEFAULT_KEY)
                            local mem = {}
                            if def then
                                for k, v in pairs(def) do mem[k] = v end
                            end
                            mem.nb_cols_landscape = lv
                            mem.nb_rows_landscape = rv
                            Memory.saveFolderMemory(DEFAULT_KEY, mem)
                        end)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                    close_callback = function()
                        -- Final save already done in callback; just verify
                        if left_value ~= nb_cols or right_value ~= nb_rows then
                            editDefault(function()
                                local def = Memory.getFolderMemory(DEFAULT_KEY)
                                local mem = {}
                                if def then
                                    for k, v in pairs(def) do mem[k] = v end
                                end
                                mem.nb_cols_landscape = left_value
                                mem.nb_rows_landscape = right_value
                                Memory.saveFolderMemory(DEFAULT_KEY, mem)
                            end)
                        end
                    end,
                }
                UIManager:show(widget)
            end,
        }
        -- Files per page (list mode)
        menu_items.files_per_page = {
            keep_menu_open = true,
            separator = true,
            text_func = function()
                local v = getDef("files_per_page", function()
                    return _BookInfoManager:getSetting("files_per_page")
                end) or 10
                return T(_("Items per page in portrait list mode: %1"), v)
            end,
            callback = function(touchmenu_instance)
                local fpp = getDef("files_per_page", function()
                    return _BookInfoManager:getSetting("files_per_page")
                end) or 10
                local current_val = fpp
                local widget = SpinWidget:new{
                    title_text = _("Default portrait list mode"),
                    value = fpp,
                    value_min = 4,
                    value_max = 20,
                    default_value = 10,
                    keep_shown_on_apply = true,
                    callback = function(spin)
                        current_val = spin.value
                        -- Save immediately so text_func sees the updated value
                        editDefault(function()
                            local def = Memory.getFolderMemory(DEFAULT_KEY)
                            local mem = {}
                            if def then
                                for k, v in pairs(def) do mem[k] = v end
                            end
                            mem.files_per_page = spin.value
                            Memory.saveFolderMemory(DEFAULT_KEY, mem)
                        end)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                    close_callback = function()
                        -- Final save already done in callback; just verify
                        if current_val ~= fpp then
                            editDefault(function()
                                local def = Memory.getFolderMemory(DEFAULT_KEY)
                                local mem = {}
                                if def then
                                    for k, v in pairs(def) do mem[k] = v end
                                end
                                mem.files_per_page = current_val
                                Memory.saveFolderMemory(DEFAULT_KEY, mem)
                            end)
                        end
                    end,
                }
                UIManager:show(widget)
            end,
        }
    end

    -- Build the sub_item_table from menu_items, in order
    local order = {
        "sort_by",
        "reverse_sorting",
        "sort_mixed",
        "book_status",
        "display_mode",
        "mosaic_portrait_grid",
        "mosaic_landscape_grid",
        "files_per_page",
    }
    local sub_item_table = {}
    for _, id in ipairs(order) do
        if menu_items[id] then
            table.insert(sub_item_table, menu_items[id])
        end
    end

    return sub_item_table
end

-- ============================================================
-- Config submenu builder – returns a table of menu items
-- ============================================================

function FolderMemory:_buildConfigSubmenu(path)
    local menu_items = {}

    -- Helper: refresh FileChooser after changes
    local function refresh()
        if self.ui and self.ui.file_chooser then
            self.ui.file_chooser:refreshPath()
        end
    end

    -- Helper: save current state to folder memory
    local function saveFolderSettings()
        local live_path = self.ui.file_chooser and self.ui.file_chooser.path
        if not live_path then return end
        local current = Memory.captureCurrentSettings()
        Memory.saveFolderMemory(live_path, current)
    end

    -- Helper: clear folder memory for this path
    local function clearFolderSettings()
        local live_path = self.ui.file_chooser and self.ui.file_chooser.path
        if not live_path then return end
        Memory.clearFolder(live_path)
    end

    -- +----------------------------+
    -- | 1. Sort by (radio submenu) |
    -- +----------------------------+
    local function buildSortBySubmenu()
        local sub = {}
        local fc = self.ui.file_chooser
        for k, v in pairs(fc.collates) do
            table.insert(sub, {
                text = v.text,
                menu_order = v.menu_order or 0,
                checked_func = function()
                    local _, id = fc:getCollate()
                    return k == id
                end,
                callback = function()
                    self.ui:onSetSortBy(k)
                    saveFolderSettings()
                    refresh()
                end,
                radio = true,
            })
        end
        table.sort(sub, function(a, b) return a.menu_order < b.menu_order end)
        return sub
    end

    menu_items.sort_by = {
        text_func = function()
            local collate = self.ui.file_chooser:getCollate()
            return T(_("Sort by: %1"), collate.text)
        end,
        sub_item_table = buildSortBySubmenu(),
    }

    -- +--------------------+
    -- | 2. Reverse sorting |
    -- +--------------------+
    menu_items.reverse_sorting = {
        text = _("Reverse sorting"),
        checked_func = function()
            return G_reader_settings:isTrue("reverse_collate")
        end,
        callback = function()
            G_reader_settings:flipNilOrFalse("reverse_collate")
            saveFolderSettings()
            refresh()
        end,
    }

    -- +--------------------------------+
    -- | 3. Folders and files mixed     |
    -- +--------------------------------+
    menu_items.sort_mixed = {
        text = _("Folders and files mixed"),
        separator = true,
        enabled_func = function()
            local collate = self.ui.file_chooser:getCollate()
            return collate.can_collate_mixed or false
        end,
        checked_func = function()
            local collate = self.ui.file_chooser:getCollate()
            return collate.can_collate_mixed and G_reader_settings:isTrue("collate_mixed")
        end,
        callback = function()
            G_reader_settings:flipNilOrFalse("collate_mixed")
            saveFolderSettings()
            refresh()
        end,
    }

    -- +--------------------+
    -- | 4. Book status     |
    -- +--------------------+
    menu_items.book_status = self:_buildBookStatusMenuTable(refresh, saveFolderSettings)
    menu_items.book_status.separator = true

    -- +--------------------+
    -- | 5. Display mode    |
    -- +--------------------+
    if _hasBookInfoManager then
        menu_items.display_mode = self:_buildDisplayModeMenuTable(saveFolderSettings)
    end

    -- +-----------------------------------+
    -- | 6. Items per page (grid / list)   |
    -- +-----------------------------------+
    if _hasBookInfoManager then
        local fc = self.ui.file_chooser
        -- Mosaic grid: DoubleSpinWidget (columns × rows in one dialog)
        menu_items.mosaic_portrait_grid = {
            keep_menu_open = true,
            text_func = function()
                local cols = fc.nb_cols_portrait or _BookInfoManager:getSetting("nb_cols_portrait") or 3
                local rows = fc.nb_rows_portrait or _BookInfoManager:getSetting("nb_rows_portrait") or 3
                return T(_("Items per page in portrait mosaic mode: %1 × %2"), cols, rows)
            end,
            callback = function(touchmenu_instance)
                local nb_cols = fc.nb_cols_portrait or _BookInfoManager:getSetting("nb_cols_portrait") or 3
                local nb_rows = fc.nb_rows_portrait or _BookInfoManager:getSetting("nb_rows_portrait") or 3
                local widget = DoubleSpinWidget:new{
                    title_text = _("Portrait mosaic mode"),
                    width_factor = 0.6,
                    left_text = _("Columns"),
                    left_value = nb_cols,
                    left_min = 2,
                    left_max = 8,
                    left_default = 3,
                    left_precision = "%01d",
                    right_text = _("Rows"),
                    right_value = nb_rows,
                    right_min = 2,
                    right_max = 8,
                    right_default = 3,
                    right_precision = "%01d",
                    keep_shown_on_apply = true,
                    callback = function(left_value, right_value)
                        fc.nb_cols_portrait = left_value
                        fc.nb_rows_portrait = right_value
                        if fc.display_mode_type == "mosaic" and fc.portrait_mode then
                            fc.no_refresh_covers = true
                            fc:updateItems()
                        end
                        _BookInfoManager:saveSetting("nb_cols_portrait", left_value)
                        _BookInfoManager:saveSetting("nb_rows_portrait", right_value)
                        FileChooser.nb_cols_portrait = left_value
                        FileChooser.nb_rows_portrait = right_value
                        saveFolderSettings()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                    close_callback = function()
                        if fc.nb_cols_portrait ~= nb_cols or fc.nb_rows_portrait ~= nb_rows then
                            _BookInfoManager:saveSetting("nb_cols_portrait", fc.nb_cols_portrait)
                            _BookInfoManager:saveSetting("nb_rows_portrait", fc.nb_rows_portrait)
                            FileChooser.nb_cols_portrait = fc.nb_cols_portrait
                            FileChooser.nb_rows_portrait = fc.nb_rows_portrait
                            saveFolderSettings()
                            if fc.display_mode_type == "mosaic" and fc.portrait_mode then
                                fc.no_refresh_covers = nil
                                fc:updateItems()
                            end
                        end
                    end,
                }
                UIManager:show(widget)
            end,
        }
        menu_items.mosaic_landscape_grid = {
            keep_menu_open = true,
            text_func = function()
                local cols = fc.nb_cols_landscape or _BookInfoManager:getSetting("nb_cols_landscape") or 4
                local rows = fc.nb_rows_landscape or _BookInfoManager:getSetting("nb_rows_landscape") or 2
                return T(_("Items per page in landscape mosaic mode: %1 × %2"), cols, rows)
            end,
            callback = function(touchmenu_instance)
                local nb_cols = fc.nb_cols_landscape or _BookInfoManager:getSetting("nb_cols_landscape") or 4
                local nb_rows = fc.nb_rows_landscape or _BookInfoManager:getSetting("nb_rows_landscape") or 2
                local widget = DoubleSpinWidget:new{
                    title_text = _("Landscape mosaic mode"),
                    width_factor = 0.6,
                    left_text = _("Columns"),
                    left_value = nb_cols,
                    left_min = 2,
                    left_max = 8,
                    left_default = 4,
                    left_precision = "%01d",
                    right_text = _("Rows"),
                    right_value = nb_rows,
                    right_min = 2,
                    right_max = 8,
                    right_default = 2,
                    right_precision = "%01d",
                    keep_shown_on_apply = true,
                    callback = function(left_value, right_value)
                        fc.nb_cols_landscape = left_value
                        fc.nb_rows_landscape = right_value
                        if fc.display_mode_type == "mosaic" and not fc.portrait_mode then
                            fc.no_refresh_covers = true
                            fc:updateItems()
                        end
                        _BookInfoManager:saveSetting("nb_cols_landscape", left_value)
                        _BookInfoManager:saveSetting("nb_rows_landscape", right_value)
                        FileChooser.nb_cols_landscape = left_value
                        FileChooser.nb_rows_landscape = right_value
                        saveFolderSettings()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                    close_callback = function()
                        if fc.nb_cols_landscape ~= nb_cols or fc.nb_rows_landscape ~= nb_rows then
                            _BookInfoManager:saveSetting("nb_cols_landscape", fc.nb_cols_landscape)
                            _BookInfoManager:saveSetting("nb_rows_landscape", fc.nb_rows_landscape)
                            FileChooser.nb_cols_landscape = fc.nb_cols_landscape
                            FileChooser.nb_rows_landscape = fc.nb_rows_landscape
                            saveFolderSettings()
                            if fc.display_mode_type == "mosaic" and not fc.portrait_mode then
                                fc.no_refresh_covers = nil
                                fc:updateItems()
                            end
                        end
                    end,
                }
                UIManager:show(widget)
            end,
        }
        -- Files per page (list mode)
        menu_items.files_per_page = {
            keep_menu_open = true,
            separator = true,
            text_func = function()
                local v = fc.files_per_page or _BookInfoManager:getSetting("files_per_page") or 10
                return T(_("Items per page in portrait list mode: %1"), v)
            end,
            callback = function(touchmenu_instance)
                local files_per_page_val = fc.files_per_page or _BookInfoManager:getSetting("files_per_page") or 10
                local widget = SpinWidget:new{
                    title_text = _("Portrait list mode"),
                    value = files_per_page_val,
                    value_min = 4,
                    value_max = 20,
                    default_value = 10,
                    keep_shown_on_apply = true,
                    callback = function(spin)
                        fc.files_per_page = spin.value
                        if fc.display_mode_type == "list" then
                            fc.no_refresh_covers = true
                            fc:updateItems()
                        end
                        _BookInfoManager:saveSetting("files_per_page", spin.value)
                        FileChooser.files_per_page = spin.value
                        saveFolderSettings()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                    close_callback = function()
                        if fc.files_per_page ~= files_per_page_val then
                            _BookInfoManager:saveSetting("files_per_page", fc.files_per_page)
                            FileChooser.files_per_page = fc.files_per_page
                            saveFolderSettings()
                            if fc.display_mode_type == "list" then
                                fc.no_refresh_covers = nil
                                fc:updateItems()
                            end
                        end
                    end,
                }
                UIManager:show(widget)
            end,
        }
    end

    -- +-----------------------------------+
    -- | 7. Clear button                   |
    -- +-----------------------------------+
    menu_items.clear_settings = {
        text = _("Clear saved settings for this folder"),
        enabled_func = function()
            local live_path = self.ui.file_chooser and self.ui.file_chooser.path
            return live_path and Memory.hasOwnSettings(live_path)
        end,
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = _("Clear saved settings for this folder? Settings will revert to default or global values."),
                ok_text = _("Clear"),
                ok_callback = function()
                    clearFolderSettings()
                    refresh()
                    UIManager:show(InfoMessage:new{
                        text = _("Folder settings cleared."),
                    })
                end,
            })
        end,
    }

    -- Build the sub_item_table from our menu_items, in order
    local order = {
        "sort_by",
        "reverse_sorting",
        "sort_mixed",
        "book_status",
        "display_mode",
        "mosaic_portrait_grid",
        "mosaic_landscape_grid",
        "files_per_page",
        "clear_settings",
    }
    local sub_item_table = {}
    for _, id in ipairs(order) do
        if menu_items[id] then
            table.insert(sub_item_table, menu_items[id])
        end
    end

    return sub_item_table
end

-- ============================================================
-- Menu
-- ============================================================

function FolderMemory:addToMainMenu(menu_items)
    -- Only add menu when in file manager context
    if not self.ui.file_chooser then return end

    local fc = self.ui.file_chooser
    local path = fc.path

    menu_items.folder_memory = {
        text = _("Folder memory"),
        sub_item_table = {},
    }

    -- Config this folder (nested submenu)
    table.insert(menu_items.folder_memory.sub_item_table, {
        text = _("Configure this folder"),
        enabled_func = function()
            return self.ui.file_chooser and self.ui.file_chooser.path ~= nil
        end,
        sub_item_table = self:_buildConfigSubmenu(self.ui.file_chooser.path),
    })


    -- Clear saved settings for this folder
    table.insert(menu_items.folder_memory.sub_item_table, {
        text = _("Clear saved settings for this folder"),
        enabled_func = function()
            return self.ui.file_chooser
                and self.ui.file_chooser.path ~= nil
                and Memory.hasOwnSettings(self.ui.file_chooser.path)
        end,
        separator = true,
        callback = function()
            if not self.ui.file_chooser or not self.ui.file_chooser.path then return end
            local p = self.ui.file_chooser.path
            UIManager:show(ConfirmBox:new{
                text = _("Clear saved settings for this folder? Settings will revert to default or global values."),
                ok_text = _("Clear"),
                ok_callback = function()
                    Memory.clearFolder(p)
                    UIManager:show(InfoMessage:new{
                        text = _("Folder settings cleared."),
                    })
                    self.ui:onRefresh()
                end,
            })
        end,
    })
 

    -- Toggle: inherit parent folder settings
    table.insert(menu_items.folder_memory.sub_item_table, {
        text = _("Inherit settings from parent folders"),
        checked_func = function()
            return Memory.inheritance_enabled
        end,
        callback = function()
            Memory.setInheritance(not Memory.inheritance_enabled)
            self.ui:onRefresh()
        end,
        keep_menu_open = true,
    })

       -- Configure default settings (separate function – never touches KOReader live state)
    table.insert(menu_items.folder_memory.sub_item_table, {
        text = _("Configure default settings"),
        separator = true,
        sub_item_table = self:_buildDefaultConfigSubmenu(),
    })

    -- Clear all folder memory
    table.insert(menu_items.folder_memory.sub_item_table, {
        text = _("Clear all saved folder settings"),
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = _("Clear all saved folder settings? Default settings will be kept if they exist."),
                ok_text = _("Clear all"),
                ok_callback = function()
                    Memory.clearAll(true)
                    UIManager:show(InfoMessage:new{
                        text = _("All folder memory cleared."),
                    })
                    self.ui:onRefresh()
                end,
            })
        end,
    })
end

-- Insert folder_memory right after sort_mixed in the filemanager settings menu
do
    local filemanager_order = require("ui/elements/filemanager_menu_order")
    local pos = 1
    for i, id in ipairs(filemanager_order.filemanager_settings) do
        if id == "sort_mixed" then
            pos = i + 1
            break
        end
    end
    table.insert(filemanager_order.filemanager_settings, pos, "folder_memory")
end

return FolderMemory