--[[
foldermemory_menu.lua – całe menu pluginu FolderMemory
Wydzielone z main.lua dla czytelności.
]]

local UIManager = require("ui/uimanager")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local FileChooser = require("ui/widget/filechooser")
local FileManager = require("apps/filemanager/filemanager")
local ButtonDialog = require("ui/widget/buttondialog")
local CheckButton = require("ui/widget/checkbutton")
local Screen = require("device").screen
local Font = require("ui/font")
local Menu = require("ui/widget/menu")
local Geom = require("ui/geometry")
local Size = require("ui/size")
local Blitbuffer = require("ffi/blitbuffer")
local LineWidget = require("ui/widget/linewidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local T = require("ffi/util").template
local util = require("util")
local logger = require("logger")

local Memory = require("foldermemory_config")

local BookList = require("ui/widget/booklist")
local SpinWidget = require("ui/widget/spinwidget")
local DoubleSpinWidget = require("ui/widget/doublespinwidget")

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

local menu = {}

-- Which "items per page" settings apply to a CoverBrowser display mode:
-- the mosaic grid for the mosaic modes, files per page for the list modes,
-- KOReader's own items_per_page for classic. CoverBrowser derives the same
-- value by stripping the suffix off display_mode.
local function displayModeType(mode)
    return (mode or "classic"):gsub("_.*", "") -- "mosaic", "list" or "classic"
end

-- Whether the device is currently held in portrait – the same test CoverBrowser
-- uses to pick between the portrait and landscape mosaic grid.
local function isPortrait()
    return Screen:getWidth() <= Screen:getHeight()
end

-- The CoverBrowser display modes: { mode key, label }. Classic is nil, as it is
-- in CoverBrowser itself (a mode is absent rather than named) – the plugin only
-- spells it "classic" when it stores one in a folder memory.
local DISPLAY_MODES = {
    { nil, _("Classic (filename only)") },
    { "mosaic_image", _("Mosaic with cover images") },
    { "mosaic_text", _("Mosaic with text covers") },
    { "list_image_meta", _("Detailed list with cover images and metadata") },
    { "list_only_meta", _("Detailed list with metadata, no images") },
    { "list_image_filename", _("Detailed list with cover images and filenames") },
}

-- Label of a display mode, accepting both conventions: nil (CoverBrowser) and
-- "classic" (as the plugin stores it in a memory). Unknown values fall back to
-- the classic label, which is the mode KOReader itself falls back to.
local function displayModeLabel(mode)
    if mode == "classic" then mode = nil end
    for _, m in ipairs(DISPLAY_MODES) do
        if m[1] == mode then return m[2] end
    end
    return DISPLAY_MODES[1][2]
end

-- +--------------------------------------------+
-- | Helper: build book status filter submenu   |
-- +--------------------------------------------+

function menu.buildBookStatusMenuTable(self, refresh_fn, save_fn)
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

function menu.buildDisplayModeMenuTable(self, save_fn)
    local sub_item_table = {}
    for _, mode in ipairs(DISPLAY_MODES) do
        local mode_key = mode[1]
        table.insert(sub_item_table, {
            text = mode[2],
            checked_func = function()
                return _BookInfoManager:getSetting("filemanager_display_mode") == mode_key
            end,
            radio = true,
            callback = function()
                local ui = FileManager.instance
                if ui and ui.coverbrowser then
                    ui.coverbrowser:setDisplayMode(mode_key)
                end
                if save_fn then save_fn() end
            end,
        })
    end
    return {
        text_func = function()
            local dm = _BookInfoManager:getSetting("filemanager_display_mode")
            return _("Display mode") .. ": " .. displayModeLabel(dm)
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

function menu.buildDefaultConfigSubmenu(self)
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
        local sub_item_table = {}
        for _, mode in ipairs(DISPLAY_MODES) do
            local mode_key = mode[1]
            table.insert(sub_item_table, {
                text = mode[2],
                checked_func = function()
                    local dm = getDef("display_mode", function()
                        return _BookInfoManager:getSetting("filemanager_display_mode")
                    end)
                    -- a memory spells classic out, CoverBrowser leaves it nil
                    if dm == "classic" then dm = nil end
                    return dm == mode_key
                end,
                radio = true,
                callback = function(touchmenu_instance)
                    saveField("display_mode", mode_key or "classic")
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end
        menu_items.display_mode = {
            text_func = function()
                local dm = getDef("display_mode", function()
                    return _BookInfoManager:getSetting("filemanager_display_mode")
                end)
                return _("Display mode") .. ": " .. displayModeLabel(dm)
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

        -- Unlike the per-folder submenu, the template keeps every entry: it
        -- describes folders as they may be later, so it must not depend on the
        -- display mode or the orientation in effect right now.
    end

    -- Classic display mode uses KOReader's own "Items per page" setting. Offered
    -- by the template like the entries above, whatever the current mode is.
    do
        -- Effective value of the live setting, used as the fallback when the
        -- template carries no value of its own.
        local liveItemsPerPage = function()
            local live = self.ui.file_chooser
            return (live and live.items_per_page) or G_reader_settings:readSetting("items_per_page")
        end
        menu_items.items_per_page_classic = {
            keep_menu_open = true,
            separator = true,
            text_func = function()
                local v = getDef("items_per_page", liveItemsPerPage)
                    or FileChooser.items_per_page_default
                return T(_("Items per page in classic mode: %1"), v)
            end,
            callback = function(touchmenu_instance)
                local default_value = FileChooser.items_per_page_default
                local current_value = getDef("items_per_page", liveItemsPerPage) or default_value
                local widget = SpinWidget:new{
                    title_text = _("Items per page"),
                    value = current_value,
                    value_min = 6,
                    value_max = 30,
                    default_value = default_value,
                    keep_shown_on_apply = true,
                    callback = function(spin)
                        saveField("items_per_page", spin.value)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
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
        "items_per_page_classic",
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
-- "Other views" submenu builder – edits KOReader's and
-- CoverBrowser's GLOBAL settings, the ones History, Favorites,
-- Collections, OPDS, Calibre and search results read.
--
-- Nothing here is saved per folder: every write runs under
-- Memory._editing_global, so the auto-save hooks stay out and the
-- value is not mirrored onto the file chooser either.
-- ============================================================

function menu.buildOtherViewsSubmenu(self)
    -- Set the flag around a write and clear it once the synchronous hooks have
    -- had their chance – the same pattern as editDefault above.
    local function editGlobal(fn)
        Memory._editing_global = true
        fn()
        UIManager:nextTick(function() Memory._editing_global = false end)
    end

    -- CoverBrowser's own entry point: saves the mode and re-patches the view it
    -- belongs to. It is a plain function on the plugin class, hence the dot call.
    local function setViewDisplayMode(widget_id, db_key, mode)
        local coverbrowser = FileManager.instance and FileManager.instance.coverbrowser
        editGlobal(function()
            if coverbrowser and coverbrowser.setupWidgetDisplayMode then
                coverbrowser.setupWidgetDisplayMode(widget_id, mode)
            elseif _hasBookInfoManager then
                _BookInfoManager:saveSetting(db_key, mode)
            end
        end)
    end

    local function buildViewModeSubmenu(widget_id, db_key)
        local sub_item_table = {}
        for _, mode in ipairs(DISPLAY_MODES) do
            local mode_key = mode[1]
            table.insert(sub_item_table, {
                text = mode[2],
                radio = true,
                checked_func = function()
                    return _BookInfoManager:getSetting(db_key) == mode_key
                end,
                callback = function()
                    setViewDisplayMode(widget_id, db_key, mode_key)
                end,
            })
        end
        return sub_item_table
    end

    local fc = self.ui and self.ui.file_chooser

    -- Shared by the grid entries below. They are for the views outside the file
    -- browser; the file browser itself follows the folder's own settings.
    local grid_help = _("Used by the mosaic and detailed-list modes of History, Favorites, Collections and search results. The file browser follows each folder's own settings – Configure this folder – or the default settings for folders. This is a global setting and is not saved per folder.")

    -- KOReader's own classic-mode setting. Unlike the per-folder entry in
    -- "Configure this folder", this writes the global, which is why it is the
    -- only one that reaches OPDS and Calibre – neither uses CoverBrowser.
    -- The two views below it have a display mode of their own, which the file
    -- browser's per-folder mode does not touch. KOReader's "use this mode
    -- everywhere" toggle is not repeated here – it lives next to the mode radios
    -- in Settings → Display mode, where the mode it copies is visible.
    local sub_item_table = {
        {
            keep_menu_open = true,
            separator = true,
            text_func = function()
                local v = G_reader_settings:readSetting("items_per_page")
                    or FileChooser.items_per_page_default
                return T(_("Items per page for other views: %1"), v)
            end,
            help_text = _([[This sets the number of items per page in:
- File browser, history and favorites in 'classic' display mode
- Search results and folder shortcuts
- File and folder selection
- Calibre and OPDS browsers/search results

It is a global setting, not saved per folder, so a folder with a saved value of its own keeps that one.]]),
            callback = function(touchmenu_instance)
                local default_value = FileChooser.items_per_page_default
                local current_value = G_reader_settings:readSetting("items_per_page") or default_value
                local widget = SpinWidget:new{
                    title_text = _("Items per page"),
                    value = current_value,
                    value_min = 6,
                    value_max = 30,
                    default_value = default_value,
                    keep_shown_on_apply = true,
                    callback = function(spin)
                        editGlobal(function()
                            G_reader_settings:saveSetting("items_per_page", spin.value)
                        end)
                        if fc then fc:refreshPath() end
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                }
                UIManager:show(widget)
            end,
        },
    }

    if _hasBookInfoManager then
        -- CoverBrowser's own grid settings. Written to the globals only: the
        -- file browser's copy lives on its instance and is reset per folder.
        local function setGridSetting(key, val)
            editGlobal(function()
                _BookInfoManager:saveSetting(key, val)
                -- CoverBrowser's own menu keeps this class-level copy in step as
                -- well, and it is what a freshly built file chooser falls back to
                -- before the plugin has applied anything – a stale copy here is
                -- what showed an old value until KOReader was restarted.
                FileChooser[key] = val
            end)
        end

        table.insert(sub_item_table, {
            keep_menu_open = true,
            text_func = function()
                local cols = _BookInfoManager:getSetting("nb_cols_portrait") or 3
                local rows = _BookInfoManager:getSetting("nb_rows_portrait") or 3
                return T(_("Items per page in portrait mosaic mode: %1 × %2"), cols, rows)
            end,
            help_text = grid_help,
            callback = function(touchmenu_instance)
                local nb_cols = _BookInfoManager:getSetting("nb_cols_portrait") or 3
                local nb_rows = _BookInfoManager:getSetting("nb_rows_portrait") or 3
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
                        setGridSetting("nb_cols_portrait", left_value)
                        setGridSetting("nb_rows_portrait", right_value)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                }
                UIManager:show(widget)
            end,
        })
        table.insert(sub_item_table, {
            keep_menu_open = true,
            text_func = function()
                local cols = _BookInfoManager:getSetting("nb_cols_landscape") or 4
                local rows = _BookInfoManager:getSetting("nb_rows_landscape") or 2
                return T(_("Items per page in landscape mosaic mode: %1 × %2"), cols, rows)
            end,
            help_text = grid_help,
            callback = function(touchmenu_instance)
                local nb_cols = _BookInfoManager:getSetting("nb_cols_landscape") or 4
                local nb_rows = _BookInfoManager:getSetting("nb_rows_landscape") or 2
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
                        setGridSetting("nb_cols_landscape", left_value)
                        setGridSetting("nb_rows_landscape", right_value)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                }
                UIManager:show(widget)
            end,
        })
        table.insert(sub_item_table, {
            keep_menu_open = true,
            separator = true,
            text_func = function()
                local v = _BookInfoManager:getSetting("files_per_page") or 10
                return T(_("Items per page in portrait list mode: %1"), v)
            end,
            help_text = grid_help,
            callback = function(touchmenu_instance)
                local files_per_page = _BookInfoManager:getSetting("files_per_page") or 10
                local widget = SpinWidget:new{
                    title_text = _("Portrait list mode"),
                    value = files_per_page,
                    value_min = 4,
                    value_max = 20,
                    default_value = 10,
                    keep_shown_on_apply = true,
                    callback = function(spin)
                        setGridSetting("files_per_page", spin.value)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                }
                UIManager:show(widget)
            end,
        })

        -- These two views read a display mode of their own; the file browser's
        -- per-folder mode does not reach them. Greyed out while KOReader's "use
        -- this mode everywhere" is on, which is where they get their mode from.
        table.insert(sub_item_table, {
            text = _("History display mode"),
            help_text = _("Display mode used by the History and Favorites views. Unavailable while KOReader's \"Use this mode everywhere\" is on (Settings → Display mode), since they then follow the file browser's mode."),
            enabled_func = function()
                return not _BookInfoManager:getSetting("unified_display_mode")
            end,
            sub_item_table = buildViewModeSubmenu("history", "history_display_mode"),
        })
        table.insert(sub_item_table, {
            text = _("Collections display mode"),
            help_text = _("Display mode used by the Collections view. Unavailable while KOReader's \"Use this mode everywhere\" is on (Settings → Display mode), since it then follows the file browser's mode."),
            enabled_func = function()
                return not _BookInfoManager:getSetting("unified_display_mode")
            end,
            sub_item_table = buildViewModeSubmenu("collections", "collection_display_mode"),
        })
    end

    return sub_item_table
end

-- ============================================================
-- Config submenu builder – returns a table of menu items
-- ============================================================

function menu.buildConfigSubmenu(self)
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
        -- a line under the sort order itself, above the options that refine it
        separator = true,
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
    menu_items.book_status = menu.buildBookStatusMenuTable(self, refresh, saveFolderSettings)
    menu_items.book_status.separator = true
    -- Several statuses can be on at once, so its choice list stays open
    menu_items.book_status.multi_select = true

    -- +--------------------+
    -- | 5. Display mode    |
    -- +--------------------+
    if _hasBookInfoManager then
        menu_items.display_mode = menu.buildDisplayModeMenuTable(self, saveFolderSettings)
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
                        -- Only the file chooser instance is written: the global
                        -- CoverBrowser settings are shared with Collections,
                        -- History and the file searcher.
                        saveFolderSettings()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                    close_callback = function()
                        if fc.nb_cols_portrait ~= nb_cols or fc.nb_rows_portrait ~= nb_rows then
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
                        -- Instance only – see the portrait mosaic item above.
                        saveFolderSettings()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                    close_callback = function()
                        if fc.nb_cols_landscape ~= nb_cols or fc.nb_rows_landscape ~= nb_rows then
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
                        -- Instance only – see the portrait mosaic item above.
                        saveFolderSettings()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                    close_callback = function()
                        if fc.files_per_page ~= files_per_page_val then
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

        -- Offer only the "items per page" entries that apply to the current
        -- display mode and to the orientation the device is held in: mosaic
        -- grid for the mosaic modes, files per page for the list modes.
        -- Classic mode has its own entry instead, built further down.
        local mode_type = displayModeType(_BookInfoManager:getSetting("filemanager_display_mode"))
        if mode_type == "mosaic" then
            if isPortrait() then
                menu_items.mosaic_landscape_grid = nil
            else
                menu_items.mosaic_portrait_grid = nil
            end
        else
            menu_items.mosaic_portrait_grid = nil
            menu_items.mosaic_landscape_grid = nil
        end
        if mode_type ~= "list" then
            menu_items.files_per_page = nil
        end
    end

    -- Classic display mode: KOReader's "Items per page" setting. The per-folder
    -- value is kept as an override on the file chooser instance, never in the
    -- global setting – Collections, OPDS and search results read the global one
    -- and would otherwise inherit the settings of the last folder visited.
    local classic_mode = true
    if _hasBookInfoManager then
        classic_mode = displayModeType(_BookInfoManager:getSetting("filemanager_display_mode")) == "classic"
    end
    if classic_mode then
        local fc = self.ui.file_chooser
        local function currentValue()
            return fc.items_per_page or G_reader_settings:readSetting("items_per_page")
                or FileChooser.items_per_page_default
        end
        menu_items.items_per_page_classic = {
            keep_menu_open = true,
            separator = true,
            text_func = function()
                return T(_("Items per page in classic mode: %1"), currentValue())
            end,
            callback = function(touchmenu_instance)
                local widget = SpinWidget:new{
                    title_text = _("Items per page"),
                    value = currentValue(),
                    value_min = 6,
                    value_max = 30,
                    default_value = FileChooser.items_per_page_default,
                    keep_shown_on_apply = true,
                    callback = function(spin)
                        fc.items_per_page = spin.value
                        saveFolderSettings()
                        refresh()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
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
        "items_per_page_classic",
        "clear_settings",
    }
    local sub_item_table = {}
    for _, id in ipairs(order) do
        if menu_items[id] then
            table.insert(sub_item_table, menu_items[id])
        end
    end

    -- A line above "Clear saved settings", drawn under whichever entry happens
    -- to precede it: the items-per-page rows above it depend on the display mode
    -- and on the orientation, so which one is last is not fixed.
    if #sub_item_table > 1 then
        sub_item_table[#sub_item_table - 1].separator = true
    end

    return sub_item_table
end

-- ============================================================
-- Standalone config window
--
-- Opened by the "Configure this folder" menu item and by the Dispatcher
-- action, so a gesture can reach it too. The item table built by
-- buildConfigSubmenu is rendered as dialog buttons: items with a
-- sub_item_table open a second window holding the choices, the others
-- run their callback in place.
-- ============================================================

-- Text of a TouchMenu-style item; used for the titles of the choice windows.
-- The buttons themselves get the item's text_func, which Button re-evaluates.
local function itemText(item)
    return item.text_func and item.text_func() or item.text
end

function menu.showConfigMenu(self)
    local fc = self.ui and self.ui.file_chooser
    if not fc or not fc.path then
        -- The action is classified as "filemanager", but gestures are global:
        -- the same gesture can also fire in the reader, where there is no folder.
        UIManager:show(InfoMessage:new{
            text = _("Folder memory: open a folder in the file browser first."),
        })
        return
    end

    -- Windows on screen: the settings one, plus the choice list opened from it.
    local main, picker
    local showWindow, showMain, built_state
    local refresh_scheduled = false

    -- Which "items per page" entries the window holds depends on the display
    -- mode and on the orientation, so both are part of the state it was built for.
    local function currentState()
        local mode = "classic"
        if _hasBookInfoManager then
            mode = _BookInfoManager:getSetting("filemanager_display_mode") or "classic"
        end
        return mode .. (isPortrait() and "|portrait" or "|landscape")
    end

    -- The callbacks below were written for TouchMenu: they expect to be handed
    -- the menu instance and may call updateItems() on it. Redraw on the next
    -- event loop tick, so the button handling the tap is not freed under its
    -- own feet (Button keeps painting itself after the callback returns).
    local function refresh()
        if refresh_scheduled then return end
        refresh_scheduled = true
        UIManager:nextTick(function()
            refresh_scheduled = false
            local redrawn = false
            if main and not main.closed then
                if built_state ~= currentState() then
                    -- The display mode or the orientation changed, and with it
                    -- which "items per page" entries apply: rebuild the window.
                    showMain()
                else
                    main.rebuild()
                end
                redrawn = true
            end
            if picker and not picker.closed then
                picker.rebuild()
                redrawn = true
            end
            if redrawn then
                -- A rebuilt window can be a different height – a label may now
                -- wrap – so repaint every window instead of just this one.
                UIManager:setDirty("all", "ui")
            end
        end)
    end

    local proxy = {
        updateItems = refresh,
        closeMenu = function() end,
    }

    showWindow = function(title, items, is_picker, multi_select)
        local entry = { closed = false }

        local function dismiss()
            if entry.closed then return end
            entry.closed = true
            UIManager:close(entry.dialog)
            if main == entry then main = nil end
            if picker == entry then picker = nil end
        end

        -- Rows are widgets, not dialog buttons: a button holds text only, while
        -- CheckButton carries the mark the menu uses – a CheckMark for toggles,
        -- a RadioMark for single choices, and an empty slot of the same width
        -- when the row has neither, so every label starts at the same place.
        -- It also highlights on tap and supports a hold callback.
        local dialog
        local function buildRows()
            local row_width = dialog:getAddedWidgetAvailableWidth()
            local vgroup = VerticalGroup:new{ align = "center" }
            for _, item in ipairs(items) do
                table.insert(vgroup, CheckButton:new{
                    parent = dialog,
                    width = row_width,
                    face = Font:getFace("smallinfofont"),
                    -- KOReader's own label, with the ▸ arrow on the entries that
                    -- open a sub-list
                    text = Menu.getMenuText(item),
                    checkable = item.checked_func ~= nil,
                    radio = item.radio or false,
                    checked = item.checked_func ~= nil and item.checked_func() or false,
                    enabled = item.enabled_func == nil or item.enabled_func() ~= false,
                    callback = function()
                        if item.sub_item_table then
                            picker = showWindow(itemText(item), item.sub_item_table, true, item.multi_select)
                        elseif item.callback then
                            item.callback(proxy)
                            if is_picker and not multi_select then
                                -- A single-choice list is done with; a multi-select
                                -- one stays open so several can be picked in a row.
                                dismiss()
                            end
                            -- the settings window below shows the value just changed
                            refresh()
                        end
                    end,
                    hold_callback = item.hold_callback and function()
                        item.hold_callback(proxy)
                        refresh()
                    end or nil,
                })
                if item.separator then
                    table.insert(vgroup, VerticalSpan:new{ width = Size.padding.default })
                    table.insert(vgroup, LineWidget:new{
                        dimen = Geom:new{ w = row_width, h = Size.line.medium },
                        background = Blitbuffer.COLOR_GRAY,
                    })
                    table.insert(vgroup, VerticalSpan:new{ width = Size.padding.default })
                end
            end
            return vgroup
        end

        dialog = ButtonDialog:new{
            title = title,
            title_align = "center",
            use_info_style = false,
            -- ButtonDialog measures its content width off its buttons, so this
            -- one is not just convenient: with no buttons the rows above would
            -- be laid out at a width of zero.
            buttons = { {
                {
                    text = _("Close"),
                    callback = function() dismiss() end,
                },
            } },
            -- the window can also be dismissed by tapping outside of it
            tap_close_callback = function()
                entry.closed = true
                if main == entry then main = nil end
                if picker == entry then picker = nil end
            end,
        }
        dialog:addWidget(buildRows())

        -- Redraw in place. The rows read the values they stand for when they are
        -- built, so a redraw means building them again – and swapping them in
        -- directly, since addWidget() can only ever append.
        entry.rebuild = function()
            if entry.closed then return end
            dialog._added_widgets = { buildRows() }
            dialog:reinit()
        end

        entry.dialog = dialog
        UIManager:show(dialog)
        return entry
    end

    -- (Re)build the settings window from the current state. The item table is
    -- built anew because the display mode decides which entries it holds.
    showMain = function()
        if main and not main.closed then
            main.closed = true
            UIManager:close(main.dialog)
            main = nil
        end
        built_state = currentState()
        main = showWindow(T(_("Folder memory: %1"), fc.path), menu.buildConfigSubmenu(self), false)
    end

    showMain()
end

-- ============================================================
-- Menu
-- ============================================================

function menu.addToMainMenu(self, menu_items)
    -- Only add menu when in file manager context
    if not self.ui.file_chooser then return end

    local fc = self.ui.file_chooser
    local path = fc.path

    menu_items.folder_memory = {
        text = _("Folder memory"),
        sub_item_table = {},
    }

    -- Config this folder – opens the same popup window the gesture action does
    table.insert(menu_items.folder_memory.sub_item_table, {
        text = _("Configure this folder"),
        enabled_func = function()
            return self.ui.file_chooser and self.ui.file_chooser.path ~= nil
        end,
        callback = function()
            menu.showConfigMenu(self)
        end,
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

    -- Fallback for folders that have nothing of their own. Deliberately not
    -- called "default settings": it is not a global default, and the group below
    -- is. Own function – never touches KOReader live state.
    table.insert(menu_items.folder_memory.sub_item_table, {
        text = _("Default settings for folders"),
        separator = true,
        help_text = _("Fallback for folders that have no saved settings of their own – and, with inheritance on, no parent folder with any either. It changes what folders do only: KOReader's global settings are left as they are, so History, Collections, OPDS and search results are not affected."),
        sub_item_table = menu.buildDefaultConfigSubmenu(self),
    })

    -- KOReader's/CoverBrowser's own global settings, the ones the views outside
    -- the file browser read. Not saved per folder – see the builder.
    table.insert(menu_items.folder_memory.sub_item_table, {
        text = _("Global settings for other views"),
        separator = true,
        help_text = _("These change KOReader's global settings – the ones History, Favorites, Collections, OPDS, Calibre and search results read. They are not saved per folder."),
        sub_item_table = menu.buildOtherViewsSubmenu(self),
    })

    -- Clear all folder memory
    table.insert(menu_items.folder_memory.sub_item_table, {
        text = _("Clear all saved folder settings"),
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = _("Clear all saved folder settings? The default settings for folders will be kept."),
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
function menu.insertMenuOrder()
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

return menu