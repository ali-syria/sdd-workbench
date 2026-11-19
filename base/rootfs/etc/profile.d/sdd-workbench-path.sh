# The workbench's own PATH, again for a login shell. Debian's /etc/profile
# resets PATH for `bash -l`, which would hide the npm globals (the language
# servers, Playwright's CLI) and Claude Code's link from any script started
# as a login shell. zsh and a plain `bash` keep the image's PATH already.
for dir in /usr/local/share/npm-global/bin "$HOME/.local/bin"; do
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) PATH="$dir:$PATH" ;;
  esac
done
export PATH
