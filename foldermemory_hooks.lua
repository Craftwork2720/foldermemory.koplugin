--[[
foldermemory_hooks.lua – hooki do przywracania i auto-zapisu ustawień per folder
Wydzielone z main.lua dla czytelności.
--]]

local UIManager = require("ui/uimanager")
local FileChooser = require("ui/widget/filechooser")
local FileManager = require("apps/filemanager/filemanager")
local logger = require("logger")

local Memory = require("foldermemory_config")

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

    -- ============================================================
    -- Core auto-save: capture + persist current settings for the
    -- active folder.  Always called via nextTick so the original
    -- setter has fully finished before we snapshot state.
    -- ============================================================
    local function autoSave()
        if _applying then return end
        if Memory._editing_default then return end
        if Memory._editing_global then return end
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
        if Memory._editing_global then return end
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
    -- Returns true when a memory was applied, so a caller that had to defer the
    -- apply can tell whether the list needs drawing again.
    local function applyMemoryIfNeeded(path)
        if _applying then return false end
        if path and path ~= lastAppliedPath then
            lastAppliedPath = path
            local mem = Memory.getFolderMemory(path)
            -- Called even when there is no memory for this folder: it also
            -- clears the per-folder items-per-page override, so the folder
            -- falls back to KOReader's global value.
            Memory.applyFolderMemory(mem)
            return true
        end
        return false
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

    -- Draw the file list again after an apply that had to be deferred. The list
    -- was drawn while the *previous* settings were still in effect, so without
    -- this the folder shown at startup would keep them until the next
    -- navigation. The raw original is called: this is only a redraw.
    local function redrawFileChooser()
        local fm = FileManager.instance
        local fc = fm and fm.file_chooser
        if not fc then return end
        local ok, err = pcall(orig_refreshPath, fc)
        if not ok then
            logger.warn("FolderMemory: redraw after startup apply failed:", err)
        end
    end

    FileChooser.refreshPath = function(self)
        if self.name == "filemanager" then
            local path = self.path
            if not _startup_done then
                UIManager:nextTick(function()
                    _startup_done = true
                    if applyMemoryIfNeeded(path) then
                        redrawFileChooser()
                    end
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
                    if applyMemoryIfNeeded(path) then
                        redrawFileChooser()
                    end
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
    -- Hook 3: G_reader_settings – collate / reverse / mixed /
    -- items per page (classic display mode)
    -- --------------------------------------------------------
    local _gs_watch       = { collate = true, items_per_page = true }
    local _boolean_watch  = { reverse_collate = true, collate_mixed = true }

    local orig_gs_save = G_reader_settings.saveSetting
    G_reader_settings.saveSetting = function(self, key, val, ...)
        orig_gs_save(self, key, val, ...)
        if _gs_watch[key] and not Memory._editing_global then
            if key == "items_per_page" then
                -- The plugin keeps the per-folder value as an override on the
                -- file chooser, so a change made from KOReader's own classic
                -- settings menu has to be mirrored onto it – otherwise that
                -- override would shadow the change for the current folder.
                -- Skipped for the plugin's own "Items per page for other views"
                -- item, which sets the flag precisely to stay global.
                local fm = FileManager.instance
                if fm and fm.file_chooser then
                    fm.file_chooser.items_per_page = val
                end
            end
            scheduleAutoSave()
        end
    end

    local orig_gs_flip = G_reader_settings.flipNilOrFalse
    if orig_gs_flip then
        G_reader_settings.flipNilOrFalse = function(self, key, ...)
            orig_gs_flip(self, key, ...)
            if _boolean_watch[key] and not Memory._editing_global then
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
                -- No need to mirror the value onto the file chooser: CoverBrowser's
                -- own menu already sets it there before saving it here, and the
                -- auto-save below then captures it from the instance.
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

end

return hooks
