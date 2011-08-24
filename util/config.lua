Vox.config = {
	pathsep = '\\',
	errorlevel = {
		TRACE = true,
		DEBUG = true,
		INFO = true,
		WARN = true,
		ERROR = true,
		FATAL = true,
	},
	version = 0.1,
}
Vox.config.mpath = '.'..Vox.config.pathsep..'Modules'

Vox.config.Greetings = Vox.Greetings or {
	"Hello, and again welcome to the Aperature Science Computer-Aided... Never mind.",
	"Hilbert Effect activated.",
	"VoX Toolkit "..Vox.config.version.." at your disposal. Type 'help' for directions.",
	"Good morning, Dave.",
	"[INSERT GREETING HERE]",
	"I enjoy the sight of humans on their knees.",
	"Morose rumination: To be or not to be, that is the question.",
}