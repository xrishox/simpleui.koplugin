-- Regression for orphaned Storyteller windows preventing KOReader shutdown.
-- Run from this repository: KOREADER_ROOT=/path/to/koreader luajit tests/exit_lifecycle.lua
-- Uses the actual KOReader event dispatch, window removal, and exit handlers;
-- rendering, native I/O, and screen contents are replaced by lightweight fixtures.
local core = assert(os.getenv('KOREADER_ROOT'), 'set KOREADER_ROOT') .. '/'
package.path = core .. 'frontend/?.lua;' .. package.path
package.loaded['ui/geometry'] = {}
table.pack = table.pack or function(...) return { n=select('#', ...), ... } end
local Event = require('ui/event')
local Container = require('ui/widget/container/widgetcontainer')
local Widget = require('ui/widget/widget')
local function read(path)
    local f=assert(io.open(path)); local s=f:read('*a'); f:close(); return s
end
-- Load production methods without initializing the native display/input drivers.
local function method(path, name)
    return assert(read(path):match('(function ' .. name .. '%([^\n]*\n.-\nend)'), name)
end
local UIManager = { setDirty=function() end, _refresh=function() end }
local logger = { dbg=function() end, warn=function() end }
local Input = {}
assert(loadstring('local UIManager,Event,logger,Input=...\n' ..
    method(core..'frontend/ui/uimanager.lua', 'UIManager:close') .. '\n' ..
    method(core..'frontend/ui/uimanager.lua', 'UIManager:broadcastEvent')))(UIManager,Event,logger,Input)
local SimpleUIPlugin = Container:extend{}
assert(loadstring('local SimpleUIPlugin,UIManager=...\n' ..
    method('main.lua', 'SimpleUIPlugin:_closeStorytellerScreen') .. '\n' ..
    method('main.lua', 'SimpleUIPlugin:onExit') .. '\n' ..
    method('main.lua', 'SimpleUIPlugin:onRestart') .. '\n' ..
    method('main.lua', 'SimpleUIPlugin:onCloseWidget')))(SimpleUIPlugin,UIManager)
local FileManagerMenu, ReaderMenu, DeviceListener = {}, {}, Widget:extend{}
assert(loadstring('local FileManagerMenu,ReaderMenu,DeviceListener,UIManager=...\n' ..
    method(core..'frontend/apps/filemanager/filemanagermenu.lua', 'FileManagerMenu:exitOrRestart') .. '\n' ..
    method(core..'frontend/apps/reader/modules/readermenu.lua', 'ReaderMenu:exitOrRestart') .. '\n' ..
    method(core..'frontend/device/devicelistener.lua', 'DeviceListener:onExit') .. '\n' ..
    method(core..'frontend/device/devicelistener.lua', 'DeviceListener:onRestart')))(FileManagerMenu,ReaderMenu,DeviceListener,UIManager)
local pending
function UIManager:nextTick(fn) pending[#pending+1]=fn end
function UIManager:restartKOReader() self._exit_code=85 end
local function drain()
    while #pending>0 do table.remove(pending,1)() end
end
local function setup(options)
    options=options or {}
    pending={}; UIManager._window_stack={}; UIManager._dirty={}
    UIManager._simpleui_exiting=nil; UIManager._exit_code=nil
    package.loaded['engines/sui_screen_engine']=nil
    package.loaded['screens/sui_storyteller']=nil
    local host=Container:new{name=options.reader and 'ReaderUI' or 'filemanager'}
    local menu_class=options.reader and ReaderMenu or FileManagerMenu
    host.menu=setmetatable({ui=host,onTapCloseMenu=function() end},{__index=menu_class})
    host.onClose=function(self) UIManager:close(self) end
    host[1]=DeviceListener:new{ui=host}
    host[2]=SimpleUIPlugin:new{ui=host}
    UIManager._window_stack={{widget=host}}
    local state={closed=0,host=host}
    if options.storyteller then
        local library=Widget:new{name='storyteller',covers_fullscreen=true}
        local module={_instance=library}
        library.onCloseWidget=function()
            state.closed=state.closed+1; module._instance=nil
            assert(library._navbar_closing_intentionally, 'must suppress home-screen reopening')
        end
        package.loaded['screens/sui_storyteller']=module
        table.insert(UIManager._window_stack, options.behind and 1 or #UIManager._window_stack+1,
            {widget=library})
    end
    if options.home then
        local home=Widget:new{name='homescreen',_parked=options.parked}
        local instance=home
        home.onCloseWidget=function() instance=nil end
        package.loaded['engines/sui_screen_engine']={
            liveScreenIds=function() return instance and {'hs'} or {} end,
            getInstance=function() return instance end,
        }
        UIManager._window_stack[#UIManager._window_stack+1]={widget=home}
    end
    return state
end
local count=0
local function check(name,options,event)
    local state=setup(options)
    UIManager:broadcastEvent(Event:new(event or 'Exit'));drain()
    assert(#UIManager._window_stack==0,name..': windows remain')
    assert(state.closed==(options.storyteller and 1 or 0),name..': close count')
    if event=='Restart' then assert(UIManager._exit_code==85,name..': restart lost') end
    count=count+1;print('ok '..count..' - '..name)
end
check('native file-manager exit without Storyteller',{})
check('Storyteller exit without loading ScreenEngine',{storyteller=true})
check('Storyteller exit with a home screen',{storyteller=true,home=true})
check('hidden Storyteller window below the file manager',{storyteller=true,home=true,behind=true})
check('reader exit with a leftover Storyteller window',{reader=true,storyteller=true})
check('reader exit also closes a parked home screen',{reader=true,storyteller=true,home=true,parked=true})
check('file-manager restart closes Storyteller',{storyteller=true},'Restart')
check('reader restart closes Storyteller',{reader=true,storyteller=true,home=true,parked=true},'Restart')
local state=setup{storyteller=true,home=true,parked=true}
state.host.tearing_down=true;state.host:onClose()
assert(state.closed==1,'opening a reader must close the old Storyteller context')
assert(#UIManager._window_stack==1 and UIManager._window_stack[1].widget.name=='homescreen',
    'normal reader transitions must preserve parked home screens')
assert(not UIManager._simpleui_exiting,'normal reader transitions must not mark app exit')
count=count+1;print('ok '..count..' - reader transition preserves parked home screen')
print('PASS: '..count..' exit lifecycle cases')
