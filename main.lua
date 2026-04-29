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

    -- Current folder path (info only, not clickable, dimmed)
    table.insert(menu_items.folder_memory.sub_item_table, {
        text_func = function()
            if not self.ui.file_chooser or not self.ui.file_chooser.path then
                return _("(none)")
            end
            local p = self.ui.file_chooser.path
            -- Shorten for display
            if #p > 60 then
                p = "..." .. p:sub(-57)
            end
            local has_own = Memory.hasOwnSettings(self.ui.file_chooser.path)
            local status = has_own and _("✓") or _("✗")
            return T("%1  %2", p, status)
        end,
        dim = true,
        enabled_func = function() return false end,
        separator = true,
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
