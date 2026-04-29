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

local Dispatcher = require("dispatcher")
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
    self:onDispatcherRegisterActions()
    self:_setupHooks()
    logger.dbg("FolderMemory: plugin loaded – per-folder sort/display/filter/grid memory enabled")
end

-- ============================================================
-- Hooki – refreshPath do przywracania pamięci
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
    -- Helper: apply folder memory for a given path, but only if
    -- the path actually changed.
    -- ============================================================
    local function applyMemoryIfNeeded(path)
        if path and path ~= lastAppliedPath then
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
end

-- ============================================================
-- Dispatcher actions – available as gestures / profiles
-- ============================================================

function FolderMemory:onDispatcherRegisterActions()
    Dispatcher:registerAction("save_folder_memory", {
        category = "none",
        event = "SaveFolderMemory",
        title = _("FolderMemory: save settings for current folder"),
        filemanager = true,
    })
    Dispatcher:registerAction("clear_folder_memory", {
        category = "none",
        event = "ClearFolderMemory",
        title = _("FolderMemory: clear settings for current folder"),
        filemanager = true,
    })
    Dispatcher:registerAction("config_folder_memory", {
        category = "none",
        event = "ConfigFolderMemory",
        title = _("FolderMemory: configure this folder"),
        filemanager = true,
    })
end

function FolderMemory:onSaveFolderMemory()
    local path = self.ui.file_chooser and self.ui.file_chooser.path
    if not path then
        UIManager:show(InfoMessage:new{
            text = _("This action is only available in File browser."),
        })
        return
    end
    local current = Memory.captureCurrentSettings()
    Memory.saveFolderMemory(path, current)
    UIManager:show(InfoMessage:new{
        text = _("Settings saved for this folder."),
    })
end

function FolderMemory:onClearFolderMemory()
    local path = self.ui.file_chooser and self.ui.file_chooser.path
    if not path then
        UIManager:show(InfoMessage:new{
            text = _("This action is only available in File browser."),
        })
        return
    end
    Memory.clearFolder(path)
    UIManager:show(InfoMessage:new{
        text = _("Folder settings cleared."),
    })
end

function FolderMemory:onConfigFolderMemory()
    local fc = self.ui.file_chooser
    local path = fc and fc.path
    if not path then
        UIManager:show(InfoMessage:new{
            text = _("This action is only available in File browser."),
        })
        return
    end
    self:_showConfigDialog(path)
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
        { _("Classic (filename only)"), nil },
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
                return current == mode_key
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
            local names = {
                mosaic_image = _("Mosaic with cover images"),
                mosaic_text = _("Mosaic with text covers"),
                list_image_meta = _("Detailed list with cover images and metadata"),
                list_only_meta = _("Detailed list with metadata, no images"),
                list_image_filename = _("Detailed list with cover images and filenames"),
            }
            return T(_("Display mode: %1"), names[dm] or _("Classic"))
        end,
        sub_item_table = sub_item_table,
    }
end

-- ============================================================
-- Config submenu builder – returns a table of menu items
-- ============================================================

function FolderMemory:_buildConfigSubmenu(path, submenu_mode)
    local menu_items = {}

    -- Helper: refresh FileChooser after changes
    local function refresh()
        if self.ui and self.ui.file_chooser then
            self.ui.file_chooser:refreshPath()
        end
    end

    -- Helper: save current state to folder memory
    local function saveFolderSettings()
        local current = Memory.captureCurrentSettings()
        Memory.saveFolderMemory(path, current)
    end

    -- Helper: clear folder memory for this path
    local function clearFolderSettings()
        Memory.clearFolder(path)
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
            separator = true,
        }
        -- Files per page (list mode)
        menu_items.files_per_page = {
            keep_menu_open = true,
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
    -- | 7. Save / Clear buttons           |
    -- +-----------------------------------+
    menu_items.save_settings = {
        text = _("Save current settings for this folder"),
        separator = true,
        callback = function()
            saveFolderSettings()
            UIManager:show(InfoMessage:new{
                text = _("Settings saved for this folder."),
            })
        end,
    }

    menu_items.clear_settings = {
        text = _("Clear saved settings for this folder"),
        enabled_func = function()
            return Memory.hasOwnSettings(path)
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

    -- "Close" item only meaningful in standalone dialog mode,
    -- not when used as a nested submenu (user simply goes back).
    if submenu_mode then
        menu_items.close_dialog = {
            text = _("Close"),
            separator = true,
            keep_menu_open = false,
            callback = function(touchmenu_instance)
                touchmenu_instance:closeMenu()
            end,
        }
    end

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
        "save_settings",
        "clear_settings",
        "close_dialog",
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
-- Standalone config dialog (for dispatcher / gesture use)
-- ============================================================

function FolderMemory:_showConfigDialog(path)
    local Menu = require("ui/widget/menu")
    local Screen = require("device").screen

    local sub_item_table = self:_buildConfigSubmenu(path, "dialog")

    local menu_widget = Menu:new{
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        title = _("Configure folder"),
        item_table = sub_item_table,
        is_popout = true,
        close_callback = function()
            if self.ui and self.ui.file_chooser then
                self.ui.file_chooser:refreshPath()
            end
        end,
    }

    UIManager:show(menu_widget)
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
        separator = true,
        sub_item_table = self:_buildConfigSubmenu(self.ui.file_chooser.path),
    })

    -- Save / Update settings for this folder
    table.insert(menu_items.folder_memory.sub_item_table, {
        text_func = function()
            if not self.ui.file_chooser or not self.ui.file_chooser.path then
                return _("Save current settings for this folder")
            end
            if Memory.hasOwnSettings(self.ui.file_chooser.path) then
                return _("Update settings for this folder")
            else
                return _("Save current settings for this folder")
            end
        end,
        enabled_func = function()
            return self.ui.file_chooser and self.ui.file_chooser.path ~= nil
        end,
        callback = function()
            if not self.ui.file_chooser or not self.ui.file_chooser.path then return end
            local current = Memory.captureCurrentSettings()
            Memory.saveFolderMemory(self.ui.file_chooser.path, current)
            UIManager:show(InfoMessage:new{
                text = _("Settings saved for this folder."),
            })
            -- Update menu to show the new status
            self.ui:onRefresh()
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

    -- Save / Update current settings as default
    table.insert(menu_items.folder_memory.sub_item_table, {
        text_func = function()
            if Memory.hasOwnSettings("__default__") then
                return _("Update default settings")
            else
                return _("Save current settings as default")
            end
        end,
        callback = function()
            Memory.saveAsDefault()
            UIManager:show(InfoMessage:new{
                text = _("Default settings saved."),
            })
            self.ui:onRefresh()
        end,
    })

    -- Clear all folder memory
    table.insert(menu_items.folder_memory.sub_item_table, {
        text = _("Clear all folder memory"),
        separator = true,
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

    -- Clear all including defaults
    table.insert(menu_items.folder_memory.sub_item_table, {
        text = _("Clear all folder memory (including defaults)"),
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = _("Clear ALL folder settings including the default template?"),
                ok_text = _("Clear everything"),
                ok_callback = function()
                    Memory.clearAll(false)
                    UIManager:show(InfoMessage:new{
                        text = _("All folder memory cleared (including defaults)."),
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
