local d = Util.debug

Vox.vars = {}
Vox.events = {}
Vox.modules = {}

do
	if not(type(Vox.context)=='table') then
		Vox.context = {}
		d('ERROR','Vox could not find or open the context table, found in '..VOX_CONTEXT_FILE..' - Custom contextual aliasing support will be unavailable.')
	end
end

-- xmpp_Init(string sServer, string sCServer, double dPort, string sUser, string sPassword, bool bUseSSL) as defined in C#
-- Util.xmpp_Init detects the proper information to use for the client and provides a little extra feedback.
-- VoX technically only needs username, password, and server. If you're connecting to Google Talk, connectserver is needed as well. SSL and port will depend entirely on your server as well.
Util.xmpp_Init()