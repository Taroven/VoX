local d = Util.debug

--[[
	xmpp_Send(string sBody, string sJid) as defined in C#
	Sends message (body) to recipient (jid[+resource]). Recipient/resource is optional, will send to Vox.usercfg.recipient if omitted.
	jid+resource may be used for direct (instead of global) replies, and are supplied in XMPP_MSG_RECEIVED events (see api.lua).
]]--
Util.Send = function (body,jid,resource)
	local jid = (resource and jid) and (jid..'/'..resource) or jid or Vox.usercfg.recipient
	xmpp_Send(body,jid)
	Vox.FireEvent('XMPP_MSG_SENT',m)
end
Vox.Send = Util.Send

-- Simple shortcut to reply to the last sender without too much hassle.
Util.Reply = function (body)
	local jid,resource = Vox.LastJID and Vox.LastJID[1], Vox.LastJID and Vox.LastJID[2]
	Util.Send(body, jid, resource)
end
Vox.Reply = Util.Reply

Util.Prompt = function (...)
	local argt,i = {},1
	while true do
		local v = select(i,...)
		if not(v) then break end
		i=i+1
	end
end

Vox.MessageDetails = function (m)
	local m = tostring(m)
	local body = string.match(m, '<body>(.*)</body>')
	local sender = string.match(m, 'from=\"(.*)\">')
	local resource
	if sender then
		resource = string.match(sender, '/(.*)')
		sender = resource and string.match(sender, '(.*)/.*') or sender
	end
	return body,sender,resource
end

xmpp_OnMessage = function (m) -- Note: The OnMessage delegate returns userdata. tostring(m) is required for pattern matching, print and Vox.debug don't mind the raw data.
	local body,sender,resource = Vox.MessageDetails(m)
	if not(body) then return end
	
	local auth -- Check the sender against Vox.config.authorized. Not the most secure way of doing things, but it works for now. TODO: Auth string or challenge prompt
	for i,jid in pairs(Vox.usercfg.authorized) do
		if string.match(sender,jid) then
			auth = true
			local mt = string.explode(body)
			Vox.vars.LastJID = {sender,resource}
			d('DEBUG','OnMessage',body,sender,resource,unpack(mt))
			Vox.FireEvent('XMPP_MSG_RECEIVED',mt,body,sender,resource)
			break
		end
	end
end


--[[
	xmpp_Init(string sServer, string sCServer, double dPort, string sUser, string sPassword, bool bUseSSL) as defined in C#
	Initializes the XMPP instance and tells it to connect. This should probably only be done once.
	Modifying this function should be done with extreme care.
]]--
Util.xmpp_Init = function ()
	if not(Vox.usercfg) then
		Util.GetUserConfig()
	end
	local c = Vox.usercfg
	Util.debug('INFO','Connecting to '..c.username..'@'..c.server..(c.connectserver~=c.server and ('('..c.connectserver..')') or '')..':'..c.port, 'SSL = '..tostring(c.useSSL))
	xmpp_Init(c.server,c.connectserver,c.port,c.username,c.password,c.useSSL)
end

xmpp_OnLogin = function ()
	math.randomseed( os.time() )
	for i = 1,20 do math.random() end -- Having a decently random login message is important, right?
	d('Connected to server.')
	Vox.Send(Vox.config.Greetings[math.random(#Vox.config.Greetings)])
	Vox.FireEvent('XMPP_LOGIN')
end

xmpp_OnClose = function ()
	Vox.FireEvent('XMPP_CLOSE')
end

-- Set up config/userconfig.lua if its info isn't available.
do
	local get
	get = function (prompt,t,default)
		print()
		local x = t == 'number' and tonumber or tostring
		local d = default and ' ['..default..']' or ''
		io.stdout:write('> ',prompt,d, ': ')
		local input = x(io.stdin:read('*l'))
		print()
		if default and (not(input) or input:match('^%s*$')) then
			print('Using the default ('..default..')')
			return default
		elseif not(input) or (type(input)=='string' and input:match('^%s*$')) then
			print('Sorry, can\'t accept an empty answer for this. Please try again.')
			return get(prompt,t)
		end
		
		return input
	end
	
	local setDetails = function (server,connectserver,port,useSSL,username,password,recipient)
		local auth = string.match(recipient,'^(.*)@.*')
		Vox.usercfg = {
			server = server,
			connectserver = connectserver,
			port = port,
			username = username,
			password = password,
			useSSL = useSSL,
			recipient = recipient,
			authorized = {
				auth,
			},
		}
		table.save(Vox.usercfg,VOX_USERCONFIG_FILE)
		return Vox.usercfg
	end
	
	local ucvalidate = function ()
		local t = table.load(VOX_USERCONFIG_FILE)
		if not(t) then return end
		local c = {
			server = true,
			connectserver = true,
			port = '(%d+)',
			username = true,
			password = true,
			recipient = '(.*@.*)',
			authorized = 'tn',
		}
		local validated = true
		for k,v in pairs(c) do
			if t[k] == nil then
				validated = nil
			elseif v == 'tn' then
				validated = type(t[k]) == 'table'
				validated = validated and #t[k] >= 1
			elseif type(v) == 'string' then
				validated = string.match(tostring(t[k]),c[k])
			end
			
			if not(validated) then break end
		end
		return (validated and t)
	end
	
	local getDetails
	getDetails = function ()
		if not(Vox.usercfg) then
			--d("INFO","Config is not present, validating.")
			Vox.usercfg = ucvalidate()
		end
		if Vox.usercfg then
			return d("INFO","Config is present, moving along.")
		end
		print()
		print('This seems to be the first time you\'ve run VoX. VoX requires two XMPP accounts to function: One for you, one for the bot.\n\nLet\'s go ahead and set it all up.\n')
		print('First, we need your XMPP address. If you use Gmail, this would be your email address. Otherwise, the address is usually username@server.com.\n\nPlease note, this is where VoX is sending messages *to*, not *from*.')
		local recipient = get('Your XMPP address')
		while not(string.match(recipient,'^.*@.*\..*')) do
			print('Sorry, that isn\'t a valid address. The usual format is username@server.com, or your Gmail address.')
			recipient = get('Your XMPP address')
		end
		
		print('Now for the bot\'s login details.\n\nFirst, enter the XMPP server that the bot resides on.\nIf you plan on using Google Talk, just press Enter.\n')
		print('NOTE: VoX requires that you already have an account set up for your bot.\nIf the account isn\'t yet active, please register it before continuing.')
		local server = get('Bot\'s server',nil,string.match(recipient,'.*@(.*)'))
		print('Next, we need its connection server. Just press enter if you\'re not sure.\nVoX usually makes a pretty good guess here.')
		local connectserver = get('Bot\'s connection server',nil,server=='gmail.com' and 'talk.google.com' or server)
		print('If your server uses a custom port, please enter it now.')
		local port = get('Server\'s port','number',5222)
		print('Does the server use SSL? (Just press Enter if you\'re not sure)')
		local useSSL = get('SSL (y/n)',nil,'y')
		useSSL = string.match(useSSL,'^[yY]+.*') and true or false
		
		print('Great! Now all we need is the bot\'s username and password.\nNOTE: The username is usually the part *before* the @ sign in the XMPP address.')
		local username = get('Bot\'s username')
		print('Last but not least, VoX needs a password to sign into the bot\'s account.\nPlease type carefully, there is no confirmation here.')
		local password = get('Bot\'s password')
		
		local confirm = function ()
			os.execute('cls')
			print('Please confirm the bot\'s information.')
			print()
			print('Server: ',server)
			print('Connectserver: ',connectserver)
			print('Port: ',port)
			print('Using SSL: ',tostring(useSSL))
			print('Username: ',username)
			print('Password: HIDDEN ('.. #password ..' characters, starting with "'..string.sub(password,1,1)..'")')
			print('Your XMPP Address: ',recipient)
			print()
			local c = get('Is this information correct? (y/n)')
			if string.match(c,'^[yY]+.*') then
				return true
			end
		end
		
		if not(confirm()) then
			return getDetails()
		else
			os.execute('cls')
			return setDetails(server,connectserver,port,useSSL,username,password,recipient)
		end
	end
	Util.GetUserConfig = getDetails
end

