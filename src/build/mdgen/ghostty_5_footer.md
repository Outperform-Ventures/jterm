# FILES

_\$XDG_CONFIG_HOME/jterm/config_

: Location of the default configuration file.

_\$HOME/Library/Application Support/com.jterm.app/config_

: **On macOS**, location of the default configuration file. This location takes
precedence over the XDG environment locations.

_\$LOCALAPPDATA/jterm/config_

: **On Windows**, if _\$XDG_CONFIG_HOME_ is not set, _\$LOCALAPPDATA_ will be searched
for configuration files.

# ENVIRONMENT

**XDG_CONFIG_HOME**

: Default location for configuration files.

**$HOME/Library/Application Support/com.jterm.app**

: **MACOS ONLY** default location for configuration files. This location takes
precedence over the XDG environment locations.

**LOCALAPPDATA**

: **WINDOWS ONLY:** alternate location to search for configuration files.

# BUGS

See the local project issue tracker for this fork.

# AUTHOR

Mitchell Hashimoto <m@mitchellh.com>
jTerm contributors

# SEE ALSO

**jterm(1)**
