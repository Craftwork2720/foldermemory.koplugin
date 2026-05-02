--[[
foldermemory_hooks.lua – hooki do przywracania i auto-zapisu ustawień per folder
Wydzielone z main.lua dla czytelności.
--]]

local UIManager = require("ui/uimanager")
local FileChooser = require("ui/widget/filechooser")
local FileManager = require("apps/filemanager/filemanager")
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

local hooks = {}

--- Główna funkcja instalująca wszystkie hooki.
function hooks.setupHooks()
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
    -- the path actually changed (or _force_apply is set).
    -- ============================================================
    local function applyMemoryIfNeeded(path)
        if _applying then return end
        if path and (path ~= lastAppliedPath or _force_apply) then
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

    local _lastFilterFP = filterFingerprint()

    -- Reset fingerprint after every apply so Hook 5 won't fire.
    local orig_apply_wrapped = Memory.applyFolderMemory
    Memory.applyFolderMemory = function(mem)
        orig_apply_wrapped(mem)
        _lastFilterFP = filterFingerprint()
    end

    -- Second wrapper around FileChooser.refreshPath (wraps Hook 1's version).
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
    -- Virtual views (History, Favorites, Collections)
    -- ============================================================

    -- Called when entering a virtual view:
    -- applies __default__ and resets tracking so the real folder's
    -- settings will be re-applied on return.
    local function onEnterVirtualView()
        _force_apply = true
        lastAppliedPath = nil
        Memory.applyDefaultMemory()
    end

    -- Called when a virtual view widget closes:
    -- forces Hook 1 to re-apply the real folder's memory by
    -- calling refreshPath with tracking flags reset.
    local function onExitVirtualView()
        UIManager:nextTick(function()
            local fm = FileManager.instance
            if not fm or not fm.file_chooser then return end
            local path = fm.file_chooser.path
            if not path then return end
            -- Reset tracking – Hook 1 (via refreshPath) will pick this up
            -- and call applyMemoryIfNeeded BEFORE re-rendering the list,
            -- ensuring G_reader_settings + CoverBrowser are up-to-date.
            lastAppliedPath = nil
            _force_apply = true
            local ok, err = pcall(function()
                fm.file_chooser:refreshPath()
            end)
            if not ok then
                logger.warn("FolderMemory: onExitVirtualView refreshPath failed:", err)
            end
        end)
    end

    -- Wrap a widget's close points so onExitVirtualView fires when
    -- the virtual view is dismissed.  Tries both close_callback
    -- (Menu-style) and the onClose method (Widget-style).
    local function hookWidgetClose(widget)
        if not widget then return end
        -- close_callback (preferred – used by KOReader's Menu widget)
        if type(widget.close_callback) == "function" then
            local orig_cb = widget.close_callback
            widget.close_callback = function(...)
                orig_cb(...)
                onExitVirtualView()
            end
        end
        -- onClose method (fallback for other widget types)
        if type(widget.onClose) == "function" then
            local orig_onClose = widget.onClose
            widget.onClose = function(w, ...)
                local r = orig_onClose(w, ...)
                onExitVirtualView()
                return r
            end
        end
    end

    -- --------------------------------------------------------
    -- History: onShowHist
    -- Uses self.booklist_menu (BookList widget).
    -- --------------------------------------------------------
    local FileManagerHistory = require("apps/filemanager/filemanagerhistory")
    if FileManagerHistory then
        local orig_onShowHist = FileManagerHistory.onShowHist
        FileManagerHistory.onShowHist = function(self, ...)
            onEnterVirtualView()
            if orig_onShowHist then
                orig_onShowHist(self, ...)
            end
            hookWidgetClose(self.booklist_menu)
        end
    end

    -- --------------------------------------------------------
    -- Collections: onShowColl / onShowCollList
    -- onShowColl also covers Favorites (default collection) –
    -- there is no separate Favorites module.
    -- onShowColl     → self.booklist_menu (BookList)
    -- onShowCollList → self.coll_list (Menu with collection list)
    -- --------------------------------------------------------
    local FileManagerCollection = require("apps/filemanager/filemanagercollection")
    if FileManagerCollection then
        local orig_onShowColl = FileManagerCollection.onShowColl
        FileManagerCollection.onShowColl = function(self, ...)
            onEnterVirtualView()
            if orig_onShowColl then
                orig_onShowColl(self, ...)
            end
            hookWidgetClose(self.booklist_menu)
        end

        local orig_onShowCollList = FileManagerCollection.onShowCollList
        FileManagerCollection.onShowCollList = function(self, ...)
            onEnterVirtualView()
            if orig_onShowCollList then
                orig_onShowCollList(self, ...)
            end
            hookWidgetClose(self.coll_list)
        end
    end
end

return hooks
