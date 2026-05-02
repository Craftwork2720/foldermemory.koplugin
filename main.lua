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
- Przy wejściu do folderu: przywraca zapisane ustawienia (foldermemory_hooks)
- Zapis TYLKO ręczny – użytkownik wybiera "Save current settings for this folder"
- Opcja "Save current settings as default" – szablon dla folderów bez pamięci
- Menu wtyczki w file browser settings (foldermemory_menu)

Zarządzanie:
- Menu wtyczki w file browser settings
- Zapisz bieżące ustawienia jako domyślne dla folderów bez pamięci
- Wyczyść pamięć dla bieżącego folderu
- Wyczyść całą pamięć folderów
--]]

local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local FileChooser = require("ui/widget/filechooser")
local FileManager = require("apps/filemanager/filemanager")
local logger = require("logger")

local Memory = require("memory")
local hooks = require("foldermemory_hooks")
local menu = require("foldermemory_menu")

local FolderMemory = WidgetContainer:extend{
    name = "foldermemory",
    is_doc_only = false,
}

function FolderMemory:init()
    -- Initialize Memory module (loads settings once, checks optional modules)
    Memory.init()
    self.ui.menu:registerToMainMenu(self)
    hooks.setupHooks()
    logger.dbg("FolderMemory: plugin loaded – per-folder sort/display/filter/grid memory enabled")
end

-- ============================================================
-- Menu delegation – przypięcie metod z foldermemory_menu
-- ============================================================

FolderMemory._buildBookStatusMenuTable = menu.buildBookStatusMenuTable
FolderMemory._buildDisplayModeMenuTable = menu.buildDisplayModeMenuTable
FolderMemory._buildDefaultConfigSubmenu = menu.buildDefaultConfigSubmenu
FolderMemory._buildConfigSubmenu = menu.buildConfigSubmenu
FolderMemory.addToMainMenu = menu.addToMainMenu

-- ============================================================
-- Menu order – wstaw folder_memory po sort_mixed
-- ============================================================

menu.insertMenuOrder()

return FolderMemory