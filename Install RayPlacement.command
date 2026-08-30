#!/bin/zsh
# Compatibility entry point; never install a second app under the retired name.
exec /bin/zsh "${0:A:h}/Install Lima.command" "$@"
