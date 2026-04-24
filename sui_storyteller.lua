local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local T = require("ffi/util").template
local _ = require("gettext")
local logger = require("logger")

local UI = require("sui_core")

local M = {}
M._instance = nil

local function _showInfo(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 3 })
end

local function _loadST()
    local st = {}
    local mods = {
        api = "st_api",
        config = "st_config",
        downloader = "st_downloader",
        http = "st_http",
        log = "st_log",
        models = "st_models",
    }
    for key, name in pairs(mods) do
        local ok, mod = pcall(require, name)
        if not ok then
            logger.warn("simpleui storyteller: missing module", name, "-", tostring(mod))
            return nil
        end
        st[key] = mod
    end
    return st
end

local function _liveSTPlugin()
    local FM = package.loaded["apps/filemanager/filemanager"]
    local fm = FM and FM.instance
    if not fm then return nil end
    if fm.storyteller then return fm.storyteller end
    if type(fm.plugins) == "table" then
        for __, p in ipairs(fm.plugins) do
            if p and p.name == "storyteller" then
                return p
            end
        end
    end
    return nil
end

local function _storytellerContext(st)
    local st_plugin = _liveSTPlugin()
    if st_plugin and st_plugin.config and st_plugin.api and st_plugin.downloader then
        return {
            plugin = st_plugin,
            config = st_plugin.config,
            api = st_plugin.api,
            downloader = st_plugin.downloader,
            models = st.models,
        }
    end

    local config = st.config:open()
    st.log:setConfig(config)
    local http = st.http:new(config, st.log)
    local api = st.api:new(http)
    local plugin_stub = {
        config = config,
        api = api,
        log = st.log,
    }
    return {
        plugin = plugin_stub,
        config = config,
        api = api,
        downloader = st.downloader:new(plugin_stub),
        models = st.models,
    }
end

local function _copyList(list)
    local out = {}
    for __, item in ipairs(list or {}) do
        table.insert(out, item)
    end
    return out
end

local function _normalizeName(value, fallback)
    if value and value ~= "" then
        return value
    end
    return fallback
end

local function _buildAuthors(book)
    local names = {}
    for __, author in ipairs(book.authors or {}) do
        if author.name then
            table.insert(names, author.name)
        end
    end
    if #names == 0 then
        return nil
    end
    return table.concat(names, ", ")
end

local function _countLabel(count)
    if count == 1 then
        return _("1 book")
    end
    return T(_("%1 books"), count or 0)
end

local function _getDownloadedBadge(ctx, book)
    local preferred = ctx.config:get("preferred_format", "ebook")
    local format = ctx.models.selectFormat(book, preferred)
    if not format then
        return ""
    end
    local __, state = ctx.downloader:findExisting(book, format, ctx.downloader:defaultDir())
    if state == "fresh" then
        return " [" .. _("Downloaded") .. "]"
    end
    return ""
end

local function _sortByTitle(items, key_name)
    table.sort(items, function(a, b)
        local left = key_name and a[key_name] or a
        local right = key_name and b[key_name] or b
        local left_name = (left and left.name) or (left and left.title) or ""
        local right_name = (right and right.name) or (right and right.title) or ""
        return left_name:lower() < right_name:lower()
    end)
    return items
end

function M.show()
    local st = _loadST()
    if not st then
        _showInfo(_("Storyteller plugin is not installed or enabled."))
        return
    end

    local ctx = _storytellerContext(st)
    ctx.config:repairAuthState()

    if not ctx.config:isLoggedIn() then
        _showInfo(_("Link your Storyteller account first (Tools -> Storyteller)."))
        return
    end

    if M._instance then
        pcall(function() UIManager:close(M._instance) end)
        M._instance = nil
    end

    local state = {
        books = nil,
        collections = nil,
        series = nil,
        stack = {},
        loaded = false,
    }

    local menu

    local function getBooksForCollection(collection_uuid)
        local filtered = {}
        for __, book in ipairs(state.books or {}) do
            for ___, collection in ipairs(book.collections or {}) do
                if collection.uuid == collection_uuid then
                    table.insert(filtered, book)
                    break
                end
            end
        end
        return filtered
    end

    local function getBooksForSeries(series_uuid)
        local filtered = {}
        for __, book in ipairs(state.books or {}) do
            for ___, relation in ipairs(book.series or {}) do
                if relation.uuid == series_uuid then
                    table.insert(filtered, book)
                    break
                end
            end
        end
        return filtered
    end

    local function getCurrentlyReadingBooks()
        local filtered = {}
        for __, book in ipairs(state.books or {}) do
            if book.status and book.status.name == "Reading" then
                table.insert(filtered, book)
            end
        end

        table.sort(filtered, function(a, b)
            local ts_a = a.position and a.position.timestamp or 0
            local ts_b = b.position and b.position.timestamp or 0
            if ts_a ~= ts_b then
                return ts_a > ts_b
            end
            return (a.title or ""):lower() < (b.title or ""):lower()
        end)

        return filtered
    end

    local function getBookCreatedAtValue(book)
        if not book or not book.createdAt then
            return 0
        end

        local parsed = os.time({
            year = tonumber(string.sub(book.createdAt, 1, 4)),
            month = tonumber(string.sub(book.createdAt, 6, 7)),
            day = tonumber(string.sub(book.createdAt, 9, 10)),
            hour = tonumber(string.sub(book.createdAt, 12, 13)),
            min = tonumber(string.sub(book.createdAt, 15, 16)),
            sec = tonumber(string.sub(book.createdAt, 18, 19)),
        })

        return parsed or 0
    end

    local function getRecentlyAddedBooks()
        local books = _copyList(state.books or {})
        table.sort(books, function(a, b)
            local created_a = getBookCreatedAtValue(a)
            local created_b = getBookCreatedAtValue(b)
            if created_a ~= created_b then
                return created_a > created_b
            end
            return (a.title or ""):lower() < (b.title or ""):lower()
        end)
        return books
    end

    local function getSeriesRelation(book, series_uuid)
        for __, relation in ipairs(book.series or {}) do
            if relation.uuid == series_uuid then
                return relation
            end
        end
        return nil
    end

    local function sortSeriesBooks(series_uuid, books)
        table.sort(books, function(a, b)
            local rel_a = getSeriesRelation(a, series_uuid) or {}
            local rel_b = getSeriesRelation(b, series_uuid) or {}
            local pos_a = tonumber(rel_a.position)
            local pos_b = tonumber(rel_b.position)

            if pos_a ~= nil and pos_b ~= nil and pos_a ~= pos_b then
                return pos_a < pos_b
            end
            if pos_a ~= nil and pos_b == nil then
                return true
            end
            if pos_a == nil and pos_b ~= nil then
                return false
            end
            return (a.title or ""):lower() < (b.title or ""):lower()
        end)
        return books
    end

    local function buildBackItem()
        return {
            text = _("Back"),
            back = true,
        }
    end

    local function buildBookItems(books)
        local items = { buildBackItem() }
        for __, book in ipairs(books or {}) do
            table.insert(items, {
                text = _normalizeName(book.title, _("Untitled")) .. _getDownloadedBadge(ctx, book),
                mandatory = _buildAuthors(book),
                book = book,
            })
        end
        if #(books or {}) == 0 then
            table.insert(items, {
                text = _("No downloadable books found."),
                dim = true,
            })
        end
        return items
    end

    local function buildCollectionItems()
        local items = { buildBackItem() }
        local collections = _copyList(state.collections or {})
        _sortByTitle(collections)
        for __, collection in ipairs(collections) do
            table.insert(items, {
                text = _normalizeName(collection.name, _("Untitled")),
                mandatory = _countLabel(#getBooksForCollection(collection.uuid)),
                collection = collection,
            })
        end
        if #collections == 0 then
            table.insert(items, { text = _("No collections found."), dim = true })
        end
        return items
    end

    local function buildSeriesItems()
        local items = { buildBackItem() }
        local series = _copyList(state.series or {})
        _sortByTitle(series)
        for __, entry in ipairs(series) do
            table.insert(items, {
                text = _normalizeName(entry.name, _("Untitled")),
                mandatory = _countLabel(#getBooksForSeries(entry.uuid)),
                series = entry,
            })
        end
        if #series == 0 then
            table.insert(items, { text = _("No series found."), dim = true })
        end
        return items
    end

    local function buildRootItems()
        return {
            {
                text = _("Currently Reading"),
                mandatory = _countLabel(#getCurrentlyReadingBooks()),
                open_currently_reading = true,
            },
            {
                text = _("Recently Added"),
                mandatory = _countLabel(#(state.books or {})),
                open_recently_added = true,
            },
            {
                text = _("All books"),
                mandatory = _countLabel(#(state.books or {})),
                open_all_books = true,
            },
            {
                text = _("Collections"),
                mandatory = _countLabel(#(state.collections or {})),
                open_collections = true,
            },
            {
                text = _("Series"),
                mandatory = _countLabel(#(state.series or {})),
                open_series = true,
            },
        }
    end

    local function renderView()
        if not menu then return end
        if not state.loaded then
            menu:switchItemTable(_("Storyteller"), {
                { text = _("Loading…"), dim = true },
            })
            return
        end

        local view = state.stack[#state.stack] or { kind = "root" }
        local title = _("Storyteller")
        local items = buildRootItems()

        if view.kind == "all_books" then
            title = _("All books")
            local books = _copyList(state.books or {})
            table.sort(books, function(a, b)
                return (a.title or ""):lower() < (b.title or ""):lower()
            end)
            items = buildBookItems(books)
        elseif view.kind == "recently_added" then
            title = _("Recently Added")
            items = buildBookItems(getRecentlyAddedBooks())
        elseif view.kind == "currently_reading" then
            title = _("Currently Reading")
            items = buildBookItems(getCurrentlyReadingBooks())
        elseif view.kind == "collections" then
            title = _("Collections")
            items = buildCollectionItems()
        elseif view.kind == "collection_books" then
            title = _normalizeName(view.collection and view.collection.name, _("Collection"))
            local books = getBooksForCollection(view.collection.uuid)
            table.sort(books, function(a, b)
                return (a.title or ""):lower() < (b.title or ""):lower()
            end)
            items = buildBookItems(books)
        elseif view.kind == "series" then
            title = _("Series")
            items = buildSeriesItems()
        elseif view.kind == "series_books" then
            title = _normalizeName(view.series and view.series.name, _("Series"))
            local books = sortSeriesBooks(view.series.uuid, getBooksForSeries(view.series.uuid))
            items = buildBookItems(books)
        end

        menu:switchItemTable(title, items)
    end

    local function pushView(view)
        table.insert(state.stack, view)
        renderView()
    end

    local function goBack()
        if #state.stack > 1 then
            table.remove(state.stack)
        end
        renderView()
    end

    local function refreshData()
        state.loaded = false
        renderView()
        NetworkMgr:runWhenOnline(function()
            local books_result = ctx.api:listBooks()
            local collections_result = ctx.api:listCollections()
            local series_result = ctx.api:listSeries()

            if not books_result.ok or not collections_result.ok or not series_result.ok then
                logger.warn("simpleui storyteller: failed to load library data")
                _showInfo(_("Failed to load Storyteller library data."))
                state.loaded = true
                state.books = state.books or {}
                state.collections = state.collections or {}
                state.series = state.series or {}
                renderView()
                return
            end

            local downloadable = {}
            for __, book in ipairs(books_result.data or {}) do
                if type(book) == "table" and book.uuid and ctx.models.hasDownloadableFormat(book) then
                    table.insert(downloadable, book)
                end
            end

            state.books = downloadable
            state.collections = collections_result.data or {}
            state.series = series_result.data or {}
            state.loaded = true
            if #state.stack == 0 then
                state.stack = { { kind = "root" } }
            end
            renderView()
        end)
    end

    local function refreshCurrentView()
        renderView()
        if menu then
            menu:updateItems()
        end
    end

    local function onSelectBook(book)
        ctx.downloader:selectAndOpen(book)
        refreshCurrentView()
    end

    local function onMenuSelect(_, item)
        if not item then
            return
        end

        local ok, err = pcall(function()
            if item.back then
                goBack()
            elseif item.open_currently_reading then
                pushView({ kind = "currently_reading" })
            elseif item.open_recently_added then
                pushView({ kind = "recently_added" })
            elseif item.open_all_books then
                pushView({ kind = "all_books" })
            elseif item.open_collections then
                pushView({ kind = "collections" })
            elseif item.open_series then
                pushView({ kind = "series" })
            elseif item.collection then
                pushView({ kind = "collection_books", collection = item.collection })
            elseif item.series then
                pushView({ kind = "series_books", series = item.series })
            elseif item.book then
                onSelectBook(item.book)
            end
        end)

        if not ok then
            logger.warn("simpleui storyteller: onMenuSelect error:", tostring(err))
            _showInfo("Error:\n" .. tostring(err))
        end
    end

    local PageMenu = Menu:extend{}
    menu = PageMenu:new{
        name = "storyteller",
        title = _("Storyteller"),
        item_table = {
            { text = _("Loading…"), dim = true },
        },
        height = UI.getContentHeight(),
        y = UI.getContentTop(),
        _navbar_height_reduced = true,
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        onMenuSelect = onMenuSelect,
        close_callback = function()
            if menu then
                UIManager:close(menu)
            end
        end,
    }

    menu.onCloseWidget = function()
        M._instance = nil
    end

    state.stack = { { kind = "root" } }
    M._instance = menu
    UIManager:show(menu)
    refreshData()
end

return M
