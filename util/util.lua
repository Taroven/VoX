--[[
	util.lua - Sets up VoX's environment before the API is initialized.
	VoX.exe sets up a very minimal API for communicating with the XMPP server and handles core file loading/retrieval, the rest is handled in pure Lua.
	
	Global constants:
		VOX_EXEC_PATH - Full path to VoX.exe.
		VOX_ENV_PATH - Path to "VoX Toolkit" in appdata.
		VOX_CONFIG_PATH - Path to the savedvariables directory (usually a subdir of VOX_ENV_PATH).
		VOX_USERCONFIG_FILE - Path to userconfig.sv, which is generated when not found and contains essential messaging info.
		VOX_LOG_FILE - Path to VoX.log. Should be in the same directory as VoX.exe.
		VOX_CONTEXT_FILE - Path to VoX's context file. Again, should be in the same directory as VoX.exe.
	
	Functions in compiled/container code:
		quit() - Triggers an interrupt, exits the program with status 0.
		xmpp_Init(...) - See Util.xmpp_Init in connect.lua for details and usage. Requires arguments, calls xmpp.Open() after passing them along.
		xmpp_Send(...) - See Vox.Send in api.lua for details and usage.
		xmpp_Presence('presence') - Changes the bot's current presence message.
		
	Function calls from C#:
		xmpp_OnLogin() - Triggers on XMPP connect.
		xmpp_OnClose() - Triggers on XMPP exit. Use for last-second cleanup if needed, as it generally only fires on interrupt.
		xmpp_OnMessage(msg) - Triggers on message receipt, passes full XML stanza.
			- api.lua does basic parsing on this via Vox.MessageDetails, which strips the stanza to body, XMPP address, and XMPP resource before firing XMPP_MSG_RECEIVED with the same.
			- api.lua also does basic validation of the sender by matching the beginning of the sender's address against entries in Vox.usercfg.authorized. If you are concerned with security, you can check a full JID by modifying userconfig.sv.
			
	Custom Lua API:
		io.create(path) - Creates a file if it doesn't already exist at a given path.
		table.save(path) - Saves a table's contents to file.
		table.load(path) - Loads a previously saved table.
]]--

--[[
	Vox.debug(['errorlevel',] ...)
	Errorlevel is optional and defaults to INFO (not case sensitive).
	Messages will be logged to both console and logfile in realtime. If the log can't be opened, VoX WILL complain.
	Set Vox.config.noLog = true to disable file logging. Note: The logfile will still be created and VoX.exe will still look for it.
]]--

-- luafilesystem is used for directory listings and some file operations.
require "lfs"

do
	local elvls = {
		'TRACE',	-- Extremely spammy messages from the message handler
		'DEBUG',	-- Spammy messages from the event handler and other common functions
		'INFO',		-- Default level, general information and notifications
		'WARN',		-- Missing or incorrect info/functionality with potential side effects
		'ERROR',	-- Missing or incorrect info/functionality with definite/harmful side effects
		'FATAL'		-- Errors with potential to really screw things up, usually forcing a program exit
	}
	local elvlsb = {}
	for i,v in ipairs(elvls) do elvlsb[v] = i end

	Util.debug = function (el,...)
		local el = el
		if (type(el) == 'string' and elvlsb[string.upper(el)]) then el = string.upper(el) elseif type(el) == 'function' then return el(...) end
		local dmesg = {...}
		if type(el) == 'number' then
			el = elvlsb[elvls[el]] or elvlsb['WARN'] -- check if the elvl is defined in both tables, set to WARN if not and call it good
		elseif not(elvlsb[tostring(el)]) then
			table.insert(dmesg,1,tostring(el)) -- unspecified errorlevel, assume it's part of the message
			el = nil -- no errorlevel implies straight print
		else
			el = elvlsb[el]
		end

		if el and not(Vox.config.errorlevel[elvls[el]]) then return end -- don't do anything if the errorlevel isn't being tracked

		local s = table.concat(dmesg,' | ')
		if el and not(Vox.config.noLog) then
			Log(el-1,s)
		else
			Print(s)
		end
	end
	Vox.debug = Util.debug
end
local d = Util.debug
local collectinfo
d('Initializing Vox utilities.')

-- Fire an event as a method of each module, passing self, event, params
Util.FireEvent = function (event, ...)
	if not(Vox.events[event]) or type(Vox.events[event])~='table' then return end
	local n = 0
	for module,mt in pairs(Vox.modules) do
		local m = Vox.modules[module]
		if m[event] then m[event](m,event,...) end
		n = n+1
	end
	d('DEBUG',event,'passed to '..n..' modules',table.concat({...},','))
end
Vox.FireEvent = Util.FireEvent

-- Original source:
----------------------------------------------
-- Pickle.lua
-- A table serialization utility for lua
-- Steve Dekorte, http://www.dekorte.com, Apr 2000
-- Freeware
----------------------------------------------
-- Modified to work in Lua 5.1+ (only minor testing)
do
	local Pickle
	local function pickle(t)
		return Pickle:clone():pickle_(t)
	end

	Pickle = {
		clone = function (t)
		local nt={}
		for i, v in pairs(t) do
			nt[i]=v
		end
		return nt end 
	}

	function Pickle:pickle_(root)
		if type(root) ~= "table" then 
			error("can only pickle tables, not ".. type(root).."s")
		end
		self._tableToRef = {}
		self._refToTable = {}
		local savecount = 0
		self:ref_(root)
		local s = ""

		while #self._refToTable > savecount do
			savecount = savecount + 1
			local t = self._refToTable[savecount]
			s = s.."{\n"
			for i, v in pairs(t) do
				s = string.format("%s[%s]=%s,\n", s, self:value_(i), self:value_(v))
			end
			s = s.."},\n"
		end

		return string.format("{%s}", s)
	end

	function Pickle:value_(v)
		print(v)
		local vtype = type(v)
		if vtype == "string" then return string.format("%q", v)
		elseif vtype == "number" then return v
		elseif vtype == "table" then return "{"..self:ref_(v).."}"
		else --error("pickle a "..type(v).." is not supported") - yeah, fuck that, just tostring it and call it good...
			return tostring(v)
		end  
	end

	function Pickle:ref_(t)
		local ref = self._tableToRef[t]
		if not ref then 
			if t == self then error("can't pickle the pickle class") end
			table.insert(self._refToTable, t)
			ref = #self._refToTable
			self._tableToRef[t] = ref
		end
		return ref
	end

	----------------------------------------------
	-- unpickle
	----------------------------------------------

	local function unpickle(s)
		if type(s) ~= "string" then
			error("can't unpickle a "..type(s)..", only strings")
		end
		local gentables = loadstring("return "..s)
		local tables = gentables()
		if not(tables) then return end
		
		for tnum = 1, #tables do
			local t = tables[tnum]
			local tcopy = {}; for i, v in pairs(t) do tcopy[i] = v end
			for i, v in pairs(tcopy) do
			  local ni, nv
			  if type(i) == "table" then ni = tables[i[1]] else ni = i end
			  if type(v) == "table" then nv = tables[v[1]] else nv = v end
			  t[i] = nil
			  t[ni] = nv
			end
		end
		return tables[1]
	end
	
	-- Actual usage: table.save, table.load
	table.load = function (file)
		local f = assert(io.open(file))
		if f then
			local s = f:read("*all")
			return unpickle(s)
		end
	end
	
	table.save = function (t,file)
		local f = io.create(file) -- Lua and LFS both lack a method of creating files, thus io.create is defined in source (arg path, returns path if found or created, nil if not)
		if f then
			f = assert(io.open(f, 'w+'))
		else return end
		
		if f then
			assert(f:write(pickle(t)))
		end
	end
	
	-- Clone a table into another
	local tclone = function (t,r)
		local ret = type(r)=='table' and r or {}
		if type(t)=='table' then
			for k,v in pairs(t) do ret[k]=v end
		end
		return ret
	end
	
	--[[ table.clone (source,result,copyMeta) : Copy a table with optional metatable information. All args technically optional.
		Args:
			source = Source table to work from.
			result = Result table for insertion.
			copyMeta = Flag to copy the metatable as well. This is done without referencing, as far as is feasible.
		
		Returns a dereferenced copy of the source with the following caveats:
			If result is defined, source will be inserted into result.
			Keys existing in result will be overwritten by source.
			
		Examples:
			test = {1,2,3, x=4}
			-- control, without table.clone:
				t = test; t[1]="changed"; for k,v in pairs(t) do print(k, t[k],test[k])
					1	changed	changed		-- direct reference, change to t affects test
					2	2	2
					3	3	3
					x	4	4
			-- with table.clone:
				-- same as control, using table.clone
				t = table.clone(test); t[1]="changed"; test[2]="changed"; for k,v in pairs(t) do print(k, t[k],test[k])
					1	changed	1			-- no reference
					2	2	changed			-- again, no reference
					3	3	3
					x	4	4
				
				-- add a result table
				t = table.clone(test,{5,6,7,8}); test[2]='changed'; t[3]='changed'; for k,v in pairs(t) do print(k, t[k],test[k])
					1	1	1				-- result[1] exists, is overwritten
					2	2	changed			-- result[2] exists, is overwritten, and modified at source afterwords
					3	changed	3			-- result[3] exists, is overwritten, and modified
					4	8	nil				-- result[4] does not exist in source, is not overwritten
					x	4	4				-- result.x does not exist and isn't changed in any case
	]]
	table.clone = function (t,r,cmt)
		local ret = tclone(t,r)
		if cmt then
			local mt = getmetatable(t)
			mt = type(mt) == 'table' and mt
			if mt then
				setmetatable(ret,tclone(mt))
			end
		end
		return ret
	end
end

--[[
	Module-related functionality

	Vox is extendable via a Table of Contents File (tocfile) system. Yes, this is similar to WoW.

	Notes (in no particular order):
	* Modules are declared in the table Vox.Load, and loaded VoX/Modules/[ModuleName]. If [ModuleName].toc does not exist within that directory, expect errors.
	* Tocfiles have no concept of comments. Double hash (##) signifies metainfo, which is stored within the module's namespace as module.MetaInfo.value (leading whitespace ignored)
		- Metainfo isn't explicitly required, but helps to identify and categorize modules.
	* Equal (=) or colon (:) may be used as the metainfo's delimiter. Whitespace is optional and ignored.
	* Modules have a namespace created for them, under Vox.modules[moduleName]. Metainfo is stored in Vox.modules[moduleName].MetaInfo.
	* An entry in Vox.Load is required for each module, and errors will probably happen if a declared module isn't found.
		- When Vox converts to a LFS-compatible version of LuaInterface, this won't be the case. Until then, it's as easy as I can make it.
	* FUTURE SUPPORT: Tocfiles may declare a SavedVariables (or SavedVars, or SV) metainfo field which will create a persistent storage file for them.
		- Until managed savedvariables are implemented, just write to a file within the module's directory.

	Directory structure:
	[VoX]
		[Modules]
			- globalcfg.toc (declares 'GlobalCFG\globalcfg.lua')
			[ModuleA]
				- ModuleA.toc (declares 'core.lua' and 'config.lua')
				- core.lua
				- config.lua
			[ModuleB]
				- ModuleB.toc (declares 'ModuleB.lua' and 'config\config.lua')
				- ModuleB.lua
				[config]
					- config.lua
			[ModuleC]
				- ModuleC.toc (declares '..\globalcfg.toc', 'core.lua')
				- core.lua
			[GlobalCFG]
				- globalcfg.lua (no toc or declaration means it won't be loaded on its own, though ModuleC in this case would load it anyway)

	TOC file structure:

		## Title: RandomTestName
		## Version = 0.1
		##screwedUpButStillValidMetaInfo=              lolhai

		core.lua
		config.lua
		..\Example\example.toc

	Example usage of Vox.Load:

	Vox.Load = {
		'ModuleA',
		'ModuleB',
		'OtherRandomModule',
	}


]]--

function attrdir (path)
	for file in lfs.dir(path) do
		if file ~= "." and file ~= ".." then
			local f = path..sep..file
			print ("\t=> "..f.." <=")
			local attr = lfs.attributes (f)
			assert (type(attr) == "table")
			if attr.mode == "directory" then
				attrdir (f)
			else
				for name, value in pairs(attr) do
					print (name, value)
				end
			end
		end
	end
end

do
	local parseToc = function (path,name) -- requires the full path *of* the tocfile (not to - small difference)
		if Vox.modules[name] then
			return d('WARN','Loading of module '..name..' failed, namespace already exists!')
		elseif not(lfs.attributes(path)) then
			return d('WARN','Loading of module '..name..' failed',select(2,lfs.attributes(path)))
		end
		
		Vox.modules[name] = {}
		Vox.modules[name].MetaInfo = Vox.modules[name].MetaInfo or {}
		
		for line in io.lines(path) do parseLine(line,name,path) end
		local m = Vox.modules[name].MetaInfo
		m.Path = string.match(path,'(.*\\).*\.toc$')
		local sv = m.SavedVariables or m.SavedVars or m.SV
		if sv then
			m.SVPath = VOX_CONFIG_PATH..Vox.config.pathsep..name..'.sv'
			local vars = table.load(m.SVPath)
			Vox.vars = Vox.vars or {}
			Vox.vars[name] = type(vars[1]=='table') and vars[1] or vars
			
			-- Assign a proxy table within the module's namespace (module.SV) to handle savedvariables.
			-- You may limit writes for commonly changed keys by making changes to Vox.vars[moduleName] directly. The entire table will be saved when a single key is changed.
			Vox.modules[name].SV = setmetatable({},{
				__index = function (self,k)
					return Vox.vars[name][k]
				end,
				
				__newindex = function (self,k,v)
					local old = Vox.vars[name][k]
					Vox.vars[name][k] = v
					if old ~= v then
						table.save(Vox.vars[name],m.SVPath)
						d('DEBUG','Module '..name,' savedvariables changed and saved',k,tostring(old)..' => '..tostring(v))
					end
				end,
				
				__metatable = 'Savedvariable storage metatables are locked.',
			})
		end
	
		Util.FireEvent('MODULE_LOADED',name)
	end
	
	local getDirStructure
	local sep = Vox.config.pathsep
	getDirStructure = function (path,t)
		if type(path)~='string' then return end
		local t = type(t) == 'table' and t or {}
		for file in lfs.dir(path) do
			if file ~= '.' and file ~= '..' then
				local f = path..sep..file
				local attr = lfs.attributes(f)
				assert (type(attr) == 'table')
				if attr.mode == 'directory' then
					t[file] = {}
					getDirStructure(f,t[file])
				else
					t[file] = true
				end
			end
		end
		return t
	end
	
	-- loadModule: Check for the file, then run it if found with arguments (accessed via '...' outside function scope)
	local loadModule = function (f,name,ns)
		local test,reason,errno = io.open(f)
		if test then
			test:close()
			local file = assert(loadfile(f))
			if file then file(name,ns) end
		else
			d('WARN','File declared in toc for module '..name..' could not be opened',f,reason,errno)
		end
	end

	local parseLine = function (l,name,path)
		if type(l)~='string' then return end
		local meta,info = string.match(l,'^%s*##%s*(.*)%s*[:=]+%s*(.*)')
		if meta and info then
			Vox.modules[name].MetaInfo[meta] = info
		else
			local file = string.match('^%s*(.+\.lua)')
			local tfile = string.match('^%s*(.+\.toc)')
			local path = string.match(path,'(.*\\).*\.toc$')
			if file then
				local f = path..Vox.config.pathsep..file
				Vox.modules[name].MetaInfo = Vox.modules[name].MetaInfo or {}
				Vox.modules[name].MetaInfo.Files = Vox.modules[name].MetaInfo.Files or {}
				table.insert(Vox.modules[name].MetaInfo.Files,f)
				loadModule(f,name,Vox.modules[name])
			elseif tfile then
				parseToc(string.match(path..tfile),string.match(tfile,'^(.+)\.toc'))
			end
		end
	end

	Util.LoadModule = function (module)
		if type(module) == 'string' then
			parseToc(Vox.config.mpath..module..Vox.config.pathsep..module..'.toc',module)
		else
			d('WARN','Invalid argument to Util.LoadModule(moduleName) - string expected, got '..tostring(module),module)
		end
	end
	
	Util.GetMetaInfo = function (module,field)
		if (Vox.modules[module] and Vox.modules[module].MetaInfo) then
			return (field and Vox.modules[module].MetaInfo[field] or Vox.modules[module].MetaInfo)
		end
	end
	
	
	
	Vox.LoadModule = Util.LoadModule
	Vox.GetMetaInfo = Util.GetMetaInfo
end

do
	local escape = function (s)
	  return (s:gsub('[%-%.%+%[%]%(%)%$%^%%%?%*]','%%%1'):gsub('%z','%%z'))
	end

	local parens = {
		["["] = "]",
		["("] = ")",
		["<"] = ">",
		["{"] = "}",
		["'"] = "'",
		["\""] = "\"",
	}
	
	--[[
		string.explode: Expands a string into table form without breaking phrases in the process.
		The returned table is numerically indexed in the order of the original string.
		Example:
		string.explode('This is a (test string) with "quotes and (parenthesis and a bit of [nesting])"')
		= {
			'This',
			'is',
			'a',
			'test string',
			'with',
			'quotes and (parenthesis and a bit of [nesting])'			
		}
		
			- Phrases are matched according to the above parens table.
			- Removes punctuation from beginning and end of phrases.
			- By design, will not destroy nested formatting. '((foo))' will return { '(foo)' }.
			- Phrases with repeating elements may be incorrectly parsed. Couldn't tell you what '(foo (foo (foo) foo) foo)' would end up as.
			- Punctuation is not altered outside of phrases. Leading and trailing punctuation should be handled by the syntax engine.
	]]--
	local explode = function (s)
		local t = {}
		local temp = {}
		
		-- First find conjoined terms, place them in their own temp table
		for paren,match in pairs(parens) do
			for w in string.gmatch(s,"%b"..paren..match) do
				for i,v in ipairs(temp) do
					-- %b() will find both occurrences of parenthesis in "(this (is a) message)", when used via string.gmatch
					-- Because we don't want duplicates, we kill them off here as best we can.
					if string.match(w,escape(v)) then
						table.remove(temp,i)
					end
				end
				--local w = string.match(w,'^'..escape(paren)..'(.*)'..escape(match)..'$')
				-- Don't even bother for single-word matches
				if string.match(w,'%s+') then
					table.insert(temp,w)
				end
			end
		end
		d('TRACE',s,#temp..' sets found within string')
		
		local current, test
		for w in string.gmatch(s,"(%S+)") do
			if current then
				-- Create a test string to ensure we're not stopping at the wrong point of a complex match.
				-- Since we space-delimit, it's easy to reconstruct the string.
				test = test .. ' ' .. w
				if current == test then
					current = nil
					test = nil
				end
			else
				-- If a match is found for a set, insert the set instead of the current word and wait until the set's completion is found.
				if temp[1] and string.match(temp[1],'^'..escape(w)) then
					current = table.remove(temp,1)
					test = w
					-- Crop out the spare punctuation from previous matching, don't need it for insertion
					local actual
					for paren,match in pairs(parens) do
						if not(actual) then
							actual = string.match(current,'^'..escape(paren)..'(.*)'..escape(match)..'$')
						end
					end
					table.insert(t,actual or current)
				else
					-- Just insert everything else, no need for extra processing. Punctuation is removed in parsing.
					table.insert(t,w)
				end
			end
		end
		
		d('TRACE','message parse complete',s,unpack(t))
		return t
	end
	string.explode = explode
end

do	
	-- FIXME: Build the argtable through a single loop, don't need findContext
	local parseCommand = function (jid,resource,t,fromHistory)
		assert(type(t)=='table' and #t>0,'parseCommand requires a table with at least one entry')
		assert(jid,'parseCommand requires a recipient')
		
		local argt = fromHistory or {
				args = {},
				jid = jid,
				resource = resource,
				tries = 0
			}
		
		if fromHistory then
			
		else
			for i,v in ipairs(t) do
				-- try to get the context
				if not(argt.context and (string.match(v,'%s+') or tonumber(v))) then --skip combined results and numbers
					local s = v:match('^%p*(.-)%p*$'):lower() -- strip leading and trailing punctuation, lowercase the result
					if Vox.context[s] then
						argt.context = s
					end
				else
					table.insert(argt.args,v)
				end
			end
		end
		
		
		if argt.context then
			Vox.LastCommand = t
			table.insert(Vox.CommandHistory,t)
		else
			-- TODO: try very hard to get the context. For now, just tell the user what's up and keep going.
			Vox.Reply("Sorry, I couldn't understand that. Did you mean to ")
		end
	end
end

